// Package backupemulator — V2 auth header generation (client-side).
//
// V2 = replay-protected authentication (audit 2026-10-13).
//
//	Carrier HTTP/2 request gets THREE auth headers:
//	  X-Backup-Session-ID:  <uuid v4>           (V1, same as before)
//	  X-Backup-Chunk-Index: <sequential int>    (V1, same as before)
//	  X-Backup-Timestamp:   <unix-minute>       (V2 NEW)
//	  X-Backup-Auth:        <hex HMAC-SHA256>   (V2 modified — includes tsMin)
//
// Where:
//	  tsMin = unix time / 60 (current minute, integer)
//	  key   = SHA256(uuid) — 32-byte precomputed
//	  msg   = "<sid>|<idx>|<tsMin>"
//	  auth  = hex(HMAC-SHA256(key, msg))
//
// Server side (xray-backuppc/internal/backupemulator/server.go):
//	  1. Verify HMAC matches one of ±2-min windows (current, prev, next minute).
//	  2. Check (sid, idx, tsMin) NOT seen recently (replay guard sync.Map, 4-min TTL).
//	  3. If RequireV2Auth is true → reject requests without X-Backup-Timestamp.
//
// Replay attack window: captured auth header can be replayed within ±2 min.
// After that, tsMin becomes stale → server rejects. Replay guard further
// deduplicates within the same window (captured auth can be used ONCE).
package backupemulator

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
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

// v2KeyCache — precomputed HMAC key: SHA256(uuid string).
// Computed once per Client.NewClient() and stored on the Client struct.
// Avoids re-SHA256 on every chunk request (3 SHA256/sec at 20 chunks/sec).
type v2KeyCache [32]byte

// computeV2Key — SHA256 of the canonical UUID string (lowercase, dashed).
// Server uses the same canonicalization: uuid.DefaultString().
//
// Why SHA256(uuid) as the key (instead of raw uuid bytes): the server
// stores users as uuid string, not raw bytes. SHA256(string) gives
// 32-byte key matching what server expects. Cross-vendor compatibility:
// Go's uuid.ParseString produces canonical form, matching server side.
func computeV2Key(uuidStr string) v2KeyCache {
	// Canonical form: lowercase, dashed (e.g. "52724a0e-...-...-...").
	// Server uses uuid.ParseString().String() which is canonical too.
	return sha256.Sum256([]byte(canonicalUUID(uuidStr)))
}

// canonicalUUID — strip whitespace, lowercase. UUID string from config
// may have uppercase letters or surrounding spaces — normalize.
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

// BackupAuthHeaderV2 — generates V2 auth header value:
// hex(HMAC-SHA256(SHA256(uuid), sid|idx|tsMin)).
//
// Parameters:
//   - uuidStr: VLESS UUID string (canonical form will be derived)
//   - sid:     X-Backup-Session-ID (UUID v4 generated per logical session)
//   - idx:     X-Backup-Chunk-Index (sequential within session)
//   - tsMin:   Unix minute (time.Now().Unix() / 60)
//
// The returned string is hex-encoded (lowercase, 64 chars).
//
// Server side verification (server.go verifyAuthUser):
//   - Recomputes HMAC for tsMin in {now-2, now-1, now, now+1, now+2}.
//   - If match found AND (sid, idx, tsMin) NOT in replay guard sync.Map →
//     accept, store in guard with 4-min TTL.
//   - If match found but already in replay guard → reject (replayed).
//   - If no match in ±2 min window → reject (out of window).
func BackupAuthHeaderV2(uuidStr, sid string, idx uint32, tsMin int64) string {
	key := computeV2Key(uuidStr)
	mac := hmac.New(sha256.New, key[:])
	fmt.Fprintf(mac, "%s|%d|%d", sid, idx, tsMin)
	return hex.EncodeToString(mac.Sum(nil))
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
