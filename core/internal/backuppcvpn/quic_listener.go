// Package backupemulator — quic_listener.go: QUIC transport fallback
// (audit 2026-10-12, ТСПУ defense).
//
// When ТСПУ/GFW blocks HTTP/2 ALPN over TCP, QUIC (HTTP/3) over UDP
// provides an alternative transport. The carrier protocol (gRPC +
// VLESS) stays identical — only the transport changes from HTTP/2
// over TCP to HTTP/3 over QUIC.
//
// Architecture:
//   Server: TCP listener (HTTP/2) + UDP listener (QUIC/HTTP/3)
//   Client: try HTTP/2 first, fall back to HTTP/3 if blocked
//
// QUIC advantages:
//   - UDP-based — bypasses TCP-level DPI rules
//   - Connection migration — client IP change doesn't break session
//   - 0-RTT resumption — faster reconnection
//   - Built-in encryption (QUIC has its own TLS)
//   - No head-of-line blocking (independent streams)
//
// QUIC disadvantages:
//   - UDP can be blocked entirely (some networks block all UDP)
//   - Different traffic pattern (UDP vs TCP) — ТСПУ can detect
//   - QUIC is more CPU-intensive (per-packet encryption)
//
// Config: ServerConfig.EnableQUIC bool + QUICListen string (default: same port as TCP)

package backuppcvpn

import (
        "context"
        "crypto/tls"
        "fmt"
        "net"

        "github.com/sagernet/quic-go/http3"
)

// startQUICListener — start an HTTP/3 (QUIC) listener alongside the TCP one.
// Uses the same TLS cert + mux handler. Clients connect via HTTP/3 when
// TCP HTTP/2 is blocked by ТСПУ.
//
// ECH (audit 2026-10-13): QUIC uses TLS 1.3 internally, so ECH works the
// same way as TCP HTTP/2. Server's EncryptedClientHelloKeys are injected
// via GetConfigForClient — hot-reloadable (atomic.Pointer swap on
// RotateECHKey() reflects immediately on next QUIC handshake).
//
// Returns when context is cancelled or listener fails.
func (s *Server) startQUICListener(ctx context.Context, addr string) error {
        if !s.cfg.EnableQUIC {
                return nil
        }

        // Build QUIC-compatible TLS config.
        // QUIC requires TLS 1.3 (QUIC doesn't support TLS 1.2).
        // ALPN must include "h3" (HTTP/3).
        //
        // ECH keys are NOT set here at base config level — only via
        // GetConfigForClient callback (same pattern as TCP HTTP/2 listener).
        // This makes ECH hot-reloadable: RotateECHKey() swaps s.echState
        // (atomic.Pointer), next QUIC handshake calls GetConfigForClient
        // which reads fresh keys from s.echServerKeys().
        cert, _ := s.certBox.Load().(tls.Certificate)
        quicTLS := &tls.Config{
                Certificates: []tls.Certificate{cert},
                MinVersion:   tls.VersionTLS13,
                NextProtos:   []string{"h3"},
                // Allow client to specify SNI (for domain-donor masquerade).
                GetConfigForClient: func(chi *tls.ClientHelloInfo) (*tls.Config, error) {
                        s.recordClientHello(chi)
                        c, _ := s.certBox.Load().(tls.Certificate)
                        return &tls.Config{
                                Certificates: []tls.Certificate{c},
                                MinVersion:   tls.VersionTLS13,
                                NextProtos:   []string{"h3"},
                                // ECH keys from atomic.Pointer — hot-reloadable.
                                // Same pattern as TCP HTTP/2 listener: when
                                // s.echState shows ECH disabled → keys=nil
                                // → server ignores ECH extension entirely.
                                EncryptedClientHelloKeys: s.echServerKeys(),
                        }, nil
                },
        }

        // Create UDP listener.
        udpAddr, err := net.ResolveUDPAddr("udp", addr)
        if err != nil {
                return fmt.Errorf("quic: resolve udp addr %s: %w", addr, err)
        }
        udpConn, err := net.ListenUDP("udp", udpAddr)
        if err != nil {
                return fmt.Errorf("quic: listen udp %s: %w", addr, err)
        }

        // Create HTTP/3 server with the same mux handler.
        h3Server := &http3.Server{
                Handler:   s.ddosMiddleware(s.recoverMiddleware(s.srv.Handler)),
                TLSConfig: quicTLS,
        }

        s.logger.Info("QUIC (HTTP/3) listener starting",
                "addr", addr, "cert_fingerprint", CertFingerprint(cert),
                "noise", s.NoiseEnabled(),
                "ech", s.ECHEnabled())

        // Serve HTTP/3 over QUIC.
        // This blocks until context is cancelled or listener fails.
        go func() {
                <-ctx.Done()
                udpConn.Close()
                h3Server.Close()
        }()

        return h3Server.Serve(udpConn)
}

// QUICEnabled — whether QUIC transport is active on this server.
func (s *Server) QUICEnabled() bool {
        return s.cfg.EnableQUIC
}
