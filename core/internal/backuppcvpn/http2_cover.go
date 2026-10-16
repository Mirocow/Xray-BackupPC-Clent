// Package backupemulator — http2_cover.go: cover-page interceptor that
// activates at the HTTP/2 (ALPN "h2") entry point via TLSNextProto override.
//
// This is the canonical fix for the "Go http2.Server sends GOAWAY on
// malformed HTTP/2 preface" fingerprint that distinguishes our carrier
// port from a real nginx (audit 2026-10-12, Marvia-inspired TSPU defense).
//
// Why we cannot use the cover_listener.go listener-wrap approach:
//
//   Go's net/http.Server.serve() does a type assertion `c.rwc.(*tls.Conn)`
//   on every accepted conn to read the negotiated ALPN protocol. Only
//   if the conn is literally *tls.Conn does it dispatch to
//   s.TLSNextProto["h2"]. A wrapper type like *coverConn (even if it
//   embeds *tls.Conn) is NOT *tls.Conn — Go type assertions check dynamic
//   type, not embed-of. So wrapping the listener silently breaks HTTP/2:
//   HTTP/2 clients fall back to HTTP/1.1 parsing which then fails with
//   "http2: frame too large" because the parser sees the HTTP/2 preface
//   "PRI * HTTP/2.0..." and tries to interpret it as HTTP/1.1 headers.
//   (Confirmed by TestCoverFallbackIdentical failing with that exact
//   error message when the cover_listener wrap was activated.)
//
// Why we cannot peek + delegate to the original TLSNextProto["h2"] handler:
//
//   The original handler signature is `func(*http.Server, *tls.Conn, http.Handler)`.
//   It receives a *tls.Conn — but we've already consumed 24 bytes from it
//   via bufio.Peek. We can't push those bytes back into *tls.Conn (TLS
//   state machine has advanced). So the original handler's http2.Server
//   would read the bytes AFTER our peek — which are NOT the HTTP/2 preface
//   (e.g. the first SETTINGS frame) → http2 rejects the conn.
//
// Solution:
//
//   Pre-set s.srv.TLSNextProto["h2"] BEFORE http.Server.ServeTLS() runs.
//   Go's net/http.onceSetNextProtoDefaults() sees the entry already exists
//   and SKIPS http2ConfigureServer (see net/http/server.go:3756-3761).
//   Our handler then:
//     1. Receives *tls.Conn directly from Go's http.Server.serve()
//     2. Wraps it with bufio.Reader
//     3. Peeks 24 bytes (HTTP/2 connection preface)
//     4. If invalid preface: writes cover HTML, closes conn
//     5. If valid preface: calls http2.Server.ServeConn directly with
//        a prependConn (returns peeked bytes first, then reads from
//        *tls.Conn) — bypasses http.Server.serve() entirely for HTTP/2,
//        so we don't hit the *tls.Conn type-assertion limit.
//
// Dependencies:
//   - golang.org/x/net/http2 — external package (stdlib's http2 bundle is
//     internal net/http/h2_bundle.go, not importable). We already have
//     golang.org/x/net in go.mod for http2-aware transports.

package backuppcvpn

import (
        "bufio"
        "bytes"
        "crypto/tls"
        "io"
        "net/http"
        "strconv"
        "time"

        "golang.org/x/net/http2"
)

// http2PrefaceBytes — HTTP/2 connection preface (RFC 7540 §3.5).
// Same as http2Preface in cover_conn.go; duplicated here so this file
// is self-contained and cover_conn.go can stay dormant (its listener-wrap
// approach doesn't work — see file header).
var http2PrefaceBytes = []byte("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

// setupHTTP2WithCoverHandler — pre-installs our cover-aware HTTP/2 handler
// into s.srv.TLSNextProto["h2"], so Go's stdlib http.Server sees it and
// skips its own http2ConfigureServer (which would otherwise install the
// default handler that sends GOAWAY on malformed prefaces).
//
// Must be called AFTER s.srv is created (so TLSNextProto is non-nil-capable)
// and BEFORE s.srv.ServeTLS/Serve is called. We call it from NewServer()
// right after s.srv is built.
//
// Behavior:
//   - Creates an http2.Server instance configured from s.srv.HTTP2 fields
//     (MaxConcurrentStreams, MaxReceiveBufferPerConnection, etc.).
//   - Calls http2.ConfigureServer(s.srv, h2srv) to let http2 setup any
//     internal state (NextProtos, RegisterOnShutdown, etc.) on s.srv.
//     This also sets s.srv.TLSNextProto["h2"] to the default handler.
//   - Overrides s.srv.TLSNextProto["h2"] with our cover-aware handler
//     (closure captures h2srv so we can ServeConn directly).
//
// Net effect: every TLS+ALPN-h2 connection hits our handler first. We
// peek the HTTP/2 preface; if invalid (GFW/ТСПУ scanner garbage), we
// serve cover HTML (200 OK, identical to probe response). If valid,
// we serve HTTP/2 via http2.Server.ServeConn — bypassing http.Server's
// HTTP/1.1 fallback path entirely.
func (s *Server) setupHTTP2WithCoverHandler() {
        // Build http2.Server from s.srv.HTTP2 config (if set) or defaults.
        h2srv := &http2.Server{
                IdleTimeout: 120 * time.Second,
        }
        if s.srv.HTTP2 != nil {
                cfg := s.srv.HTTP2
                if cfg.MaxConcurrentStreams > 0 {
                        h2srv.MaxConcurrentStreams = uint32(cfg.MaxConcurrentStreams)
                }
                if cfg.MaxReadFrameSize > 0 {
                        h2srv.MaxReadFrameSize = uint32(cfg.MaxReadFrameSize)
                }
                if cfg.MaxDecoderHeaderTableSize > 0 {
                        h2srv.MaxDecoderHeaderTableSize = uint32(cfg.MaxDecoderHeaderTableSize)
                }
                if cfg.MaxEncoderHeaderTableSize > 0 {
                        h2srv.MaxEncoderHeaderTableSize = uint32(cfg.MaxEncoderHeaderTableSize)
                }
                if cfg.MaxReceiveBufferPerConnection > 0 {
                        h2srv.MaxUploadBufferPerConnection = int32(cfg.MaxReceiveBufferPerConnection)
                }
                if cfg.MaxReceiveBufferPerStream > 0 {
                        h2srv.MaxUploadBufferPerStream = int32(cfg.MaxReceiveBufferPerStream)
                }
                if cfg.WriteByteTimeout > 0 {
                        h2srv.WriteByteTimeout = cfg.WriteByteTimeout
                }
                if cfg.PingTimeout > 0 {
                        h2srv.PingTimeout = cfg.PingTimeout
                }
                if cfg.SendPingTimeout > 0 {
                        // http2.Server has ReadIdleTimeout for client-style pings; for
                        // server it's not directly exposed. We map SendPingTimeout →
                        // ReadIdleTimeout (close enough semantically: idle period before
                        // sending a ping). Ignored if not applicable.
                        h2srv.ReadIdleTimeout = cfg.SendPingTimeout
                }
        }
        // ConfigureServer also sets s.srv.TLSNextProto["h2"] with default
        // handler. We capture this side effect then override.
        if err := http2.ConfigureServer(s.srv, h2srv); err != nil {
                // Don't fail NewServer on this — log and continue. Cover
                // protection is best-effort; basic TLS+HTTP/2 still works.
                s.logger.Warn("http2.ConfigureServer failed; cover handler not installed",
                        "err", err)
                return
        }
        // Save the http2.Server instance for use in our handler.
        s.h2server = h2srv
        // Override s.srv.TLSNextProto["h2"] with our cover-aware handler.
        // Go's onceSetNextProtoDefaults checks `if _, ok := s.TLSNextProto["h2"]; ok { return }`
        // so it won't re-install the default handler over our override.
        s.srv.TLSNextProto[http2.NextProtoTLS] = func(hs *http.Server, c *tls.Conn, h http.Handler) {
                s.serveHTTP2WithCover(c, h)
        }
}

// serveHTTP2WithCover — our HTTP/2 entry point. Receives *tls.Conn from
// Go's http.Server.serve() after ALPN "h2" was negotiated.
//
// Steps:
//   1. Wrap *tls.Conn with bufio.Reader.
//   2. Peek 24 bytes (HTTP/2 connection preface).
//   3. If preface invalid OR short read: write cover HTML, close conn.
//      This is the TSPU/GFW scanner case — instead of Go's default
//      GOAWAY+close (distinguishable from nginx), we serve the same
//      cover HTML that the HTTP/1.1 path serves for probe requests.
//   4. If preface valid: call http2.Server.ServeConn with a prependConn
//      that returns peeked bytes first, then reads from *tls.Conn.
//      Bypasses http.Server's HTTP/1.1 path entirely for HTTP/2 —
//      no risk of "frame too large" misparse.
func (s *Server) serveHTTP2WithCover(c *tls.Conn, h http.Handler) {
        // Set a peek deadline: if the client doesn't send 24 bytes
        // (HTTP/2 preface length) within 5 seconds, treat as a slow
        // scanner and serve cover HTML. Without this, bufio.Peek blocks
        // indefinitely on idle connections (http.Server's IdleTimeout
        // applies only to fully-idle post-handshake conns, not to
        // in-progress TLSNextProto handlers).
        peekDeadline := 5 * time.Second
        _ = c.SetReadDeadline(time.Now().Add(peekDeadline))
        br := bufio.NewReaderSize(c, 4096)
        preface, err := br.Peek(len(http2PrefaceBytes))
        // Clear the deadline — http2.Server sets its own per-frame deadlines.
        _ = c.SetReadDeadline(time.Time{})
        if err != nil || !bytes.Equal(preface, http2PrefaceBytes) {
                // Invalid preface → cover HTML (THE FIX).
                // This branch covers:
                //   - Garbage bytes (Peek returns 24, Equal fails)
                //   - Short read (Peek returns <24 with ErrUnexpectedEOF)
                //   - Timeout (Peek returns 0 with timeout error)
                //   - HTTP/1.1 traffic (e.g. "GET / HTTP/1.1..." — bytes don't match)
                writeCoverResponseToConn(c)
                _ = c.Close()
                return
        }
        // CRITICAL: Peek(24) does NOT advance the read position. Without
        // discarding, br.Read() would return the preface bytes AGAIN,
        // corrupting the HTTP/2 stream (server sees preface where it
        // expects SETTINGS frame → FRAME_SIZE_ERROR GOAWAY).
        // Discard(24) consumes 24 bytes from the buffer; subsequent
        // br.Read() starts at the byte right after the preface (the
        // client's first SETTINGS frame header).
        if _, err := br.Discard(len(http2PrefaceBytes)); err != nil {
                // Should never fail — we just Peek'd 24 bytes successfully.
                _ = c.Close()
                return
        }
        // Valid preface → serve HTTP/2 via http2CoverConn. The conn embeds
        // *tls.Conn (for Write/Close/LocalAddr/RemoteAddr/SetDeadline) but
        // overrides Read() to read from the bufio.Reader — which has the
        // client's first SETTINGS frame (and possibly more) buffered after
        // our Peek(24)+Discard(24).
        //
        // Without the bufio.Reader wrap, http2.Server reads the post-preface
        // bytes directly from *tls.Conn, which works for the first byte but
        // would bypass any bytes the bufio.Reader had already buffered from
        // the initial Peek's underlying read. Wrapping with br is mandatory.
        hc := &http2CoverConn{
                Conn: c,
                br:   br,
        }
        opts := &http2.ServeConnOpts{
                Handler:           h,
                BaseConfig:        s.srv,
                SawClientPreface:  true, // we already consumed+validated preface via Peek+Discard
        }
        // ServeConn blocks until conn closes. Caller (http.Server.serve's
        // TLSNextProto dispatcher) returns, http.Server treats this conn
        // as fully handled (it is). ServeConn returns no error (it logs
        // internally); nothing to handle here.
        s.h2server.ServeConn(hc, opts)
}

// http2CoverConn — wraps *tls.Conn + bufio.Reader for HTTP/2 cover-page
// interception. Embeds *tls.Conn so Write/Close/LocalAddr/RemoteAddr/
// SetDeadline/etc. all delegate to the TLS conn (http2.Server expects
// net.Conn). Read() is overridden to read from bufio.Reader.
//
// Why we need bufio.Reader: Peek(24)+Discard(24) leave the client's
// first SETTINGS frame (and possibly more) buffered in the bufio.Reader.
// If we let http2.Server read directly from *tls.Conn, those buffered
// bytes are lost — http2.Server would see nothing or garbage after the
// preface → GOAWAY PROTOCOL_ERROR or FRAME_SIZE_ERROR.
//
// By overriding Read to go through br.Read(), http2.Server reads the
// buffered SETTINGS frame from bufio.Reader, then continues reading
// from *tls.Conn when the buffer empties.
type http2CoverConn struct {
        *tls.Conn
        br *bufio.Reader
}

// Read — override *tls.Conn.Read to read from bufio.Reader.
// First call returns the post-preface bytes (client's SETTINGS frame);
// subsequent calls continue from bufio.Reader, which auto-refills from
// *tls.Conn when its internal buffer empties.
func (c *http2CoverConn) Read(p []byte) (int, error) {
        return c.br.Read(p)
}

// writeCoverResponseToConn — write HTTP/1.1 200 OK + cover HTML directly
// to a *tls.Conn, then close. Used by serveHTTP2WithCover when the preface
// check fails.
//
// Identical wire bytes to Server.serveCoverPage() — same headers, same
// body, same Server/X-Powered-By values. This is the indistinguishability
// invariant: a scanner that sends garbage after ALPN-h2 negotiation gets
// the SAME response as a random visitor hitting GET / on the carrier port.
//
// 'Connection: close' is set so we can close the conn immediately after
// write — http2 clients expecting keep-alive get a clean connection close,
// which is also what nginx does for malformed HTTP/2 prefaces (it returns
// 400 + closes, but our response is 200 + cover HTML instead — see
// TSPU-DEFENSE.md for why 200 is better than 400 for blending in).
func writeCoverResponseToConn(c *tls.Conn) {
        resp := "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/html; charset=utf-8\r\n" +
                "Server: " + coverServerHeader + "\r\n" +
                "X-Powered-By: " + coverPoweredByHeader + "\r\n" +
                "X-Backup-Storage: backup-pool-01\r\n" +
                "Cache-Control: no-store, no-cache, must-revalidate\r\n" +
                "Pragma: no-cache\r\n" +
                "Expires: 0\r\n" +
                "Content-Length: " + strconv.Itoa(len(coverHTML)) + "\r\n" +
                "Connection: close\r\n" +
                "\r\n" +
                coverHTML
        _ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
        _, _ = io.WriteString(c, resp)
}
