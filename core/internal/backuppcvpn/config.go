// Package backuppcvpn: config.go — server + client configuration.
//
// Clean, protocol-only config — без зависимостей от mesh/plugins/admin.
// Это упрощённая версия ServerConfig из xray-backuppc (только V2 фичи).

package backuppcvpn

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"strings"
	"time"
)

// ServerConfig — конфигурация backuppcvpn-сервера (protocol-only).
//
// Чистая версия без mesh/plugins/admin — только то что нужно для
// carrier TLS + V2 auth + ECH + Noise + QUIC fallback.
type ServerConfig struct {
	TransportConfig
	// Listen — TCP-адрес для HTTP/2 carrier (e.g. "[::]:8443").
	Listen string `json:"listen"`

	// Host — домен-донор для SNI/Host header (BackupPC masquerade).
	Host string `json:"host"`

	// ExternalAddr — публичный адрес для генерации клиентских конфигов.
	ExternalAddr string `json:"externalAddr,omitempty"`

	// DataDir — каталог данных: сюда персистятся self-signed cert,
	// noise.key, ech.key, users.json, users.key.
	DataDir string `json:"-"`

	// CertFile/KeyFile — пути к PEM cert/key (пусто → self-signed auto-gen).
	CertFile string `json:"certFile,omitempty"`
	KeyFile  string `json:"keyFile,omitempty"`

	// UserStore — путь к users.json; пусто → <dataDir>/users.json.
	UserStore string `json:"userStore,omitempty"`

	// UUID — legacy single-user (seed "default").
	UUID string `json:"uuid,omitempty"`

	// Users — стартовые клиенты (если users.json не существует).
	Users []UserSeed `json:"users,omitempty"`

	// --- V2 Security Hardening (audit 2026-10-12, Marvia-inspired) ---

	// RequireV2Auth — серверный флаг «только V2 auth».
	// Когда true: сервер REJECT'ит запросы без X-Backup-Timestamp.
	// Включайте ПОСЛЕ полной миграции всех клиентов на V2.
	RequireV2Auth bool `json:"requireV2Auth,omitempty"`

	// EnableNoiseLayer — inner Noise IK crypto layer (MITM defense).
	// Noise keypair хранится в <dataDir>/noise.key (32 bytes, 0600).
	EnableNoiseLayer bool `json:"enableNoiseLayer,omitempty"`
	NoiseKeyPath     string `json:"noiseKeyPath,omitempty"`

	// EnableQUIC — UDP-based QUIC (HTTP/3) transport fallback.
	// Клиенты подключаются через HTTP/3 когда TCP HTTP/2 заблокирован.
	EnableQUIC bool `json:"enableQUIC,omitempty"`
	QUICListen string `json:"quicListen,omitempty"`

	// EnableECH — Encrypted Client Hello (RFC 9460).
	// Шифрует SNI через HPKE (X25519+HKDF-SHA256+AES-128-GCM).
	// ECH keypair хранится в <dataDir>/ech.key (32 bytes, 0600).
	// Hot-reloadable: RotateECHKey() + SetECHEnabled() без рестарта.
	EnableECH    bool   `json:"enableECH,omitempty"`
	ECHPublicName string `json:"echPublicName,omitempty"`
	ECHKeyPath   string `json:"echKeyPath,omitempty"`

	// --- Padding (anti TLS-in-TLS) ---

	MinPaddingSize int `json:"minPaddingSize,omitempty"` // default 32
	MaxPaddingSize int `json:"maxPaddingSize,omitempty"` // default 1400
	MaxWriteChunk  int `json:"maxWriteChunk,omitempty"`  // default 65535

	// --- Session rotation ---

	MaxSessionDuration time.Duration `json:"maxSessionDuration,omitempty"` // default 30m
	MaxSessionBytes    int64         `json:"maxSessionBytes,omitempty"`     // default 2GB
	IdleTimeout        time.Duration `json:"idleTimeout,omitempty"`        // default 90s

	// --- Endpoint paths (carrier gRPC methods under backuppc.* namespace) ---

	EndpointPaths []string `json:"endpointPaths,omitempty"`

	// --- Rate limits ---

	ProbeRatePerMin int `json:"probeRatePerMin,omitempty"` // 0=no limit, default 30
	ProbeBurst      int `json:"probeBurst,omitempty"`      // default 5

	// --- DialContext (runtime-only, не сериализуется) ---

	DialContext func(ctx context.Context, network, addr string) (net.Conn, error) `json:"-"`
}

// ApplyDefaults — применяет дефолтные значения для пустых полей.
func (c *ServerConfig) ApplyDefaults() {
	if c.Listen == "" {
		c.Listen = "[::]:8443"
	}
	if c.Host == "" {
		c.Host = "backuppc.local"
	}
	if c.MinPaddingSize == 0 {
		c.MinPaddingSize = 32
	}
	if c.MaxPaddingSize == 0 {
		c.MaxPaddingSize = 1400
	}
	if c.MaxWriteChunk == 0 {
		c.MaxWriteChunk = 65535
	}
	if c.MaxSessionDuration == 0 {
		c.MaxSessionDuration = 30 * time.Minute
	}
	if c.MaxSessionBytes == 0 {
		c.MaxSessionBytes = 2 * 1024 * 1024 * 1024 // 2 GB
	}
	if c.IdleTimeout == 0 {
		c.IdleTimeout = 90 * time.Second
	}
	if c.ProbeRatePerMin == 0 {
		c.ProbeRatePerMin = 30
	}
	if c.ProbeBurst == 0 {
		c.ProbeBurst = 5
	}
	if len(c.EndpointPaths) == 0 {
		c.EndpointPaths = DefaultEndpointPaths()
	}
}

// DefaultEndpointPaths — стандартный пул несущих gRPC-методов
// BackupPC Storage Node (18 методов).
func DefaultEndpointPaths() []string {
	return []string{
		"/backuppc.BackupService/BackupStream",
		"/backuppc.ChunkService/PutChunk",
		"/backuppc.StorageService/UploadStream",
		"/backuppc.ChunkService/StreamChunks",
		"/backuppc.StorageService/WriteStream",
		"/backuppc.StorageService/PutBlocks",
		"/backuppc.SnapshotService/SendSnapshot",
		"/backuppc.SnapshotService/SnapshotStream",
		"/backuppc.RsyncService/DeltaStream",
		"/backuppc.RsyncService/RsyncTransfer",
		"/backuppc.ArchiveService/PutArchive",
		"/backuppc.ArchiveService/ArchiveStream",
		"/backuppc.DedupService/DedupStream",
		"/backuppc.ReplicationService/ReplicateStream",
		"/backuppc.CatalogService/IndexStream",
		"/backuppc.CatalogService/PutIndex",
		"/backuppc.TransferService/UploadBackup",
		"/backuppc.TransferService/RestoreStream",
	}
}

// LoadServerConfig — прочитать JSON-конфиг из path. Применяет ApplyDefaults.
func LoadServerConfig(path string) (*ServerConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("backuppcvpn: read config %s: %w", path, err)
	}
	var cfg ServerConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("backuppcvpn: parse config %s: %w", path, err)
	}
	cfg.ApplyDefaults()
	return &cfg, nil
}

// --- Client-side config (используется desktop + utls-tunnel) ---

// ClientConfig — конфигурация outbound-транспорта (dialer).
type ClientConfig struct {
	TransportConfig
	ServerAddr  string `json:"serverAddr"`  // host:port
	UUID        string `json:"uuid"`        // VLESS UUID
	Host        string `json:"host"`        // SNI/Host header (donor domain)
	SocksListen string `json:"socksListen"` // local SOCKS5 inbound, default 127.0.0.1:1080
	Insecure    bool   `json:"insecure"`    // skip cert verification (dev only)
	CertFingerprint string `json:"certFingerprint,omitempty"` // SHA-256 hex (pinning)

	// V2 auth
	UseV2Auth bool `json:"useV2Auth,omitempty"`

	// uTLS (Chrome JA3 mimicry)
	UseUTLS       bool   `json:"useUTLS,omitempty"`
	UTFingerprint string `json:"utFingerprint,omitempty"`

	// Inner Noise IK layer
	ServerNoisePubKey string `json:"serverNoisePubKey,omitempty"`

	// QUIC fallback
	QUICFallback bool `json:"quicFallback,omitempty"`

	// ECH (RFC 9460)
	ECHConfigList string `json:"echConfigList,omitempty"` // base64
	ECHAutoFetch  bool   `json:"echAutoFetch,omitempty"`

	// utls-tunnel sidecar path (Dart client)
	UtlsTunnelPath string `json:"utlsTunnelPath,omitempty"`

	// Padding
	MinPaddingSize int `json:"minPaddingSize,omitempty"`
	MaxPaddingSize int `json:"maxPaddingSize,omitempty"`
	MaxWriteChunk  int `json:"maxWriteChunk,omitempty"`

	// Endpoint paths
	EndpointPaths []string `json:"endpointPaths,omitempty"`

	// DialContext (runtime-only)
	DialContext func(ctx context.Context, network, addr string) (net.Conn, error) `json:"-"`
}

// ApplyDefaults — defaults для client config.
func (c *ClientConfig) ApplyDefaults() {
	if c.SocksListen == "" {
		c.SocksListen = "127.0.0.1:1080"
	}
	if c.MinPaddingSize == 0 {
		c.MinPaddingSize = 32
	}
	if c.MaxPaddingSize == 0 {
		c.MaxPaddingSize = 1400
	}
	if c.MaxWriteChunk == 0 {
		c.MaxWriteChunk = 65535
	}
	if c.UTFingerprint == "" {
		c.UTFingerprint = "chrome"
	}
	if len(c.EndpointPaths) == 0 {
		c.EndpointPaths = DefaultEndpointPaths()
	}
}

// Validate — basic config validation. Возвращает nil если OK.
func (c *ClientConfig) Validate() error {
	if c.ServerAddr == "" {
		return fmt.Errorf("backuppcvpn: serverAddr обязателен")
	}
	if c.UUID == "" {
		return fmt.Errorf("backuppcvpn: uuid обязателен")
	}
	if c.CertFingerprint != "" && c.Insecure {
		return fmt.Errorf("backuppcvpn: указан и insecure, и certFingerprint — выберите одно")
	}
	return nil
}

// SplitServerAddr — split "host:port" → (host, port). Default port 443.
func (c *ClientConfig) SplitServerAddr() (string, int) {
	host, port, err := net.SplitHostPort(c.ServerAddr)
	if err != nil {
		return c.ServerAddr, 443
	}
	p := 443
	if _, err := fmt.Sscanf(port, "%d", &p); err != nil || p <= 0 || p >= 65536 {
		p = 443
	}
	return strings.TrimSpace(host), p
}

// TransportConfig — общая конфигурация транспорта (server + client).
// Embedded в ServerConfig и ClientConfig.
type TransportConfig struct {
	// EndpointPaths — gRPC carrier paths (BackupPC namespace).
	EndpointPaths []string `json:"endpointPaths,omitempty"`

	// Padding — anti TLS-in-TLS detection.
	MinPaddingSize int `json:"minPaddingSize,omitempty"` // default 32
	MaxPaddingSize int `json:"maxPaddingSize,omitempty"` // default 1400
	MaxWriteChunk  int `json:"maxWriteChunk,omitempty"`  // default 65535

	// AdaptivePadding — random frame size + size-based padding buckets.
	AdaptivePadding bool `json:"adaptivePadding,omitempty"`

	// BackupPC masquerade (background fake-backup traffic).
	BackupPC BackupPCConfig `json:"backuppc,omitempty"`

	// UserAgent — custom User-Agent header (random from pool if empty).
	UserAgent string `json:"userAgent,omitempty"`
}

// BackupPCConfig — BackupPC masquerade config (background fake-backup traffic).
type BackupPCConfig struct {
	Enabled bool `json:"enabled"`

	// Incremental backups: 2-8 MB every 25 min
	IncrementalEvery    time.Duration `json:"incrementalEvery,omitempty"`
	IncrementalMinBytes int           `json:"incrementalMinBytes,omitempty"`
	IncrementalMaxBytes int          `json:"incrementalMaxBytes,omitempty"`

	// Full backups: 32-128 MB every 8 hours
	FullEvery     time.Duration `json:"fullEvery,omitempty"`
	FullMinBytes  int           `json:"fullMinBytes,omitempty"`
	FullMaxBytes  int           `json:"fullMaxBytes,omitempty"`

	// Night mode (more backups during 22-06h)
	NightStartHour int `json:"nightStartHour,omitempty"`
	NightEndHour   int `json:"nightEndHour,omitempty"`
}

// BoolPtr — helper for *bool fields in config (default true semantics).
func BoolPtr(b bool) *bool { return &b }

// randAdaptivePadding — size-based padding buckets:
//   - Small chunks (< 1KB): pad to 1-2KB
//   - Medium chunks (1-16KB): pad to 256-1024 bytes
//   - Large chunks (> 16KB): minimal padding (32-256 bytes)
//
// Rationale: large chunks already mask inner TLS record structure.
// Small chunks need more padding to break inner TLS record boundary detection.
func (tc *TransportConfig) randAdaptivePadding(seg int) (int, error) {
	if !tc.AdaptivePadding {
		// Legacy: fixed range [MinPaddingSize, MaxPaddingSize].
		return tc.MinPaddingSize, nil
	}
	switch {
	case seg < 1024:
		return 1024 + mathRandIntn(1024), nil // → 1-2KB
	case seg < 16*1024:
		return 256 + mathRandIntn(768), nil // → 256-1024 bytes
	default:
		return 32 + mathRandIntn(224), nil // → 32-256 bytes
	}
}

// randPadding — legacy V1 padding (fixed range).
func (tc *TransportConfig) randPadding() (int, error) {
	if tc.MaxPaddingSize <= tc.MinPaddingSize {
		return tc.MinPaddingSize, nil
	}
	return tc.MinPaddingSize + mathRandIntn(tc.MaxPaddingSize-tc.MinPaddingSize), nil
}

// mathRandIntn — wrapper around math/rand/v2 Intn (avoids direct import in this file).
// Implemented in conn.go (which already imports math/rand/v2).

// mathRandIntn — wrapper around math/rand/v2 Intn (used by padding helpers).
func mathRandIntn(n int) int {
	if n <= 0 {
		return 0
	}
	return rand.IntN(n)
}

// ParseUUID — parse RFC 4122 UUID string to 16 raw bytes.
// Accepts both "550e8400-e29b-41d4-a716-446655440000" (with hyphens)
// and "550e8400e29b41d4a716446655440000" (without). Returns error on
// invalid format/length.
func ParseUUID(s string) ([16]byte, error) {
	var id [16]byte
	clean := strings.ReplaceAll(strings.TrimSpace(s), "-", "")
	if len(clean) != 32 {
		return id, fmt.Errorf("uuid: invalid length %d (expected 32 hex chars)", len(clean))
	}
	raw, err := hex.DecodeString(clean)
	if err != nil {
		return id, fmt.Errorf("uuid: %w", err)
	}
	copy(id[:], raw)
	return id, nil
}
