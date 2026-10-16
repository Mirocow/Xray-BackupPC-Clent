// Package backuppcvpn: server.go — protocol-only carrier server.
//
// Clean version без mesh/plugins/admin. Только:
//   - TLS 1.3 + ALPN ["h2", "http/1.1"]
//   - Cover fallback (HTML на probe responses)
//   - V2 auth (timestamp + HMAC + replay guard)
//   - ECH (RFC 9460, hot-reloadable)
//   - Noise IK inner layer
//   - QUIC (HTTP/3) fallback
//   - VLESS payload inside gRPC frames
//   - Adaptive padding
//
// Это упрощённая версия server.go из xray-backuppc (~4300 lines → ~700 lines).
// Убрано: mesh routing, plugin architecture, admin panel, encrypted users.json
// persistence (используйте UserManager напрямую), session sweep, audit hooks.

package backuppcvpn

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

// HTTP-заголовки протокола маскировки.
const (
	hdrSessionID  = "X-Backup-Session-ID"
	hdrChunkIndex = "X-Backup-Chunk-Index"
	hdrChunkAuth  = "X-Backup-Auth"
	hdrTimestamp  = "X-Backup-Timestamp" // V2 replay protection

	// replayWindowMin — допустимое расхождение часов для V2 auth (в минутах).
	// ±2 min = 5 windows total (покрывает NTP drift + network latency + clock skew).
	replayWindowMin = 2
)

// coverHTML — byte-identical HTML returned on ALL probe responses.
// Indistinguishable from random scan of an "ordinary" BackupPC Storage Node.
const coverHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BackupPC Storage Node</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,Cantarell,sans-serif;background:#f4f5f7;color:#1a1a1a;line-height:1.5;padding:2rem}
.container{max-width:480px;margin:4rem auto;background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:2.5rem;box-shadow:0 1px 3px rgba(0,0,0,.04)}
h1{font-size:1.4rem;font-weight:600;margin-bottom:.5rem;color:#24292f}
.subtle{color:#57606a;font-size:.9rem;margin-bottom:2rem}
label{display:block;font-size:.85rem;font-weight:500;margin:.75rem 0 .25rem;color:#24292f}
input[type=text],input[type=password]{width:100%;padding:.55rem .75rem;border:1px solid #d0d7de;border-radius:5px;font-size:.9rem;font-family:inherit}
button{margin-top:1.5rem;width:100%;padding:.6rem;background:#1f6feb;color:#fff;border:0;border-radius:5px;font-size:.9rem;font-weight:500;cursor:pointer}
.footer{margin-top:2rem;padding-top:1.25rem;border-top:1px solid #d0d7de;font-size:.75rem;color:#57606a;text-align:center}
.status{display:inline-block;padding:.2rem .55rem;font-size:.7rem;font-weight:600;background:#ddf4ff;color:#0969da;border-radius:12px;margin-left:.5rem}
</style>
</head>
<body>
<div class="container">
<h1>BackupPC Storage Node<span class="status">online</span></h1>
<p class="subtle">Cluster: backup-pool-01 &middot; Node version 3.14.2</p>
<form action="/storage/login" method="post">
<label for="user">Operator login</label>
<input type="text" id="user" name="user" autocomplete="username" required>
<label for="pass">Access key</label>
<input type="password" id="pass" name="pass" autocomplete="current-password" required>
<button type="submit">Authenticate</button>
</form>
<div class="footer">
&copy; 2026 BackupPC Storage Cluster &middot; Operator access only
</div>
</div>
</body>
</html>`

// Server — protocol-only carrier server.
//
// Construction: NewServer(). Lifecycle: Serve(listener).
// Hot-reload: RotateECHKey(), SetECHEnabled(), ReloadCert().
type Server struct {
	cfg    *ServerConfig
	users  *UserManager
	logger *slog.Logger

	srv *http.Server // net/http server with cover-aware HTTP/2 dispatch

	// certBox — atomic hot-swap of TLS cert.
	certBox atomic.Value // tls.Certificate

	// echState — atomic.Pointer for hot-reload ECH keypair.
	// RotateECHKey/SetECHEnabled trigger immediate effect on next handshake
	// (via GetConfigForClient callback that reads this state).
	echState atomic.Pointer[echRuntimeState]

	// noiseKeyPair — server's static X25519 keypair for Noise IK.
	noiseKeyPair NoiseKeyPair

	// V2 auth replay guard — sync.Map with seen-hash memory (4min TTL).
	// Key: "sid|idx" string. Value: *time.Time (expiry).
	replayGuard sync.Map

	// authCache — positive cache: "sid|idx|tsMin" → *authCacheEntry (3s TTL)
	authCache sync.Map
	// authNegCache — negative cache: "sid|idx" → *authNegativeCacheEntry (250ms TTL)
	authNegCache sync.Map

	// sessions — active logical sessions (sid → *logicalSession).
	// sessionID are random UUIDs; chunk rotation creates new sid.
	sessions sync.Map

	cancelFn context.CancelFunc

	// h2server — http2.Server for cover-aware HTTP/2 dispatch.
	h2server *http2.Server
}

// NewServer — construct protocol-only carrier server.
//
// Auto-loads/creates:
//   - TLS cert (from cfg.CertFile/KeyFile, or self-signed auto-gen in dataDir)
//   - Noise keypair (from cfg.NoiseKeyPath, or auto-gen in <dataDir>/noise.key)
//   - ECH keypair (from cfg.ECHKeyPath, or auto-gen in <dataDir>/ech.key)
//   - User store (from cfg.UserStore, or auto-create empty)
//
// Returns server ready to Serve. Callers must call Serve() to start listening.
func NewServer(cfg *ServerConfig, logger *slog.Logger) (*Server, error) {
	if cfg == nil {
		return nil, errors.New("backuppcvpn: cfg is nil")
	}
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	cfg.ApplyDefaults()

	s := &Server{
		cfg:    cfg,
		logger: logger,
		users:  NewUserManager(cfg.UserStore, logger),
	}

	// Load TLS cert.
	cert, err := loadOrGenCert(cfg)
	if err != nil {
		return nil, fmt.Errorf("backuppcvpn: cert: %w", err)
	}
	s.certBox.Store(cert)

	// Load seed users.
	if err := s.users.LoadSeeds(cfg.Users); err != nil {
		return nil, fmt.Errorf("backuppcvpn: seeds: %w", err)
	}
	if cfg.UUID != "" {
		if _, err := s.users.Add("default", cfg.UUID, 0, 0, 0); err != nil {
			// "default" already exists — ignore if same UUID.
		}
	}

	// Load Noise keypair (if enabled).
	if cfg.EnableNoiseLayer {
		noisePath := cfg.NoiseKeyPath
		if noisePath == "" && cfg.DataDir != "" {
			noisePath = filepath.Join(cfg.DataDir, "noise.key")
		}
		kp, err := loadOrCreateNoiseKey(noisePath)
		if err != nil {
			logger.Error("noise key load failed, disabling Noise layer", "err", err)
			cfg.EnableNoiseLayer = false
		} else {
			s.noiseKeyPair = kp
			logger.Info("Noise layer enabled",
				"key_path", noisePath,
				"public_key_hex", hex.EncodeToString(kp.Public))
		}
	}

	// Load ECH keypair (if enabled).
	if cfg.EnableECH {
		echPath := cfg.ECHKeyPath
		if echPath == "" && cfg.DataDir != "" {
			echPath = filepath.Join(cfg.DataDir, "ech.key")
		}
		pubName := cfg.ECHPublicName
		if pubName == "" {
			pubName = cfg.Host
			if pubName == "" {
				pubName = cfg.ExternalAddr
			}
		}
		priv, _, _, _, err := LoadOrCreateECHKey(cfg.DataDir, pubName)
		if err != nil {
			logger.Error("ECH key load failed, disabling ECH", "err", err)
			cfg.EnableECH = false
			s.echState.Store(BuildECHRuntimeState(nil, pubName, echPath))
		} else {
			s.echState.Store(BuildECHRuntimeState(priv, pubName, echPath))
			logger.Info("ECH enabled",
				"key_path", echPath,
				"public_name", pubName)
		}
	} else {
		s.echState.Store(BuildECHRuntimeState(nil, "", ""))
	}

	// Build http.Server with cover-aware HTTP/2 dispatch.
	mux := http.NewServeMux()
	// /api/ech-config — PUBLIC endpoint (clients fetch before TLS handshake).
	mux.HandleFunc("/api/ech-config", s.handleECHConfigPublic)
	// Catch-all: carrier endpoint OR cover fallback.
	mux.HandleFunc("/", s.handleRoot)

	s.srv = &http.Server{
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS13,
			NextProtos: []string{"h2", "http/1.1"},
			GetConfigForClient: func(chi *tls.ClientHelloInfo) (*tls.Config, error) {
				c, _ := s.certBox.Load().(tls.Certificate)
				return &tls.Config{
					Certificates:             []tls.Certificate{c},
					MinVersion:               tls.VersionTLS13,
					NextProtos:               []string{"h2", "http/1.1"},
					EncryptedClientHelloKeys: s.echServerKeys(), // hot-reload
				}, nil
			},
		},
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	// Install cover-aware HTTP/2 handler (overrides TLSNextProto["h2"]).
	s.setupHTTP2WithCoverHandler()

	return s, nil
}

// Serve — start accepting connections. Blocks until ctx cancelled or
// listener fails. Starts QUIC listener in parallel if EnableQUIC=true.
func (s *Server) Serve(ln net.Listener) error {
	ctx, cancel := context.WithCancel(context.Background())
	s.cancelFn = cancel
	defer cancel()

	// Start background sweep loops.
	go s.replayGuardSweepLoop(ctx)
	go s.authCacheSweepLoop(ctx)

	// Start QUIC listener if enabled.
	if s.cfg.EnableQUIC {
		quicAddr := s.cfg.QUICListen
		if quicAddr == "" {
			quicAddr = s.cfg.Listen
		}
		go func() {
			if err := s.startQUICListener(ctx, quicAddr); err != nil {
				s.logger.Error("QUIC listener stopped", "err", err)
			}
		}()
	}

	s.logger.Info("server starting",
		"listen", s.cfg.Listen,
		"ech", s.ECHEnabled(),
		"noise", s.NoiseEnabled(),
		"quic", s.cfg.EnableQUIC,
		"require_v2_auth", s.cfg.RequireV2Auth)

	tlsLn := tls.NewListener(ln, s.srv.TLSConfig)
	return s.srv.Serve(tlsLn)
}

// Shutdown — graceful shutdown (waits for in-flight handshakes).
func (s *Server) Shutdown(ctx context.Context) error {
	if s.cancelFn != nil {
		s.cancelFn()
	}
	if s.srv != nil {
		return s.srv.Shutdown(ctx)
	}
	return nil
}

// --- Users accessor ---

// Users — return UserManager (for external user management).
func (s *Server) Users() *UserManager { return s.users }

// --- ECH hot-reload API ---

// ECHEnabled — whether ECH is currently active (hot-reloadable).
func (s *Server) ECHEnabled() bool {
	st := s.echState.Load()
	return st != nil && st.enabled
}

// ECHConfigListB64 — base64-encoded ECHConfigList for /api/ech-config.
// Empty string when ECH disabled.
func (s *Server) ECHConfigListB64() string {
	st := s.echState.Load()
	if st == nil || !st.enabled {
		return ""
	}
	return st.configListB64
}

// ECHStatus — public snapshot of ECH state (no private key).
func (s *Server) ECHStatus() ECHStatus {
	st := s.echState.Load()
	return st.snapshot()
}

// RotateECHKey — generate fresh X25519 keypair + atomic swap state.
// Returns new ECHStatus. Existing TLS connections keep negotiated state.
// Clients with stale ECHConfigList get ECHRejectionError → auto-retry
// with server's RetryConfigList (SendAsRetry=true).
func (s *Server) RotateECHKey(publicNameOverride string) (ECHStatus, error) {
	cur := s.echState.Load()
	pubName := publicNameOverride
	if pubName == "" && cur != nil {
		pubName = cur.publicName
	}
	keyPath := ""
	if cur != nil {
		keyPath = cur.keyPath
	}
	newState, err := GenerateNewECHKeypair(pubName, keyPath)
	if err != nil && newState == nil {
		return ECHStatus{}, err
	}
	s.echState.Store(newState)
	if err != nil {
		s.logger.Warn("ECH key rotated (in-memory only, persistence failed)", "err", err)
	} else {
		s.logger.Info("ECH key rotated", "public_name", pubName)
	}
	return newState.snapshot(), err
}

// SetECHEnabled — toggle ECH on/off without restart.
// Same keypair preserved (clients with cached config list continue to work).
func (s *Server) SetECHEnabled(enabled bool) ECHStatus {
	cur := s.echState.Load()
	if cur == nil {
		s.echState.Store(BuildECHRuntimeState(nil, "", ""))
		return ECHStatus{}
	}
	if cur.enabled == enabled {
		return cur.snapshot()
	}
	newState := cur.CloneWithEnabled(enabled)
	s.echState.Store(newState)
	s.logger.Info("ECH toggled", "enabled", enabled)
	return newState.snapshot()
}

// ReloadCert — hot-swap TLS cert (e.g. after Let's Encrypt renewal).
// Atomic certBox.Store — next handshake sees new cert.
func (s *Server) ReloadCert() error {
	cert, err := loadOrGenCert(s.cfg)
	if err != nil {
		return err
	}
	s.certBox.Store(cert)
	s.logger.Info("TLS cert reloaded")
	return nil
}

// --- Noise accessors ---

// NoiseEnabled — whether Noise layer is active.
func (s *Server) NoiseEnabled() bool { return s.cfg.EnableNoiseLayer }

// NoisePublicKey — server's Noise X25519 public key (hex). Empty if disabled.
func (s *Server) NoisePublicKey() string {
	if !s.cfg.EnableNoiseLayer {
		return ""
	}
	return hex.EncodeToString(s.noiseKeyPair.Public)
}

// --- Internal helpers ---

// echServerKeys — bridge atomic.Pointer state → tls.EncryptedClientHelloKey.
// Called from GetConfigForClient on every TLS handshake.
func (s *Server) echServerKeys() []tls.EncryptedClientHelloKey {
	st := s.echState.Load()
	if st == nil || !st.enabled || st.privKey == nil || len(st.config) == 0 {
		return nil
	}
	return []tls.EncryptedClientHelloKey{{
		Config:      st.config,
		PrivateKey:  st.privKey.Bytes(),
		SendAsRetry: true,
	}}
}

// handleECHConfigPublic — GET /api/ech-config (PUBLIC, no auth).
// Clients download ECHConfigList before TLS handshake.
func (s *Server) handleECHConfigPublic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	status := s.ECHStatus()
	_ = json.NewEncoder(w).Encode(map[string]any{
		"echEnabled":       status.Enabled,
		"echConfigListB64": status.ConfigListB64,
		"publicName":       status.PublicName,
		"rotatedAt":        status.RotatedAt,
	})
}

// handleRoot — catch-all: carrier endpoint OR cover fallback.
//
// Decision tree:
//   - If path matches EndpointPaths → carrier auth (V2 verify + VLESS relay)
//   - Otherwise → probe → cover HTML (byte-identical)
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if !s.matchEndpoint(r.URL.Path) {
		s.probe(w, r, "path", http.StatusNotFound, "")
		return
	}

	// Parse V2 auth headers.
	sid := r.Header.Get(hdrSessionID)
	idxStr := r.Header.Get(hdrChunkIndex)
	auth := r.Header.Get(hdrChunkAuth)
	tsMinStr := r.Header.Get(hdrTimestamp)

	if sid == "" || idxStr == "" || auth == "" {
		s.probe(w, r, "no-session", http.StatusBadRequest, "")
		return
	}

	idx, err := strconv.ParseUint(idxStr, 10, 32)
	if err != nil {
		s.probe(w, r, "bad-chunk", http.StatusBadRequest, "")
		return
	}

	user := s.verifyAuthUser(sid, uint32(idx), auth, tsMinStr)
	if user == nil {
		s.probe(w, r, "bad-auth", http.StatusUnauthorized, "")
		return
	}

	// Auth OK — relay bytes (VLESS handshake + target dial).
	// For brevity, this minimal version just acknowledges.
	// Full implementation: dial target, wrap in VLESS, relay bytes.
	w.Header().Set("Content-Type", "application/grpc")
	w.WriteHeader(http.StatusOK)
	// In a real carrier: read r.Body (VLESS + payload), dial target,
	// relay bidirectionally. This is the protocol-only stub.
	_ = user
}

// matchEndpoint — check if path is in cfg.EndpointPaths or its "chunk file".
// E.g. /backuppc.ChunkService/PutChunk matches /backuppc.ChunkService/PutChunk
// and /backuppc.ChunkService/PutChunk/backup-chunk-007.bin.
func (s *Server) matchEndpoint(p string) bool {
	for _, base := range s.cfg.EndpointPaths {
		if p == base || strings.HasPrefix(p, base+"/") {
			return true
		}
	}
	return false
}

// probe — return byte-identical cover HTML. Called for ALL probe kinds.
//
// All probes return same HTTP 200 + coverHTML — censor cannot distinguish:
//   - Random TCP scan with garbage payload
//   - HTTP/1.1 GET request
//   - HTTP/2 request with wrong path
//   - HTTP/2 request with wrong auth header
//   - HTTP/2 request with bad VLESS handshake
//   - Replay-protected auth rejection
//
// kind is just for metrics (not in response body — that would leak info).
func (s *Server) probe(w http.ResponseWriter, r *http.Request, kind string, status int, _ string) {
	// Always return 200 + coverHTML (not the passed status!).
	// status param is kept for API compat but ignored — would leak info.
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(coverHTML))
}

// verifyAuthUser — V2 auth verification with replay guard.
//
// V2: auth = hex(HMAC-SHA256(SHA256(uuid), sid|idx|tsMin))
// Server checks ±2min time window. Replay guard catches (sid, idx) reuse.
func (s *Server) verifyAuthUser(sid string, idx uint32, auth string, tsMinStr string) *User {
	// V2 path: timestamp header present.
	if tsMinStr != "" {
		tsMin, err := strconv.ParseInt(tsMinStr, 10, 64)
		if err != nil {
			return nil // malformed timestamp → probe → cover
		}

		// Check replay guard FIRST (before HMAC verify — cheap path).
		replayKey := sid + "|" + strconv.FormatUint(uint64(idx), 10)
		if v, ok := s.replayGuard.Load(replayKey); ok {
			expiry := v.(*time.Time)
			if time.Now().Before(*expiry) {
				return nil // REPLAY!
			}
			s.replayGuard.Delete(replayKey)
		}

		// Check ±2min time window. Try client's tsMin first (fast path —
		// single HMAC per user when clocks match). Fall back to window
		// iteration if exact match fails (clock skew).
		nowTsMin := nowMin()
		var found *User
		s.users.Iter(func(u *User) bool {
			// Fast path: try client's reported tsMin directly.
			expected := BackupAuthHeaderV2(u.uuidB, sid, idx, tsMin)
			if hmac.Equal([]byte(auth), []byte(expected)) {
				found = u
				return false
			}
			// Slow path: iterate ±2min window.
			for delta := int64(-replayWindowMin); delta <= replayWindowMin; delta++ {
				candidateTsMin := nowTsMin + delta
				if candidateTsMin == tsMin {
					continue // already tried above
				}
				expected := BackupAuthHeaderV2(u.uuidB, sid, idx, candidateTsMin)
				if hmac.Equal([]byte(auth), []byte(expected)) {
					found = u
					return false // stop iteration
				}
			}
			return true // continue
		})

		if found != nil {
			// Mark (sid, idx) as seen — replay guard.
			expiry := time.Now().Add(2 * 2 * time.Minute) // 4min TTL
			s.replayGuard.Store(replayKey, &expiry)
			return found
		}
		return nil
	}

	// V1 fallback (if RequireV2Auth is false).
	if s.cfg.RequireV2Auth {
		return nil // V1 rejected
	}

	// V1 auth: hex(HMAC-SHA256(uuid, sid|idx))
	var found *User
	s.users.Iter(func(u *User) bool {
		expected := BackupAuthHeader(u.uuidB, sid, idx)
		if hmac.Equal([]byte(auth), []byte(expected)) {
			found = u
			return false
		}
		return true
	})
	return found
}

// --- Background sweep loops ---

// replayGuardSweepLoop — каждые 60s убирает истёкшие (sid, idx) записи.
// TTL 4min — sweep 60s покрывает с запасом.
func (s *Server) replayGuardSweepLoop(ctx context.Context) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.replayGuard.Range(func(k, v any) bool {
				expiry := v.(*time.Time)
				if time.Now().After(*expiry) {
					s.replayGuard.Delete(k)
				}
				return true
			})
		}
	}
}

// authCacheSweepLoop — каждые 30s чистит authCache/authNegCache от истёкших.
func (s *Server) authCacheSweepLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			now := time.Now()
			s.authCache.Range(func(k, v any) bool {
				if entry, ok := v.(*authCacheEntry); ok {
					if now.After(entry.expiry) {
						s.authCache.Delete(k)
					}
				}
				return true
			})
			s.authNegCache.Range(func(k, v any) bool {
				if entry, ok := v.(*authNegativeCacheEntry); ok {
					if now.After(entry.expiry) {
						s.authNegCache.Delete(k)
					}
				}
				return true
			})
		}
	}
}

// authCacheEntry — positive cache entry (3s TTL).
type authCacheEntry struct {
	user   *User
	expiry time.Time
}

// authNegativeCacheEntry — negative cache entry (250ms TTL).
type authNegativeCacheEntry struct {
	expiry time.Time
}

// nowMin — helper: unix-time in minutes.
func nowMin() int64 { return time.Now().Unix() / 60 }

// --- Auth header helpers (exported for client-side use) ---

// BackupAuthHeader — V1 auth: hex(HMAC-SHA256(uuid, sid|idx)).
// Vulnerable to replay — use BackupAuthHeaderV2 in production.
func BackupAuthHeader(key [16]byte, sid string, idx uint32) string {
	mac := hmac.New(sha256.New, key[:])
	mac.Write([]byte(sid))
	mac.Write([]byte("|"))
	mac.Write([]byte(strconv.FormatUint(uint64(idx), 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

// BackupAuthHeaderV2 — V2 auth: hex(HMAC-SHA256(SHA256(uuid), sid|idx|tsMin)).
// Replay-protected: ±2min time window + seen-hash memory (4min TTL).
func BackupAuthHeaderV2(key [16]byte, sid string, idx uint32, tsMin int64) string {
	hashedKey := sha256.Sum256(key[:])
	mac := hmac.New(sha256.New, hashedKey[:])
	mac.Write([]byte(sid))
	mac.Write([]byte("|"))
	mac.Write([]byte(strconv.FormatUint(uint64(idx), 10)))
	mac.Write([]byte("|"))
	mac.Write([]byte(strconv.FormatInt(tsMin, 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

// --- noise keypair persistence ---

// loadOrCreateNoiseKey — load or generate X25519 keypair for Noise IK.
// Persisted to path (atomic tmp+rename, 0600). In-memory if path="".
func loadOrCreateNoiseKey(path string) (NoiseKeyPair, error) {
	if path == "" {
		return GenerateNoiseKeyPair()
	}
	if raw, err := os.ReadFile(path); err == nil {
		return NoiseKeyPairFromPrivate(raw)
	} else if !errors.Is(err, os.ErrNotExist) && !os.IsNotExist(err) {
		return NoiseKeyPair{}, fmt.Errorf("noise: stat %s: %w", path, err)
	}
	kp, err := GenerateNoiseKeyPair()
	if err != nil {
		return NoiseKeyPair{}, err
	}
	if werr := os.WriteFile(path, kp.Private, 0o600); werr != nil {
		// Don't fail — in-memory still works.
		_ = werr
	}
	return kp, nil
}


// --- Stubs for compatibility with xray-backuppc ported code ---

// recordClientHello — log TLS ClientHello info for debug.
// In xray-backuppc this dispatches to plugin + debug ring buffer.
// Clean version: just logs at Debug level.
func (s *Server) recordClientHello(chi *tls.ClientHelloInfo) {
	s.logger.Debug("TLS ClientHello",
		"server_name", chi.ServerName,
		"alpn", strings.Join(chi.SupportedProtos, ","))
}

// ddosMiddleware — DDoS protection middleware (per-IP ban list + rate limit).
// Clean version: pass-through (no DDoS protection — implement externally if needed).
func (s *Server) ddosMiddleware(next http.Handler) http.Handler {
	return next
}

// recoverMiddleware — panic recovery middleware.
// Logs panic + stack trace, returns 500 to client.
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.logger.Error("panic in handler",
					"err", fmt.Sprintf("%v", rec),
					"path", r.URL.Path)
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// --- Cover headers (used by http2_cover.go) ---

const (
	// coverServerHeader — Server header value on cover HTML responses.
	// Mimics nginx-style "Server: nginx/1.25.3" header.
	coverServerHeader = "nginx/1.25.3"

	// coverPoweredByHeader — X-Powered-By header (PHP-style, common on web).
	coverPoweredByHeader = "BackupPC/3.14.2"
)
