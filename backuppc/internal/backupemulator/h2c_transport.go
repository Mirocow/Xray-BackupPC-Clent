// Package backupemulator — h2c_transport.go: HTTP/2 cleartext transport for
// sidecar mode (audit 2026-10-13).
//
// When the client uses utls-tunnel sidecar (cfg.SidecarAddr is set), it
// needs to send HTTP/2 frames over plain TCP (no TLS) to the sidecar's
// local listener. The sidecar then wraps them in uTLS+TLS+ECH+Noise and
// relays to the real server.
//
// Go's stdlib http.Transport with ForceAttemptHTTP2=true only negotiates
// HTTP/2 via ALPN during TLS handshake — that doesn't work for cleartext
// TCP. We use golang.org/x/net/http2.Transport with AllowHTTP=true +
// DialTLS returning a plain TCP conn (no TLS), known as HTTP/2 with
// prior knowledge (RFC 7540 §3.4 starts with PRI * HTTP/2.0).
package backupemulator

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"time"

	"golang.org/x/net/http2"
)

// newH2CTransport builds an HTTP/2-over-TCP (prior knowledge) RoundTripper
// for sidecar mode. Returns *http2.Transport (which satisfies ChunkCloser
// via CloseIdleConnections).
//
// dialCtx is the optional custom dialer (router's outbound.Handler passes
// Xray's internet.Dialer for VPN-protect on Android). nil → standard
// net.Dialer.
//
// The transport sends HTTP/2 frames directly over TCP — no TLS, no ALPN.
// The sidecar's local listener receives raw bytes, wraps in uTLS+TLS to
// the server. Server sees HTTP/2 inside TLS (single TLS layer).
//
// When sidecar is NOT used (cfg.SidecarAddr == ""), the standard https
// path is taken in DialChunk — TLS+ALPN h2 negotiation as before.
func newH2CTransport(dialCtx func(ctx context.Context, network, addr string) (net.Conn, error)) *http2.Transport {
	dial := dialCtx
	if dial == nil {
		dialer := &net.Dialer{Timeout: 10 * time.Second}
		dial = func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, addr)
		}
	}

	return &http2.Transport{
		// AllowHTTP=true + http:// URL scheme → http2.Transport treats it as
		// h2c (HTTP/2 over cleartext, prior knowledge). No TLS upgrade.
		AllowHTTP: true,
		// DialTLSContext: returns plain TCP conn (no TLS) regardless of cfg.
		// Called for both http:// and https:// URLs (when AllowHTTP=true).
		// We always return raw TCP — sidecar's local listener is plain TCP.
		DialTLSContext: func(ctx context.Context, network, addr string, cfg *tls.Config) (net.Conn, error) {
			_ = cfg // ignored — sidecar handles TLS to remote
			return dial(ctx, network, addr)
		},
		DisableCompression: true,
	}
}

// Compile-time assertions: both transports satisfy ChunkCloser interface
// (CloseIdleConnections method). DialChunk() can treat them uniformly.
var _ ChunkCloser = (*http2.Transport)(nil)
var _ ChunkCloser = (*http.Transport)(nil)
