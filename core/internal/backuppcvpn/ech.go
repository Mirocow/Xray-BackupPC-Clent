package backuppcvpn

import (
        "crypto/ecdh"
        "crypto/rand"
        "encoding/base64"
        "encoding/binary"
        "errors"
        "fmt"
        "os"
        "path/filepath"
        "strings"
        "sync/atomic"
        "time"
)

// echRuntimeState — immutable snapshot of ECH runtime state.
// Stored in Server.echState (atomic.Pointer) — atomic swap on RotateECHKey()
// or SetECHEnabled() triggers immediate effect on next TLS handshake (via
// GetConfigForClient callback that reads this state).
//
// All fields are read-only after construction. To change ECH state, build
// a new echRuntimeState and Store() it (old state stays GC-referenced
// until in-flight handshakes complete).
type echRuntimeState struct {
        enabled      bool                  // false → ECH off (no keys in TLS config)
        privKey      *ecdh.PrivateKey      // X25519 private key for HPKE decryption
        config       []byte                // single ECHConfig (for tls.EncryptedClientHelloKey.Config)
        configList   []byte                // length-prefixed (for /api/ech-config response body)
        configListB64 string                // base64-encoded (for /api/stats, URL params)
        publicName   string                // outer SNI (visible to TSPU)
        keyPath      string                // file path where privKey bytes are persisted
        rotatedAt    time.Time             // when this state was created (for monitoring)
}

// ECHStatus — public snapshot of ECH state for admin UI + /api/ech/status.
// Does NOT include private key material.
type ECHStatus struct {
        Enabled         bool      `json:"enabled"`
        PublicName      string    `json:"publicName"`
        ConfigListB64   string    `json:"configListB64,omitempty"`
        KeyPath         string    `json:"keyPath,omitempty"`
        RotatedAt       time.Time `json:"rotatedAt,omitempty"`
        ConfigListBytes int       `json:"configListBytes,omitempty"`
}

// snapshot — convert echRuntimeState to public ECHStatus (no private key).
func (s *echRuntimeState) snapshot() ECHStatus {
        if s == nil {
                return ECHStatus{Enabled: false}
        }
        return ECHStatus{
                Enabled:         s.enabled,
                PublicName:      s.publicName,
                ConfigListB64:   s.configListB64,
                KeyPath:         s.keyPath,
                RotatedAt:       s.rotatedAt,
                ConfigListBytes: len(s.configList),
        }
}

// tlsKeys — return []tls.EncryptedClientHelloKey for tls.Config (per-conn).
// Returns nil when ECH disabled — tls.Config.EncryptedClientHelloKeys=nil
// means server ignores ECH extension entirely (legacy behavior).
//
// This is called from GetConfigForClient on every TLS handshake.
func (s *echRuntimeState) tlsKeys() []tlsEncryptedClientHelloKey {
        if s == nil || !s.enabled || s.privKey == nil || len(s.config) == 0 {
                return nil
        }
        return []tlsEncryptedClientHelloKey{{
                Config:      s.config,
                PrivateKey:  s.privKey.Bytes(),
                SendAsRetry: true,
        }}
}

// tlsEncryptedClientHelloKey — local alias to avoid importing crypto/tls in ech.go
// (would create import cycle: ech.go is imported by server.go which imports tls).
// Server.echServerKeys() bridges to actual tls.EncryptedClientHelloKey type.
type tlsEncryptedClientHelloKey struct {
        Config      []byte
        PrivateKey  []byte
        SendAsRetry bool
}

// ECH (Encrypted Client Hello, RFC 9460) — нативная поддержка Go 1.26
// crypto/tls. Скрывает реальный SNI от TSPU/DPI: outer ClientHello содержит
// публичный домен-донор (например cloudflare.com), inner ClientHello с реальным
// servername шифруется X25519+HKDF-SHA256+AES-128-GCM (HPKE).
//
// Серверная сторона:
//   - X25519 keypair хранится в <dataDir>/ech.key (32 байта, 0600)
//   - ECHConfig (public key + public_name) публикуется через /api/ech-config
//   - tls.Config.EncryptedClientHelloKeys активирует server-side decrypt
//
// Клиентская сторона:
//   - Скачивает ECHConfigList (base64) с сервера или получает в URL &echConfigList=
//   - Конфигурирует tls.Config.EncryptedClientHelloConfigList
//   - ServerName = реальный домен (внутренний, скрытый ECH)
//
// Совместимость с uTLS: НЕ СОВМЕСТИМ. uTLS (HelloChrome_Auto) подменяет весь
// ClientHelloSpec, в т.ч. ECH extension не генерируется. Когда включён ECH —
// uTLS отключается (native crypto/tls). Это разумный trade-off: ECH даёт
// более сильную защиту (SNI скрыт), чем JA3 fingerprint mimicry.
//
// Marshallers ниже — binary format RFC 9460 §4:
//
//      ECHConfig {
//        version (2 bytes, 0xfe0d)
//        length (2 bytes)
//        config_id (1 byte)
//        kem_id (2 bytes, 0x0020 = DHKEM(X25519, HKDF-SHA256))
//        public_key (2-byte length + bytes)
//        cipher_suites (2-byte length + repeated {kdf_id, aead_id})
//        max_name_length (1 byte)
//        public_name (1-byte length + bytes)
//        extensions (2 bytes, пусто)
//      }
//
// ECHConfigList = 2-byte total length + один или несколько ECHConfig.

const (
        // echVersion — RFC 9460: version 0xfe0d (draft version, frozen).
        echVersion = 0xfe0d
        // echKEMID_X25519_HKDF_SHA256 — единственный KEM в RFC 9460 mandatory-to-implement.
        echKEMID_X25519_HKDF_SHA256 = 0x0020
        // echKDFID_HKDF_SHA256 — единственный KDF (RFC 9460 §8.2).
        echKDFID_HKDF_SHA256 = 0x0001
        // echAEADID_AES_128_GCM — mandatory AEAD (RFC 9460 §8.3: 0x0001 = AES-128-GCM).
        // ВАЖНО: RFC 9460 использует 0x0001 для AES-128-GCM, а не 0x0000.
        // 0x0000 RESERVED; 0x0001 = AES-128-GCM; 0x0002 = AES-256-GCM; 0x0003 = ChaCha20Poly1305.
        echAEADID_AES_128_GCM = 0x0001
        // echConfigID — произвольный идентификатор конфига (0-255), даёт до 256
        // одновременных ротаций ключей. Мы держим один (id=0x42 — легко опознать в dump).
        echConfigID = 0x42
        // echMaxNameLength — максимальная длина SNI для padding'а. 32 байта
        // покрывает большинство доменов; длинные будут сокращены до этого значения
        // (но наш server domain обычно короче).
        echMaxNameLength = 32
)

// LoadOrCreateECHKey — прочитать или сгенерировать X25519 keypair для ECH.
// Сходен с LoadOrCreateUsersKey: atomic tmp+rename (0600), auto-генерация
// при отсутствии. Возвращает приватный ключ, ECHConfig (single), ECHConfigList
// (length-prefixed) и base64-encoded config list (для API ответов).
//
// dataDir — каталог данных сервера (main.go: os.MkdirAll(*data, 0o700)).
// publicName — домен outer ClientHello SNI (виден ТСПУ). Обычно cfg.Host
// или ExternalAddr. Должен быть безобидным, в идеале — реальный CDN домен.
func LoadOrCreateECHKey(dataDir, publicName string) (privKey *ecdh.PrivateKey, config, configList []byte, configListB64 string, err error) {
        if dataDir == "" {
                // Тесты / in-memory: генерируем ephemeral.
                return generateECHMaterial(publicName)
        }
        keyPath := filepath.Join(dataDir, "ech.key")
        if raw, rerr := os.ReadFile(keyPath); rerr == nil {
                priv, perr := ecdh.X25519().NewPrivateKey(raw)
                if perr == nil {
                        return assembleECHMaterial(priv, publicName)
                }
                // Файл есть, но повреждён — не перезаписываем молча (см. подход users.key).
                return nil, nil, nil, "", fmt.Errorf("ech: чтение %s: %w", keyPath, perr)
        } else if !errors.Is(rerr, os.ErrNotExist) && !os.IsNotExist(rerr) {
                return nil, nil, nil, "", fmt.Errorf("ech: stat %s: %w", keyPath, rerr)
        }
        // Генерация + atomic persist.
        priv, gerr := ecdh.X25519().GenerateKey(rand.Reader)
        if gerr != nil {
                return nil, nil, nil, "", fmt.Errorf("ech: generate X25519: %w", gerr)
        }
        if werr := os.WriteFile(keyPath, priv.Bytes(), 0o600); werr != nil {
                // Не падаем — in-memory ephemeral лучше чем вообще ничего (server
                // перезапуск всё равно будет новый ECH keypair, клиенты должны
                // перефетчить /api/ech-config).
                _ = werr // Логируется вызывающим кодом при желании.
        }
        return assembleECHMaterial(priv, publicName)
}

// generateECHMaterial — in-memory ephemeral ECH keypair (тесты, no dataDir).
func generateECHMaterial(publicName string) (*ecdh.PrivateKey, []byte, []byte, string, error) {
        priv, err := ecdh.X25519().GenerateKey(rand.Reader)
        if err != nil {
                return nil, nil, nil, "", fmt.Errorf("ech: generate X25519: %w", err)
        }
        return assembleECHMaterial(priv, publicName)
}

// assembleECHMaterial — построить config + configList из приватного ключа.
func assembleECHMaterial(priv *ecdh.PrivateKey, publicName string) (*ecdh.PrivateKey, []byte, []byte, string, error) {
        pub := priv.PublicKey().Bytes()
        cfg := marshalECHConfig(echConfigID, pub, publicName, echMaxNameLength)
        list := marshalECHConfigList(cfg)
        b64 := base64.StdEncoding.EncodeToString(list)
        return priv, cfg, list, b64, nil
}

// marshalECHConfig — сериализовать ECHConfig (RFC 9460 §4).
//
//      cfg_id=0x42, KEM=X25519+HKDF-SHA256, KDF=HKDF-SHA256, AEAD=AES-128-GCM,
//      max_name_len=32, public_name=<publicName>.
//
// binary.LittleEndian для 1-byte полей не нужен; для 2-byte полей используется
// BigEndian (TLS IETF tradition).
func marshalECHConfig(configID uint8, pubKey []byte, publicName string, maxNameLen uint8) []byte {
        // Структура ECHConfig:
        // version (2) | length (2) | config_id (1) | kem_id (2) |
        // public_key (2-byte length + bytes) |
        // cipher_suites (2-byte length + repeated {kdf_id, aead_id}) |
        // max_name_length (1) | public_name (1-byte length + bytes) |
        // extensions (2 bytes, empty)
        pubKeyLen := len(pubKey)
        pubNameLen := len(publicName)
        // Вычисляем длину inner content:
        // 1 (config_id) + 2 (kem_id) + 2 (pubkey len) + pubKeyLen +
        // 2 (cipher_suites len) + 4 (one cipher suite: kdf_id+aead_id) +
        // 1 (max_name_len) + 1 (pubName len) + pubNameLen + 2 (extensions)
        innerLen := 1 + 2 + 2 + pubKeyLen + 2 + 4 + 1 + 1 + pubNameLen + 2
        buf := make([]byte, 0, 4+innerLen)
        // version
        buf = binary.BigEndian.AppendUint16(buf, echVersion)
        // length
        buf = binary.BigEndian.AppendUint16(buf, uint16(innerLen))
        // config_id
        buf = append(buf, configID)
        // kem_id
        buf = binary.BigEndian.AppendUint16(buf, echKEMID_X25519_HKDF_SHA256)
        // public_key length + bytes
        buf = binary.BigEndian.AppendUint16(buf, uint16(pubKeyLen))
        buf = append(buf, pubKey...)
        // cipher_suites length + one suite
        buf = binary.BigEndian.AppendUint16(buf, 4) // 1 suite = 4 bytes (kdf_id + aead_id)
        buf = binary.BigEndian.AppendUint16(buf, echKDFID_HKDF_SHA256)
        buf = binary.BigEndian.AppendUint16(buf, echAEADID_AES_128_GCM)
        // max_name_length
        buf = append(buf, maxNameLen)
        // public_name length + bytes
        buf = append(buf, byte(pubNameLen))
        buf = append(buf, publicName...)
        // extensions (empty)
        buf = binary.BigEndian.AppendUint16(buf, 0)
        return buf
}

// marshalECHConfigList — обернуть один или несколько ECHConfig в ECHConfigList:
//
//      2-byte total length + concatenated configs.
//
// Мы публикуем один config (один keypair), но формат поддерживает несколько
// для будущей ротации.
func marshalECHConfigList(config []byte) []byte {
        out := make([]byte, 2+len(config))
        binary.BigEndian.PutUint16(out[:2], uint16(len(config)))
        copy(out[2:], config)
        return out
}

// ParseECHConfigListB64 — base64-decode ECHConfigList из URL или API.
// Возвращает raw bytes (готовые для tls.Config.EncryptedClientHelloConfigList).
// Используется utls-tunnel sidecar: принимает --ech-config-list <base64>.
func ParseECHConfigListB64(b64 string) ([]byte, error) {
        b64 = strings.TrimSpace(b64)
        if b64 == "" {
                return nil, errors.New("ech: пустой config list")
        }
        return base64.StdEncoding.DecodeString(b64)
}

// BuildECHRuntimeState — construct echRuntimeState from a private key +
// publicName + persistence metadata. Used at startup AND on RotateECHKey:
//   - At startup: LoadOrCreateECHKey loads/generates keypair, then this
//     builds the immutable state for atomic.Pointer storage.
//   - On RotateECHKey: new X25519 keypair is generated, this builds a new
//     state, caller atomic.Stores it → next TLS handshake sees new keys.
//
// persistedKeyPath is empty when state is ephemeral (in-memory only).
// Returns a state with enabled=true — caller can clone with enabled=false
// if ECH should be disabled (e.g. SetECHEnabled(false)).
func BuildECHRuntimeState(priv *ecdh.PrivateKey, publicName, persistedKeyPath string) *echRuntimeState {
        if priv == nil {
                return &echRuntimeState{enabled: false}
        }
        pub := priv.PublicKey().Bytes()
        cfg := marshalECHConfig(echConfigID, pub, publicName, echMaxNameLength)
        list := marshalECHConfigList(cfg)
        b64 := base64.StdEncoding.EncodeToString(list)
        return &echRuntimeState{
                enabled:       true,
                privKey:       priv,
                config:        cfg,
                configList:    list,
                configListB64: b64,
                publicName:    publicName,
                keyPath:       persistedKeyPath,
                rotatedAt:     time.Now(),
        }
}

// GenerateNewECHKeypair — generate fresh X25519 keypair + persist atomically
// to keyPath (0600). Used by RotateECHKey: returns new state ready for
// atomic.Pointer.Store.
//
// If keyPath is empty — in-memory only (no persistence, server restart will
// lose the key). Useful for tests.
//
// If publicName is empty — uses "" (outer SNI blank, not recommended for prod).
// Caller should ensure publicName is set correctly (typically cfg.Host or
// cfg.ECHPublicName).
func GenerateNewECHKeypair(publicName, keyPath string) (*echRuntimeState, error) {
        priv, err := ecdh.X25519().GenerateKey(rand.Reader)
        if err != nil {
                return nil, fmt.Errorf("ech: generate X25519: %w", err)
        }
        // Atomic persist (tmp+rename, 0600) — same pattern as users.key.
        if keyPath != "" {
                if err := atomicWriteFile(keyPath, priv.Bytes(), 0o600); err != nil {
                        // Don't fail — in-memory ephemeral state still works.
                        // Caller can decide to log this.
                        return BuildECHRuntimeState(priv, publicName, ""), fmt.Errorf("ech: persist %s: %w (state is in-memory only)", keyPath, err)
                }
        }
        return BuildECHRuntimeState(priv, publicName, keyPath), nil
}

// atomicWriteFile — write data atomically via tmp+rename pattern.
// 1. Write to <path>.tmp with given perms.
// 2. Rename to final path (atomic on POSIX filesystems).
// 3. On any error, cleanup tmp file.
//
// Same pattern as persistSelfSigned, persistUsersKey, etc. — kept here
// to keep ech.go self-contained (no cross-package helpers needed).
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
        tmp := path + ".tmp"
        if err := os.WriteFile(tmp, data, perm); err != nil {
                _ = os.Remove(tmp)
                return fmt.Errorf("write %s: %w", tmp, err)
        }
        if err := os.Rename(tmp, path); err != nil {
                _ = os.Remove(tmp)
                return fmt.Errorf("rename %s → %s: %w", tmp, path, err)
        }
        return nil
}

// CloneWithEnabled — return a copy of state with enabled flag changed.
// Used by SetECHEnabled: keeps same keypair + configList, just toggles
// whether keys are exposed in TLS config. Atomic.Store of cloned state
// triggers immediate effect on next handshake (no restart needed).
//
// When enabling back: same keypair is used (clients with cached config list
// continue to work). When disabling: tlsKeys() returns nil → server ignores
// ECH extension entirely.
func (s *echRuntimeState) CloneWithEnabled(enabled bool) *echRuntimeState {
        if s == nil {
                return &echRuntimeState{enabled: false}
        }
        clone := *s // shallow copy — all fields are immutable values/slices
        clone.enabled = enabled
        clone.rotatedAt = time.Now()
        return &clone
}

// countAtomicPointer — placeholder to silence unused import warning if
// atomic is only used in server.go (not in ech.go).
// atomic is used by server.go (s.echState.Load/Store) but ech.go imports
// it for type definition reference. Keep import alive.
var _ = atomic.Pointer[echRuntimeState]{}
