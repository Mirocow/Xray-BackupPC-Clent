// Package backupemulator — V2 auth header generation (client-side).
//
// V2 = replay-protected authentication (audit 2026-10-13, updated 2026-10-14).
//
//      Carrier HTTP/2 request gets THREE auth headers:
//        X-Backup-Session-ID:  <uuid v4>           (V1, same as before)
//        X-Backup-Chunk-Index: <sequential int>    (V1, same as before)
//        X-Backup-Timestamp:   <unix-minute>       (V2 NEW)
//        X-Backup-Auth:        <hex HMAC-SHA256>   (V2 modified — includes tsMin)
//
// Where (V2 token-based path, audit 2026-10-14):
//        tsMin = unix time / 60 (current minute, integer)
//        key   = user_token bytes (32 bytes, server-issued random — NO SHA256)
//        msg   = "<sid>|<idx>|<tsMin>"
//        auth  = hex(HMAC-SHA256(key, msg))
//
// The V2 user token is a 32-byte random secret issued by the server per user.
// It is NOT the VLESS UUID — V2 protocol eliminates UUID from the client
// config entirely. VLESS UUID is derived deterministically = token[:16]
// (server-side lookup).
//
// Legacy V2 path (pre-2026-10-14, kept for back-compat):
//        key   = SHA256(uuid string) — 32-byte precomputed
//        msg   = "<sid>|<idx>|<tsMin>"
//        auth  = hex(HMAC-SHA256(key, msg))
// Used only when UseV2Auth=true AND UserToken=="" (old clients that still
// store UUID). New V2 clients should set UserToken and not store UUID.
//
// Server side (xray-backuppc/internal/backupemulator/server.go):
//        1. Look up user by token (preferred) OR by UUID (legacy).
//        2. Verify HMAC matches one of ±2-min windows.
//        3. Check (sid, idx, tsMin) NOT in replay guard sync.Map (4-min TTL).
//        3. If RequireV2Auth is true → reject requests without X-Backup-Timestamp.
//
// Replay attack window: captured auth header can be replayed within ±2 min.
// After that, tsMin becomes stale → server rejects. Replay guard further
// deduplicates within the same window (captured auth can be used ONCE).
package backupemulator

import (
        "crypto/hmac"
        "crypto/sha256"
        "encoding/hex"
        "errors"
        "fmt"
        "strconv"
        "time"
)

// V2 auth header constants — must match server side (xray-backuppc
// internal/backupemulator/server.go).
const (
        HdrTimestamp = "X-Backup-Timestamp"

        // v2TimeWindow — ±2 минуты от текущей минуты. Сервер принимает auth,
        // сгенерированный для tsMin в диапазоне [now-2, now+2] минут.
        // Совпадает с серверной константой replayWindow.
        v2TimeWindow = 2 * time.Minute

        // v2ReplayTTL — TTL для replay guard sync.Map. Сервер хранит
        // (sid, idx, tsMin) → expiry в течение 4 минут, потом выкидывает.
        v2ReplayTTL = 4 * time.Minute
)

// v2KeyCache — precomputed HMAC key.
// Computed once per Client.NewClient() and stored on the Client struct.
// Avoids re-decoding the token on every chunk request.
//
// Two modes:
//   - Token-based (V2 preferred, audit 2026-10-14): 32 raw bytes from hex-decoded UserToken.
//   - Legacy UUID-based (V2 deprecated): SHA256(canonical UUID string).
type v2KeyCache [32]byte

// computeV2KeyFromToken — hex-decode the V2 user token (64 chars → 32 bytes).
// Used when UserToken is set (preferred V2 path, audit 2026-10-14).
// The token IS the HMAC key directly — no SHA256 derivation.
//
// Server stores the same 32 bytes and uses them as HMAC key.
// Returns an error if the token is not 64 hex chars (32 bytes).
func computeV2KeyFromToken(tokenHex string) (v2KeyCache, error) {
        var key v2KeyCache
        tokenHex = canonicalUUID(tokenHex) // lowercase, strip whitespace
        if len(tokenHex) != 64 {
                return key, fmt.Errorf("v2 token: expected 64 hex chars (32 bytes), got %d", len(tokenHex))
        }
        n, err := hex.Decode(key[:], []byte(tokenHex))
        if err != nil || n != 32 {
                return key, fmt.Errorf("v2 token: hex decode: %w", err)
        }
        return key, nil
}

// computeV2KeyFromUUID — SHA256 of the canonical UUID string (lowercase, dashed).
// Legacy V2 path (pre-2026-10-14, kept for back-compat with already-deployed
// V2 clients that still store UUID).
//
// Server uses the same canonicalization: uuid.DefaultString().
func computeV2KeyFromUUID(uuidStr string) v2KeyCache {
        return sha256.Sum256([]byte(canonicalUUID(uuidStr)))
}

// canonicalUUID — strip whitespace, lowercase. UUID string from config
// may have uppercase letters or surrounding spaces — normalize.
// Also works for hex tokens (no dashes, just lowercase).
func canonicalUUID(s string) string {
        out := make([]byte, 0, len(s))
        for i := 0; i < len(s); i++ {
                c := s[i]
                if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
                        continue
                }
                if c >= 'A' && c <= 'Z' {
                        c = c + 'a' - 'A'
                }
                out = append(out, c)
        }
        return string(out)
}

// BackupAuthHeaderV2FromToken — generates V2 auth header value using the
// V2 user token (preferred path, audit 2026-10-14):
// hex(HMAC-SHA256(token, sid|idx|tsMin))
//
// Parameters:
//   - tokenHex: 64-char hex string (32 bytes), server-issued V2 user token
//   - sid:      X-Backup-Session-ID (UUID v4 generated per logical session)
//   - idx:      X-Backup-Chunk-Index (sequential within session)
//   - tsMin:    Unix minute (time.Now().Unix() / 60)
//
// The returned string is hex-encoded (lowercase, 64 chars).
// Returns error if token is invalid (not 64 hex chars).
//
// Server side: looks up user by token bytes, uses same bytes as HMAC key.
func BackupAuthHeaderV2FromToken(tokenHex, sid string, idx uint32, tsMin int64) (string, error) {
        key, err := computeV2KeyFromToken(tokenHex)
        if err != nil {
                return "", err
        }
        mac := hmac.New(sha256.New, key[:])
        fmt.Fprintf(mac, "%s|%d|%d", sid, idx, tsMin)
        return hex.EncodeToString(mac.Sum(nil)), nil
}

// BackupAuthHeaderV2 — generates V2 auth header value (legacy path):
// hex(HMAC-SHA256(SHA256(uuid), sid|idx|tsMin))
//
// DEPRECATED: use BackupAuthHeaderV2FromToken (token-based) for new V2
// clients. This function is kept for back-compat with clients that still
// store UUID instead of token.
//
// Parameters:
//   - uuidStr: VLESS UUID string (canonical form will be derived)
//   - sid:     X-Backup-Session-ID (UUID v4 generated per logical session)
//   - idx:     X-Backup-Chunk-Index (sequential within session)
//   - tsMin:   Unix minute (time.Now().Unix() / 60)
func BackupAuthHeaderV2(uuidStr, sid string, idx uint32, tsMin int64) string {
        key := computeV2KeyFromUUID(uuidStr)
        mac := hmac.New(sha256.New, key[:])
        fmt.Fprintf(mac, "%s|%d|%d", sid, idx, tsMin)
        return hex.EncodeToString(mac.Sum(nil))
}

// DeriveVLESSUUIDFromToken — derive a 16-byte VLESS UUID from a 32-byte V2 token.
// Algorithm: uuid = token[:16] (first half of the 32-byte token).
//
// Both client and server use this same derivation — VLESS UUID is deterministic
// from the token. The client doesn't store UUID separately, only the token.
// Server stores token → user mapping; on VLESS handshake, derives expected
// UUID = user.Token[:16] and compares to received UUID.
//
// Parameters:
//   - tokenHex: 64-char hex string (32 bytes), V2 user token
//
// Returns:
//   - 16-byte VLESS UUID (raw bytes, not formatted as xxxxxxxx-xxxx-...)
//   - error if token is invalid
func DeriveVLESSUUIDFromToken(tokenHex string) ([16]byte, error) {
        var uuid [16]byte
        tokenHex = canonicalUUID(tokenHex)
        if len(tokenHex) != 64 {
                return uuid, errors.New("v2: token must be 64 hex chars (32 bytes)")
        }
        // Decode first 32 hex chars (= 16 bytes) into uuid[:].
        _, err := hex.Decode(uuid[:], []byte(tokenHex[:32]))
        if err != nil {
                return uuid, fmt.Errorf("v2: token hex decode: %w", err)
        }
        // RFC 4122 variant bits (for VLESS compatibility — some VLESS impls check).
        uuid[6] = (uuid[6] & 0x0f) | 0x40 // version 4
        uuid[8] = (uuid[8] & 0x3f) | 0x80 // variant RFC 4122
        return uuid, nil
}

// currentTsMin — current Unix minute (epoch seconds / 60, integer).
// Used as X-Backup-Timestamp value and in HMAC message.
func currentTsMin() int64 {
        return time.Now().Unix() / 60
}

// formatTsMinHeader — string representation of tsMin for HTTP header.
// Server does strconv.ParseInt(_, 10, 64) — must be decimal.
func formatTsMinHeader(tsMin int64) string {
        return strconv.FormatInt(tsMin, 10)
}
