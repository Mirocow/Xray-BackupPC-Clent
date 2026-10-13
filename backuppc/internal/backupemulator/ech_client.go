// Package backupemulator — ech_client.go: ECH helper for client-side (router).
//
// Subset of server-side ech.go — only what's needed by utls-tunnel sidecar
// + the router's xray binary. Server-side functions (LoadOrCreateECHKey,
// BuildECHRuntimeState, RotateECHKey) are NOT here — those manage persisted
// server keypairs and belong in xray-backuppc/internal/backupemulator/ech.go.
//
// What's here:
//   - ParseECHConfigListB64(): base64-decode ECHConfigList from URL/API.
//     Used by utls-tunnel --ech-config-list flag.
//
// On the client, ECH is a CONSUMER feature: server publishes ECHConfigList
// via /api/ech-config, client fetches it (or user pastes manually in
// router UI), then sets tls.Config.EncryptedClientHelloConfigList. The
// actual HPKE encryption happens inside Go's crypto/tls at TLS handshake.
package backupemulator

import (
	"encoding/base64"
	"errors"
	"strings"
)

// ParseECHConfigListB64 — base64-decode ECHConfigList from URL or API.
// Returns raw bytes (ready for tls.Config.EncryptedClientHelloConfigList).
//
// Used by utls-tunnel sidecar: accepts --ech-config-list <base64> flag.
// Same function exists in xray-backuppc/internal/backupemulator/ech.go
// (server-side) — kept in sync.
//
// Empty/whitespace input → error (caller should treat empty as "ECH off").
func ParseECHConfigListB64(b64 string) ([]byte, error) {
	b64 = strings.TrimSpace(b64)
	if b64 == "" {
		return nil, errors.New("ech: empty config list")
	}
	return base64.StdEncoding.DecodeString(b64)
}
