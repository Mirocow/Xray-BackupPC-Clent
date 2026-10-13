// Package v2 provides client-side V2 security helpers (ECH + Noise).
//
// This is a public re-export shim for backuppc/internal/backupemulator —
// that package is internal (cannot be imported from outside the backuppc
// module). The xray outbound (backuppc-core module) and the utls-tunnel
// sidecar (also backuppc-core module) need these helpers, so we expose
// them here.
//
// All functions are aliases for the internal equivalents — same semantics,
// same wire-format, kept in sync with server-side (xray-backuppc repo,
// internal/backupemulator/ech.go + noise_conn.go).
//
// Functions:
//   - ParseECHConfigListB64: base64-decode ECHConfigList (RFC 9460)
//   - GenerateNoiseKeyPair: X25519 keypair for Noise IK handshake
//   - NewNoiseClientConn: Noise IK client connection (ChaCha20-Poly1305 AEAD)
//   - NoiseConn, NoiseKeyPair types (aliased)
package v2

import "backuppc/internal/backupemulator"

// ParseECHConfigListB64 — base64-decode ECHConfigList from URL/API flag.
// Returns raw bytes ready for tls.Config.EncryptedClientHelloConfigList.
var ParseECHConfigListB64 = backupemulator.ParseECHConfigListB64

// GenerateNoiseKeyPair — generate a fresh X25519 keypair for Noise IK.
var GenerateNoiseKeyPair = backupemulator.GenerateNoiseKeyPair

// NewNoiseClientConn — wrap an existing TLS connection with Noise IK.
var NewNoiseClientConn = backupemulator.NewNoiseClientConn

// NoiseConn — Noise-wrapped connection (after IK handshake).
// Implements net.Conn with AEAD encryption of all payload bytes.
type NoiseConn = backupemulator.NoiseConn

// NoiseKeyPair — static X25519 keypair for Noise handshake.
type NoiseKeyPair = backupemulator.NoiseKeyPair
