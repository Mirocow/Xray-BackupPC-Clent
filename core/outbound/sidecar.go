// Package outbound — sidecar.go: utls-tunnel sidecar spawning (audit 2026-10-13).
//
// When V2 transport features are enabled (uTLS fingerprint, ECH, Noise, QUIC
// fallback), the router's xray binary spawns utls-tunnel as a local TCP
// sidecar. The backuppc.Client connects to the sidecar's local port via h2c
// (HTTP/2 over cleartext TCP). The sidecar wraps bytes in uTLS+TLS+ECH+
// Noise+QUIC and relays to the real server.
//
// Architecture:
//
//	[outbound.Handler] --spawns--> [utls-tunnel sidecar :127.0.0.1:port]
//	                                          |
//	[backuppc.Client] --h2c TCP--> [sidecar local port]
//	                                          |
//	                                          +--uTLS/ECH/Noise/QUIC--> [server]
//
// When to spawn: when cfg.UtlsTunnelPath is non-empty AND any of:
//   - cfg.UtFingerprint (uTLS JA3 mimicry)
//   - cfg.EchConfigList or cfg.EchAutoFetch (ECH SNI encryption)
//   - cfg.NoisePubKey (Noise IK inner layer)
//   - cfg.QuicFallback (HTTP/3 over UDP)
//
// When NONE of these are set, the client connects directly to the server
// with stdlib TLS (V1 behavior). UtlsTunnelPath alone (without any V2
// transport feature) is a no-op — the sidecar wouldn't add any value.
package outbound

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"backuppc"
)

// sidecarManager — manages the lifetime of a utls-tunnel sidecar process.
// One per outbound.Handler. Started lazily on first DialLogical() call
// when V2 features are enabled.
type sidecarManager struct {
	binaryPath string  // path to utls-tunnel binary
	remote     string  // server host:port (real)
	sni        string  // SNI donor domain
	insecure   bool    // skip cert verify (tests only)
	certPin    string  // SHA-256 cert pin (hex)

	// V2 transport feature flags (passed to sidecar as CLI flags).
	utFingerprint string // chrome|firefox|safari|ios|random
	echConfigList string // base64 ECHConfigList (manual)
	echAutoFetch  bool   // auto-fetch ECHConfigList from /api/ech-config
	noisePubKey   string // server Noise X25519 public key (hex)
	quicFallback  bool   // HTTP/3 over UDP when TCP HTTP/2 blocked

	// Runtime state.
	mu        sync.Mutex
	cmd       *exec.Cmd
	localAddr string // 127.0.0.1:<port> — set after start()
	started   bool
}

// newSidecarManager — constructs a manager from a backuppc.ClientConfig.
// Returns nil when sidecar isn't needed (no V2 transport features set,
// OR binary path is empty).
func newSidecarManager(cfg *backuppc.ClientConfig) *sidecarManager {
	if cfg.UtlsTunnelPath == "" {
		return nil // sidecar not configured
	}
	// Spawn only when at least one V2 transport feature is active.
	// V2 auth alone (useV2Auth=true) doesn't need sidecar — that's just
	// HTTP headers, handled inline by the client library.
	if cfg.UtFingerprint == "" && !cfg.EchAutoFetch && cfg.EchConfigList == "" &&
		cfg.NoisePubKey == "" && !cfg.QuicFallback {
		return nil // no V2 transport features → no sidecar
	}

	// Split ServerAddr into host:port for --remote flag.
	remote := cfg.ServerAddr
	sni := cfg.Host
	if sni == "" {
		// Fall back to host part of ServerAddr.
		if h, _, err := net.SplitHostPort(remote); err == nil {
			sni = h
		} else {
			sni = remote
		}
	}

	return &sidecarManager{
		binaryPath:    cfg.UtlsTunnelPath,
		remote:        remote,
		sni:           sni,
		insecure:      cfg.Insecure,
		certPin:       cfg.CertFingerprint,
		utFingerprint:  cfg.UtFingerprint,
		echConfigList: cfg.EchConfigList,
		echAutoFetch:  cfg.EchAutoFetch,
		noisePubKey:   cfg.NoisePubKey,
		quicFallback:  cfg.QuicFallback,
	}
}

// start — launches the sidecar process, reads its local port from stdout,
// returns the local address (e.g., "127.0.0.1:54321"). Idempotent —
// returns existing localAddr if already started.
func (m *sidecarManager) start(ctx context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.started {
		return m.localAddr, nil
	}

	args := []string{
		"--listen", "127.0.0.1:0", // random port, printed to stdout
		"--remote", m.remote,
		"--sni", m.sni,
	}
	if m.utFingerprint != "" {
		args = append(args, "--fingerprint", m.utFingerprint)
	}
	if m.insecure {
		args = append(args, "--insecure")
	}
	if m.certPin != "" {
		args = append(args, "--cert-fingerprint", m.certPin)
	}
	if m.echAutoFetch {
		// ECH auto-fetch: sidecar will fetch ECHConfigList from server's
		// /api/ech-config before TLS handshake.
		args = append(args, "--ech-config-list", "auto")
	} else if m.echConfigList != "" {
		args = append(args, "--ech-config-list", m.echConfigList)
	}
	if m.noisePubKey != "" {
		args = append(args, "--noise-key", m.noisePubKey)
	}
	if m.quicFallback {
		args = append(args, "--quic")
	}

	cmd := exec.CommandContext(ctx, m.binaryPath, args...)
	cmd.Stdout = nil // we'll use a pipe to read port
	cmd.Stderr = nil // logged elsewhere if needed

	// Pipe stdout to read the port number on first line.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("sidecar: stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("sidecar: start %s: %w", m.binaryPath, err)
	}

	// Read first line: should be the port number.
	// utls-tunnel prints port to stdout on startup (see cmd/utls-tunnel/main.go:186).
	portCh := make(chan struct {
		port int
		err  error
	}, 1)
	go func() {
		defer close(portCh)
		reader := bufio.NewReader(stdout)
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			portCh <- struct {
				port int
				err  error
			}{0, fmt.Errorf("sidecar: read port: %w", err)}
			return
		}
		line = strings.TrimSpace(line)
		port, perr := strconv.Atoi(line)
		if perr != nil {
			portCh <- struct {
				port int
				err  error
			}{0, fmt.Errorf("sidecar: parse port %q: %w", line, perr)}
			return
		}
		portCh <- struct {
			port int
			err  error
		}{port, nil}
	}()

	select {
	case res := <-portCh:
		if res.err != nil {
			_ = cmd.Process.Kill()
			return "", res.err
		}
		m.localAddr = fmt.Sprintf("127.0.0.1:%d", res.port)
		m.cmd = cmd
		m.started = true
		return m.localAddr, nil
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		return "", errors.New("sidecar: timeout waiting for port")
	}
}

// stop — gracefully kills the sidecar process. Safe to call multiple times.
func (m *sidecarManager) stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.started {
		return
	}
	if m.cmd != nil && m.cmd.Process != nil {
		_ = m.cmd.Process.Kill()
		_, _ = m.cmd.Process.Wait()
	}
	m.started = false
	m.cmd = nil
	m.localAddr = ""
}
