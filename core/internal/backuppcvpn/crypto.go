// Package backupemulator — crypto.go: file-at-rest encryption for sensitive
// persistent stores (users.json with plaintext UUIDs).
//
// Threat model (Marvia-inspired, see docs/security-comparison.md in
// github.com/jytt8u/marvia): if the database file leaks from disk,
// attacker should NOT immediately get all user UUIDs (each UUID is the
// HMAC key for that user — leak = full credential compromise).
//
// Approach: AES-256-GCM encrypt users.json at rest. The 32-byte key lives
// in a separate file (`<dataDir>/users.key`, 0600 perms). On the same host
// both files are accessible to the server process — but a disk-only leak
// (backup snapshot, file copy, s3 pull) without the key file is useless.
//
// Memory model: User.uuidB stays plaintext in memory (needed for HMAC
// verification — see BackupAuthHeader). Encryption only protects the
// on-disk persistence layer.
//
// Migration: existing plaintext users.json (starts with `{` or `[` JSON
// brackets) is loaded as-is on first run after this code, then re-saved
// as an encrypted blob. No manual migration step needed.

package backuppcvpn

import (
        "crypto/aes"
        "crypto/cipher"
        "crypto/rand"
        "crypto/sha256"
        "encoding/hex"
        "errors"
        "fmt"
        "io"
        "os"
        "path/filepath"
)

// UsersKeyLen — длина server-side AES key для шифрования users.json.
const UsersKeyLen = 32 // AES-256

// encryptedMagic — magic prefix для отличия encrypted blob от plaintext JSON.
// Если файл начинается с этих байт → decrypt; иначе → treat as plaintext JSON.
//
// 4 байта: "ENC1" (encrypted v1). Меняя magic при изменении схемы шифрования,
// можно отличать версии.
var encryptedMagic = []byte("ENC1")

// LoadOrCreateUsersKey — загружает 32-байтовый ключ из path. Если файл
// не существует — генерирует новый, пишет на диск с 0600. Возвращает ключ.
//
// Path обычно: filepath.Join(cfg.DataDir, "users.key").
func LoadOrCreateUsersKey(path string) ([UsersKeyLen]byte, error) {
        var key [UsersKeyLen]byte

        data, err := os.ReadFile(path)
        if err == nil {
                // File exists — validate length.
                if len(data) != UsersKeyLen {
                        return key, fmt.Errorf("users: key file %s: wrong length %d (expected %d)",
                                path, len(data), UsersKeyLen)
                }
                copy(key[:], data)
                return key, nil
        }
        if !os.IsNotExist(err) {
                return key, fmt.Errorf("users: read key %s: %w", path, err)
        }

        // File doesn't exist — generate new key.
        if _, err := rand.Read(key[:]); err != nil {
                return key, fmt.Errorf("users: generate key: %w", err)
        }

        // Write with restrictive perms (0600). Create parent dir if missing.
        if dir := filepath.Dir(path); dir != "" {
                if err := os.MkdirAll(dir, 0o700); err != nil {
                        return key, fmt.Errorf("users: mkdir %s: %w", dir, err)
                }
        }
        if err := os.WriteFile(path, key[:], 0o600); err != nil {
                return key, fmt.Errorf("users: write key %s: %w", path, err)
        }
        return key, nil
}

// encryptBytes — AES-256-GCM encrypt: returns magic || nonce || ciphertext.
// Caller is responsible for keeping `key` private (loaded once at startup).
func encryptBytes(key [UsersKeyLen]byte, plaintext []byte) ([]byte, error) {
        block, err := aes.NewCipher(key[:])
        if err != nil {
                return nil, fmt.Errorf("encrypt: new cipher: %w", err)
        }
        gcm, err := cipher.NewGCM(block)
        if err != nil {
                return nil, fmt.Errorf("encrypt: new gcm: %w", err)
        }
        nonce := make([]byte, gcm.NonceSize())
        if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
                return nil, fmt.Errorf("encrypt: nonce: %w", err)
        }
        // Layout: magic (4) || nonce (12) || ciphertext (N + 16 tag).
        // Magic lets us distinguish encrypted vs plaintext on load.
        out := make([]byte, 0, len(encryptedMagic)+len(nonce)+len(plaintext)+gcm.Overhead())
        out = append(out, encryptedMagic...)
        out = append(out, nonce...)
        out = gcm.Seal(out, nonce, plaintext, nil)
        return out, nil
}

// decryptBytes — reverse of encryptBytes. Returns plaintext if file is
// encrypted with our magic, OR returns input as-is if it doesn't have
// the magic prefix (legacy plaintext file).
//
// This dual behavior enables automatic migration: first time server
// starts after this code, plaintext users.json loads via this function
// (returns input as plaintext), then save() encrypts it. No manual
// migration needed.
func decryptBytes(key [UsersKeyLen]byte, data []byte) ([]byte, error) {
        if len(data) < len(encryptedMagic) {
                // Too short to be encrypted — must be plaintext (or empty).
                return data, nil
        }
        // Check magic. If missing → plaintext JSON, return as-is (migration path).
        if string(data[:len(encryptedMagic)]) != string(encryptedMagic) {
                return data, nil
        }
        // Encrypted: parse magic || nonce || ciphertext.
        body := data[len(encryptedMagic):]
        block, err := aes.NewCipher(key[:])
        if err != nil {
                return nil, fmt.Errorf("decrypt: new cipher: %w", err)
        }
        gcm, err := cipher.NewGCM(block)
        if err != nil {
                return nil, fmt.Errorf("decrypt: new gcm: %w", err)
        }
        nonceSize := gcm.NonceSize()
        if len(body) < nonceSize {
                return nil, errors.New("decrypt: ciphertext too short for nonce")
        }
        nonce := body[:nonceSize]
        ciphertext := body[nonceSize:]
        plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
        if err != nil {
                return nil, fmt.Errorf("decrypt: gcm open: %w", err)
        }
        return plaintext, nil
}

// KeyHex — hex представление ключа для диагностических логов
// (не логируем сам ключ, но его fingerprint может быть полезен).
func KeyFingerprint(key [UsersKeyLen]byte) string {
        // Возвращаем первые 8 hex символов SHA-256 (full fingerprint не нужен).
        // Не используем сам ключ чтобы не утёк в логах.
        h := sha256.Sum256(key[:])
        return hex.EncodeToString(h[:4])
}
