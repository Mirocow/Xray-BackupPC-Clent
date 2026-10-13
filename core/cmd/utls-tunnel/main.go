// Package main — utls-tunnel: локальный TCP relay с uTLS Chrome fingerprint.
//
// Проблема: Dart клиент (backuppc_dart/lib/src/carrier.dart) использует
// dart:io SecureSocket, который использует BoringSSL из Dart SDK. Это даёт
// уникальный JA3/JA4 fingerprint, не совпадающий ни с одним браузером.
// GFW/ТСПУ может блокировать по этому fingerprint (Iran precedent 2022-2023).
//
// Решение: отдельный Go binary делает TLS handshake с utls.UClient +
// HelloChrome_Auto. Dart клиент подключается к local listener этого binary
// по raw TCP. TLS-layer fingerprints (JA3/JA4) на wire = Chrome, не Dart.
//
// Architecture:
//
//      Dart carrier ─── raw TCP ──> [utls-tunnel :localPort]
//                                       │
//                                       ├── uTLS handshake (Chrome ClientHello)
//                                       │   OR
//                                       ├── crypto/tls + ECH (RFC 9460, encrypted SNI)
//                                       │
//                                       └── relay bytes ──> [actual server host:port]
//
// Usage:
//
//      utls-tunnel --listen 127.0.0.1:0 --remote example.com:8443 \
//                  --sni cdn.example.com --fingerprint chrome
//
//      ECH mode (stronger DPI evasion, encrypts SNI):
//      utls-tunnel --listen 127.0.0.1:0 --remote example.com:8443 \
//                  --sni real.example --ech-config-list <base64>
//
//      Listens on 127.0.0.1:<random port>, prints port to stdout on startup.
//      Dart carrier connects to that port (raw TCP), all bytes are relayed
//      to remote via uTLS-wrapped TLS connection.
//
// Alternative: if --listen given as port 0, prints actual port on stdout
// (first line) so Dart can spawn the binary and read the port.
//
// See:
//   - docs/UTLS-GAP-ANALYSIS.md (in xray-backuppc repo) — gap analysis
//   - desktop/internal/backupemulator/utls.go — Go desktop uTLS impl
//   - Marvia's internal/transport/tls.go — Marvia's uTLS impl
package main

import (
        "context"
        "crypto/sha256"
        crypto_tls "crypto/tls"
        "crypto/x509"
        "encoding/hex"
        "errors"
        "flag"
        "fmt"
        "io"
        "log/slog"
        "net"
        "os"
        "os/signal"
        "strings"
        "syscall"
        "time"

        utls "github.com/refraction-networking/utls"
        "github.com/quic-go/quic-go"

        // Public re-export shim for ECH/Noise helpers (internal package
        // can't be imported cross-module). Kept in sync with server-side
        // xray-backuppc/internal/backupemulator/ech.go + noise_conn.go.
        "backuppc/v2"
)

const (
        // connectTimeout — на установку TCP к remote.
        connectTimeout = 10 * time.Second
        // handshakeTimeout — на TLS handshake.
        handshakeTimeout = 15 * time.Second
        // relayBufferSize — размер буфера для relay (как у Dart carrier).
        relayBufferSize = 32 * 1024
)

func main() {
        logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
                Level: slog.LevelInfo,
        })).With("component", "utls-tunnel")

        var (
                listen      = flag.String("listen", "127.0.0.1:0", "local TCP listen address (port 0 = random)")
                remote      = flag.String("remote", "", "remote host:port (e.g. cdn.example.com:8443)")
                sni         = flag.String("sni", "", "TLS SNI (defaults to host part of --remote)")
                fingerprint = flag.String("fingerprint", "chrome", "uTLS ClientHelloID: chrome|firefox|safari|ios|random|golang")
                insecure    = flag.Bool("insecure", false, "skip TLS cert verification (dev only)")
                certPin     = flag.String("cert-fingerprint", "", "SHA-256 hex of server cert (pinning instead of CA)")
                h2only      = flag.Bool("h2-only", true, "ALPN: only negotiate h2 (HTTP/2 required for carrier)")
                // Noise layer (audit 2026-10-12, Marvia-inspired): when --noise-key
                // is set, after TLS + uTLS handshake, do Noise IK handshake with
                // server. All subsequent bytes relayed via Noise AEAD.
                // Dart client doesn't have Noise library — utls-tunnel does it.
                noiseKey = flag.String("noise-key", "", "server's Noise X25519 public key (hex, 64 chars). When set: enable Noise layer after TLS.")
                // QUIC fallback: when --quic is set, use HTTP/3 over QUIC (UDP).
                quic = flag.Bool("quic", false, "use HTTP/3 over QUIC (UDP) instead of HTTP/2 over TCP. For when TCPU blocks TCP HTTP/2.")
                // ECH (Encrypted Client Hello, audit 2026-10-13, RFC 9460):
                // when --ech-config-list is set (base64-encoded ECHConfigList),
                // use native crypto/tls instead of uTLS, and set
                // EncryptedClientHelloConfigList. SNI is encrypted via HPKE,
                // not visible to DPI. Trade-off: lose JA3 fingerprint mimicry
                // (uTLS doesn't support ECH — overrides ClientHelloSpec).
                // ECH gives stronger passive-DPI defense than JA3 mimicry.
                echConfigListB64 = flag.String("ech-config-list", "", "base64-encoded ECHConfigList (RFC 9460). When set: use native crypto/tls + ECH (disables uTLS).")
        )
        flag.Parse()

        if *remote == "" {
                logger.Error("--remote is required")
                os.Exit(1)
        }

        // Parse remote host:port for SNI default.
        remoteHost, remotePort, err := net.SplitHostPort(*remote)
        if err != nil {
                logger.Error("invalid --remote", "remote", *remote, "err", err)
                os.Exit(1)
        }

        // SNI: explicit flag > default from remote host.
        sniValue := *sni
        if sniValue == "" {
                sniValue = remoteHost
        }

        // Resolve fingerprint.
        helloID := pickClientHelloID(*fingerprint)

        // ECH mode: native crypto/tls + EncryptedClientHelloConfigList.
        // When --ech-config-list is set, we switch from uTLS to native crypto/tls
        // and configure ECH. uTLS doesn't support ECH (overrides ClientHelloSpec).
        var echConfigList []byte
        if *echConfigListB64 != "" {
                parsed, err := v2.ParseECHConfigListB64(*echConfigListB64)
                if err != nil {
                        logger.Error("invalid --ech-config-list", "err", err)
                        os.Exit(1)
                }
                echConfigList = parsed
                logger.Info("ECH mode: native crypto/tls (uTLS disabled — incompatible with ECH)",
                        "config_list_b64_len", len(*echConfigListB64),
                        "config_list_bytes", len(echConfigList))
        }

        logger.Info("uTLS tunnel starting",
                "listen", *listen, "remote", *remote, "sni", sniValue,
                "fingerprint", *fingerprint, "insecure", *insecure,
                "cert_pin", *certPin != "",
                "ech", *echConfigListB64 != "", "quic", *quic)

        // Build uTLS config.
        alpn := []string{"h2"}
        if !*h2only {
                alpn = []string{"h2", "http/1.1"}
        }
        uCfg := &utls.Config{
                ServerName:         sniValue,
                NextProtos:         alpn,
                InsecureSkipVerify: *insecure,
        }
        if *certPin != "" {
                uCfg.InsecureSkipVerify = true // verify manually via pin
                want := strings.ToLower(*certPin)
                uCfg.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
                        if len(rawCerts) == 0 {
                                return errors.New("utls-tunnel: server did not provide cert")
                        }
                        sum := sha256.Sum256(rawCerts[0])
                        got := hex.EncodeToString(sum[:])
                        if got != want {
                                return fmt.Errorf("utls-tunnel: cert fingerprint mismatch (pinning): got %s, want %s", got, want)
                        }
                        return nil
                }
        }

        // Listen on local TCP.
        ln, err := net.Listen("tcp", *listen)
        if err != nil {
                logger.Error("listen failed", "addr", *listen, "err", err)
                os.Exit(1)
        }
        defer ln.Close()
        logger.Info("local listener ready", "addr", ln.Addr().String())

        // Print actual port on stdout (first line) for parent process to read.
        fmt.Println(ln.Addr().(*net.TCPAddr).Port)
        os.Stdout.Sync()

        // Graceful shutdown on SIGINT/SIGTERM.
        ctx, cancel := context.WithCancel(context.Background())
        defer cancel()
        go func() {
                sigCh := make(chan os.Signal, 1)
                signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
                <-sigCh
                logger.Info("shutdown signal received")
                cancel()
                ln.Close()
        }()

        // Accept loop.
        for {
                conn, err := ln.Accept()
                if err != nil {
                        if ctx.Err() != nil {
                                return // shutdown
                        }
                        logger.Error("accept failed", "err", err)
                        continue
                }
                go handleConn(ctx, logger, conn, *remote, remoteHost, remotePort, helloID, uCfg, *noiseKey, *quic, echConfigList)
        }
}

// handleConn — handle one local connection: dial remote with uTLS or native
// crypto/tls (ECH mode), relay bytes. When noiseKey is non-empty: after TLS,
// do Noise IK handshake, relay via Noise.
func handleConn(ctx context.Context, logger *slog.Logger, localConn net.Conn,
        remote, remoteHost, remotePort string, helloID utls.ClientHelloID, uCfg *utls.Config, noiseKey string, useQUIC bool, echConfigList []byte) {
        defer localConn.Close()

        // ECH mode: use native crypto/tls (not uTLS).
        if len(echConfigList) > 0 {
                handleECHConn(ctx, logger, localConn, remote, uCfg, noiseKey, echConfigList)
                return
        }

        // 1a. QUIC mode: dial UDP + QUIC handshake (HTTP/3).
        if useQUIC {
                handleQUICConn(ctx, logger, localConn, remote, uCfg, noiseKey)
                return
        }

        // 1b. TCP mode: dial remote TCP (existing path).
        dialer := net.Dialer{Timeout: connectTimeout}
        rawConn, err := dialer.DialContext(ctx, "tcp", remote)
        if err != nil {
                logger.Error("dial remote failed", "remote", remote, "err", err)
                return
        }

        // 2. Wrap with uTLS UClient + handshake (Chrome ClientHello).
        uConn := utls.UClient(rawConn, uCfg, helloID)
        handshakeCtx, handshakeCancel := context.WithTimeout(ctx, handshakeTimeout)
        defer handshakeCancel()
        if err := uConn.HandshakeContext(handshakeCtx); err != nil {
                rawConn.Close()
                logger.Error("utls handshake failed", "remote", remote, "err", err)
                return
        }

        // 3. Verify ALPN negotiated h2 (HTTP/2 required for carrier).
        if uConn.ConnectionState().NegotiatedProtocol != "h2" {
                rawConn.Close()
                logger.Error("ALPN did not negotiate h2",
                        "negotiated", uConn.ConnectionState().NegotiatedProtocol)
                return
        }

        // 3.5. Noise layer (audit 2026-10-12): when --noise-key is set,
        // do Noise IK handshake after TLS. All subsequent bytes go through
        // Noise AEAD (ChaCha20-Poly1305). Dart client talks raw TCP to
        // local port — utls-tunnel does TLS + Noise.
        var relayConn net.Conn = uConn
        if noiseKey != "" {
                serverPub, err := hex.DecodeString(noiseKey)
                if err != nil || len(serverPub) != 32 {
                        rawConn.Close()
                        logger.Error("invalid noise key", "key", noiseKey, "err", err)
                        return
                }
                clientKP, err := v2.GenerateNoiseKeyPair()
                if err != nil {
                        rawConn.Close()
                        logger.Error("noise keypair generation failed", "err", err)
                        return
                }
                noiseConn := v2.NewNoiseClientConn(uConn, clientKP, serverPub)
                // NoiseConn.Read/Write triggers handshake on first call.
                // Do a test write to trigger handshake explicitly.
                if _, err := noiseConn.Write([]byte{}); err != nil {
                        rawConn.Close()
                        logger.Error("noise handshake failed", "err", err)
                        return
                }
                relayConn = noiseConn
                logger.Info("noise layer established", "client_pub", hex.EncodeToString(clientKP.Public))
        }

        logger.Info("tunnel established", "remote", remote, "local", localConn.RemoteAddr(),
                "noise", noiseKey != "")

        // 4. Relay bytes both ways: localConn <-> relayConn.
        done := make(chan struct{}, 2)
        // local → remote
        go func() {
                _, _ = io.CopyBuffer(relayConn, localConn, make([]byte, relayBufferSize))
                _ = relayConn.Close()
                done <- struct{}{}
        }()
        // remote → local
        go func() {
                _, _ = io.CopyBuffer(localConn, relayConn, make([]byte, relayBufferSize))
                done <- struct{}{}
        }()

        // Wait for both directions to close OR shutdown.
        select {
        case <-done:
                // One direction done. Close everything.
        case <-ctx.Done():
        }
        localConn.Close()
        rawConn.Close()
}

// handleECHConn — ECH mode: dial remote with native crypto/tls +
// EncryptedClientHelloConfigList. SNI is encrypted via HPKE (RFC 9460),
// DPI cannot see real servername. Trade-off: no uTLS fingerprint mimicry
// (native Go fingerprint). For passive DPI evasion (TSPU inspecting SNI),
// ECH is the strongest defense available in Go 1.26+.
//
// Auto-retry on ECHRejectionError (RFC 9460 §6.2):
// When server rotates ECH keypair, client's cached ECHConfigList becomes
// stale. Server responds with ECHRejectionError containing a RetryConfigList
// (server's hint: "use this new config list"). Client automatically retries
// handshake with RetryConfigList (max 1 retry). If RetryConfigList empty
// → server rejected ECH without retry hint → fail.
//
// Connection layout:
//
//   Dart carrier ── raw TCP ──> [local listener]
//                                    │
//                                    ├── crypto/tls handshake (native Go ClientHello)
//                                    │   + ECH extension (encrypted SNI)
//                                    │   ↓ (ECH rejected? retry with RetryConfigList)
//                                    │   ↓ (still rejected? fail)
//                                    │
//                                    └── relay bytes ──> [server host:port]
//                                            (optional Noise AEAD layer if --noise-key)
func handleECHConn(ctx context.Context, logger *slog.Logger, localConn net.Conn,
        remote string, uCfg *utls.Config, noiseKey string, echConfigList []byte) {

        // 1. Dial remote TCP.
        dialer := net.Dialer{Timeout: connectTimeout}
        rawConn, err := dialer.DialContext(ctx, "tcp", remote)
        if err != nil {
                logger.Error("ech: dial remote failed", "remote", remote, "err", err)
                return
        }

        // 2. Native crypto/tls with ECH config list.
        // ServerName = sniValue (real secret SNI — encrypted in ECH).
        // EncryptedClientHelloConfigList activates ECH extension.
        buildTLSConfig := func(configList []byte) *crypto_tls.Config {
                cfg := &crypto_tls.Config{
                        ServerName:                     uCfg.ServerName,
                        NextProtos:                     []string{"h2"},
                        MinVersion:                     crypto_tls.VersionTLS13, // ECH requires TLS 1.3
                        InsecureSkipVerify:             uCfg.InsecureSkipVerify,
                        EncryptedClientHelloConfigList: configList,
                }
                if uCfg.VerifyPeerCertificate != nil {
                        cfg.VerifyPeerCertificate = uCfg.VerifyPeerCertificate
                }
                return cfg
        }

        // 3. TLS handshake with auto-retry on ECHRejectionError.
        // RFC 9460: if server rejects ECH with retry config list, client
        // should retry with that list (max 1 retry).
        //
        // Two retry triggers:
        //   a) ECHRejectionError with non-empty RetryConfigList → use it.
        //   b) (fallback) If ECHRejected flag is false AND no error → server
        //      silently ignored ECH → log + return (no auto-refetch from
        //      /api/ech-config because that itself requires TLS).
        handshakeCtx, handshakeCancel := context.WithTimeout(ctx, handshakeTimeout)
        defer handshakeCancel()

        var tlsConn *crypto_tls.Conn
        currentConfigList := echConfigList
        maxRetries := 1
        for attempt := 0; attempt <= maxRetries; attempt++ {
                tlsConn = crypto_tls.Client(rawConn, buildTLSConfig(currentConfigList))
                if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
                        // Check if ECH was rejected with retry config list.
                        var echErr *crypto_tls.ECHRejectionError
                        if errors.As(err, &echErr) && len(echErr.RetryConfigList) > 0 && attempt < maxRetries {
                                logger.Info("ech: server rejected with retry config list, retrying",
                                        "attempt", attempt+1,
                                        "retry_list_bytes", len(echErr.RetryConfigList))
                                // Use server's hint for next attempt.
                                currentConfigList = echErr.RetryConfigList
                                // Need fresh rawConn — previous one is closed by failed handshake.
                                rawConn.Close()
                                rawConn, err = dialer.DialContext(ctx, "tcp", remote)
                                if err != nil {
                                        logger.Error("ech: redial after retry", "err", err)
                                        return
                                }
                                continue
                        }
                        rawConn.Close()
                        if errors.As(err, &echErr) {
                                logger.Error("ech: server rejected ECH (no retry hint)",
                                        "err", err, "retry_list_bytes", len(echErr.RetryConfigList))
                        } else {
                                logger.Error("ech: TLS handshake failed", "remote", remote, "err", err)
                        }
                        return
                }
                break // handshake succeeded
        }

        // 4. Verify ALPN negotiated h2.
        if tlsConn.ConnectionState().NegotiatedProtocol != "h2" {
                rawConn.Close()
                logger.Error("ech: ALPN did not negotiate h2",
                        "negotiated", tlsConn.ConnectionState().NegotiatedProtocol)
                return
        }

        // 5. Verify ECH was actually accepted by server.
        if !tlsConn.ConnectionState().ECHAccepted {
                rawConn.Close()
                logger.Error("ech: server rejected ECH (no ECH in final handshake)")
                return
        }

        // 5. Optional Noise layer (same as uTLS path).
        var relayConn net.Conn = tlsConn
        if noiseKey != "" {
                serverPub, err := hex.DecodeString(noiseKey)
                if err != nil || len(serverPub) != 32 {
                        rawConn.Close()
                        logger.Error("invalid noise key", "key", noiseKey, "err", err)
                        return
                }
                clientKP, err := v2.GenerateNoiseKeyPair()
                if err != nil {
                        rawConn.Close()
                        logger.Error("noise keypair generation failed", "err", err)
                        return
                }
                noiseConn := v2.NewNoiseClientConn(tlsConn, clientKP, serverPub)
                if _, err := noiseConn.Write([]byte{}); err != nil {
                        rawConn.Close()
                        logger.Error("noise handshake failed", "err", err)
                        return
                }
                relayConn = noiseConn
                logger.Info("noise layer established (ECH mode)", "client_pub", hex.EncodeToString(clientKP.Public))
        }

        logger.Info("ech tunnel established", "remote", remote,
                "local", localConn.RemoteAddr(), "noise", noiseKey != "")

        // 6. Relay bytes both ways: localConn <-> relayConn.
        done := make(chan struct{}, 2)
        go func() {
                _, _ = io.CopyBuffer(relayConn, localConn, make([]byte, relayBufferSize))
                _ = relayConn.Close()
                done <- struct{}{}
        }()
        go func() {
                _, _ = io.CopyBuffer(localConn, relayConn, make([]byte, relayBufferSize))
                done <- struct{}{}
        }()
        select {
        case <-done:
        case <-ctx.Done():
        }
        localConn.Close()
        rawConn.Close()
}

// pickClientHelloID — map user-facing fingerprint name → utls.ClientHelloID.
func pickClientHelloID(name string) utls.ClientHelloID {
        switch strings.ToLower(strings.TrimSpace(name)) {
        case "", "chrome":
                return utls.HelloChrome_Auto
        case "firefox":
                return utls.HelloFirefox_Auto
        case "safari":
                return utls.HelloSafari_Auto
        case "ios":
                return utls.HelloIOS_Auto
        case "random":
                return utls.HelloRandomized
        case "golang":
                // For testing only — gives standard Go fingerprint (no spoofing).
                return utls.HelloGolang
        default:
                return utls.HelloChrome_Auto
        }
}

// handleQUICConn — QUIC mode: dial UDP, do QUIC+HTTP/3 to remote,
// relay bytes between local TCP and remote QUIC stream.
// Same local TCP interface for Dart — no QUIC library needed in Dart.
func handleQUICConn(ctx context.Context, logger *slog.Logger, localConn net.Conn,
        remote string, uCfg *utls.Config, noiseKey string) {
        // Parse remote host:port.
        remoteHost, remotePort, err := net.SplitHostPort(remote)
        if err != nil {
                logger.Error("quic: parse remote", "remote", remote, "err", err)
                return
        }

        // QUIC uses standard crypto/tls (not uTLS — utls doesn't support QUIC).
        // ALPN: "h3" (HTTP/3).
        quicTLS := &crypto_tls.Config{
                ServerName:         uCfg.ServerName,
                NextProtos:         []string{"h3"},
                InsecureSkipVerify: uCfg.InsecureSkipVerify,
        }
        if uCfg.VerifyPeerCertificate != nil {
                quicTLS.VerifyPeerCertificate = uCfg.VerifyPeerCertificate
        }

        // Dial QUIC (UDP) to remote.
        quicCtx, quicCancel := context.WithTimeout(ctx, connectTimeout)
        defer quicCancel()
        remoteUDP := net.JoinHostPort(remoteHost, remotePort)
        conn, err := quic.DialAddr(quicCtx, remoteUDP, quicTLS, nil)
        if err != nil {
                logger.Error("quic: dial failed", "remote", remoteUDP, "err", err)
                return
        }
        defer conn.CloseWithError(0, "done")

        logger.Info("QUIC tunnel established", "remote", remoteUDP)

        // Open a bidirectional QUIC stream.
        stream, err := conn.OpenStreamSync(ctx)
        if err != nil {
                logger.Error("quic: open stream", "err", err)
                return
        }
        defer stream.Close()

        // Relay bytes: local TCP <-> QUIC stream.
        done := make(chan struct{}, 2)
        go func() {
                _, _ = io.CopyBuffer(stream, localConn, make([]byte, relayBufferSize))
                stream.Close()
                done <- struct{}{}
        }()
        go func() {
                _, _ = io.CopyBuffer(localConn, stream, make([]byte, relayBufferSize))
                done <- struct{}{}
        }()
        select {
        case <-done:
        case <-ctx.Done():
        }
}
