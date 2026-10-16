// Package backuppcvpn implements the BackupPC VPN stealth proxy protocol.
//
// BackupPC VPN is a censorship-evasion proxy protocol designed to bypass
// TSPU (Russian DPI), GFW (China), and other network-level censorship
// systems. The protocol disguises proxy traffic as legitimate BackupPC
// Storage Node backup traffic over gRPC/HTTP/2.
//
// # Architecture
//
// The protocol stack (top → bottom):
//
//	┌────────────────────────────────────────────────────────────┐
//	│ Application (SOCKS5 / TUN inbound)                          │
//	├────────────────────────────────────────────────────────────┤
//	│ VLESS payload (target host:port + raw TCP bytes)            │
//	├────────────────────────────────────────────────────────────┤
//	│ HTTP/2 frames (POST /backuppc.BackupService/BackupStream)   │
//	│ + X-Backup-Session-ID, X-Backup-Chunk-Index,                │
//	│   X-Backup-Auth, X-Backup-Timestamp (V2)                    │
//	├────────────────────────────────────────────────────────────┤
//	│ [OPTIONAL] Noise IK AEAD (ChaCha20-Poly1305)                │
//	├────────────────────────────────────────────────────────────┤
//	│ [OPTIONAL] ECH (RFC 9460, SNI encryption via HPKE)          │
//	├────────────────────────────────────────────────────────────┤
//	│ TLS 1.3 + ALPN ["h2", "http/1.1"]                          │
//	│ [OPTIONAL] uTLS HelloChrome_Auto (JA3 mimicry)              │
//	├────────────────────────────────────────────────────────────┤
//	│ TCP (HTTP/2 default) OR UDP (HTTP/3 fallback)              │
//	└────────────────────────────────────────────────────────────┘
//
// # Versions
//
// This package implements both v1.0 (legacy) and v2.0.2 (current) of the
// protocol. See docs/protocols/backuppc-v1.md and backuppc-v2-full.md for
// the full specification.
//
//	v1.0  Original: gRPC + VLESS + TLS 1.3 + basic padding (no replay protection)
//	v2.0  Marvia-inspired: V2 auth (timestamp+HMAC) + replay guard +
//	      cover fallback + uTLS + Noise IK + QUIC fallback + encrypted users.json
//	v2.0.2 ECH (RFC 9460) activation + hot-reload + auto-retry
//
// # Key features
//
//   - ECH (Encrypted Client Hello, RFC 9460): SNI encrypted via HPKE,
//     invisible to passive DPI. Hot-reloadable keypair (no server restart).
//   - V2 auth (WireGuard-style): timestamp + HMAC-SHA256 + seen-hash
//     memory for replay protection.
//   - Cover fallback: byte-identical HTML response on ALL probe kinds,
//     indistinguishable from random scan.
//   - Inner Noise IK layer: ChaCha20-Poly1305 AEAD protects data even
//     if TLS is compromised by corporate MITM with custom CA.
//   - Adaptive padding: random frame size + size-based padding buckets
//     to defeat TLS-in-TLS detection.
//   - QUIC (HTTP/3) fallback: UDP transport when TCP HTTP/2 is blocked.
//   - uTLS fingerprint spoofing: Chrome JA3 mimicry (client-side only).
//
// # Quick start (server)
//
//	import "backuppc-core/internal/backuppcvpn"
//
//	cfg := &backuppcvpn.ServerConfig{
//	    Listen:    "[::]:8443",
//	    Host:      "cdn.example.com",
//	    DataDir:   "/var/lib/backuppc",
//	    EnableECH: true,
//	    EnableNoiseLayer: true,
//	    EnableQUIC: true,
//	}
//	srv, err := backuppcvpn.NewServer(cfg, logger)
//	if err != nil { ... }
//	srv.Serve(listener)
//
// # Quick start (client via utls-tunnel sidecar)
//
//	utls-tunnel --listen 127.0.0.1:0 \
//	            --remote cdn.example.com:8443 \
//	            --sni cdn.example.com \
//	            --ech-config-list <base64> \
//	            --noise-key <hex> \
//	            --quic
//
// See docs/protocols/backuppc-v2-full.md for the full specification.
//
// # References
//
//   - RFC 9460: Encrypted Client Hello (ECH)
//   - RFC 7748: X25519 ECDH
//   - RFC 8439: ChaCha20-Poly1305 AEAD
//   - RFC 9000: QUIC
//   - Noise Protocol Framework (IK pattern)
//   - Marvia VP1 (primary inspiration)
package backuppcvpn
