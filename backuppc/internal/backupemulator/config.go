// Package backupemulator — транспортный плагин «Backup-Emulator»
// (VLESS over Dynamic HTTP/2 Streams).
//
// Маскировка прокси-трафика под передачу файлов корпоративного
// бэкап-хранилища: бинарный фрейминг с рандомным паддингом (ТЗ 3.1),
// джиттер-пинги (ТЗ 3.2), выравнивание плеч трафика (ТЗ 3.3),
// дробление сессий на чанки (ТЗ 3.4) и защита от активного
// зондирования (ТЗ, раздел 6).
package backupemulator

import (
        "context"
        "crypto/rand"
        "encoding/hex"
        "encoding/json"
        "errors"
        "fmt"
        "math/big"
        "net"
        "net/url"
        "os"
        "strconv"
        "strings"
        "time"
)

// Duration — обертка над time.Duration для JSON-конфигураций:
// принимает строки ("20s", "15m", "1.5h") и числа (секунды).
type Duration struct{ time.Duration }

// D — нативное представление.
func (d Duration) D() time.Duration { return d.Duration }

// Dur — конструктор из нативной длительности.
func Dur(d time.Duration) Duration { return Duration{Duration: d} }

func (d Duration) String() string { return d.Duration.String() }

// UnmarshalJSON реализует прием строк и секунд (float) из JSON.
func (d *Duration) UnmarshalJSON(data []byte) error {
        s := strings.TrimSpace(string(data))
        if s == "" || s == "null" {
                return nil
        }
        if s[0] == '"' {
                var str string
                if err := json.Unmarshal(data, &str); err != nil {
                        return err
                }
                v, err := time.ParseDuration(str)
                if err != nil {
                        return fmt.Errorf("config: некорректная длительность %q: %w", str, err)
                }
                d.Duration = v
                return nil
        }
        var sec float64
        if err := json.Unmarshal(data, &sec); err != nil {
                return fmt.Errorf("config: длительность должна быть строкой (\"20s\") или числом секунд: %w", err)
        }
        d.Duration = time.Duration(sec * float64(time.Second))
        return nil
}

// MarshalJSON — обратно в строку.
func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.Duration.String()) }

// TransportConfig — общая конфигурация транспорта клиента и сервера (ТЗ, раздел 2).
type TransportConfig struct {
        // Мимикрия
        EndpointPaths []string `json:"endpointPaths"` // gRPC-методы «узла хранения» (несущие вызовы)
        Host          string   `json:"host"`          // Домен-донор (Host/SNI)
        UserAgent     string   `json:"userAgent"`     // UA агента бэкапа (пусто → пул BackupPC-агентов)

        // Паддинг (ТЗ 3.1)
        MinPaddingSize int `json:"minPaddingSize"` // Дефолт: 32
        MaxPaddingSize int `json:"maxPaddingSize"` // Дефолт: 1400

        // Джиттер пингов (ТЗ 3.2)
        PingBaseInterval Duration `json:"pingBaseInterval"` // Дефолт: 20s
        PingJitterMax    Duration `json:"pingJitterMax"`    // Дефолт: 15s

        // Балансировка асимметрии (ТЗ 3.3)
        BalancingInterval Duration `json:"balancingInterval"` // Дефолт: 5s
        MinTxThreshold    int64    `json:"minTxThreshold"`    // Дефолт: 16384

        // Дробление сессий (ТЗ 3.4)
        MaxSessionDuration Duration `json:"maxSessionDuration"` // Дефолт: 30m
        MaxSessionBytes    int64    `json:"maxSessionBytes"`    // Дефолт: 2 GiB

        // Эмуляция периодических бекапов BackupPC (раздел 4)
        BackupPC BackupPCConfig `json:"backuppc"`

        // --- Расширения прототипа (не входили в базовое ТЗ) ---

        MaxWriteChunk int `json:"maxWriteChunk"` // Максимум payload в одном кадре, дефолт: 65535
        // FakeUploadChunk — объем фейкового аплоада за одно срабатывание
        // балансировщика, дефолт: 512 KiB (ТЗ 4.2: 1024*512).
        FakeUploadChunk int `json:"fakeUploadChunk"`
        // IdleTimeout — бездрейфовый таймаут логической сессии на сервере.
        IdleTimeout Duration `json:"idleTimeout"` // Дефолт: 90s
        // DialRetries — попытки набора нового чанка при ротации.
        DialRetries int `json:"dialRetries"` // Дефолт: 3
        // RotationGrace — окно добивки хвоста очереди при финальном
        // завершении сессии (источники остановлены).
        RotationGrace Duration `json:"rotationGrace"` // Дефолт: 250ms
        // RotationHandoff — окно ожидания преемника при ротации: pump старого
        // чанка продолжает отдавать очередь, пока не прибудет чанк N+1.
        RotationHandoff Duration `json:"rotationHandoff"` // Дефолт: 3s
}

// ServerConfig — конфигурация inbound-транспорта (Listener).
type ServerConfig struct {
        TransportConfig
        Listen   string `json:"listen"`   // Например: "0.0.0.0:8443"
        UUID     string `json:"uuid"`     // UUID пользователя VLESS
        CertFile string `json:"certFile"` // PEM-сертификат TLS (пусто → self-signed)
        KeyFile  string `json:"keyFile"`  // PEM-ключ TLS
}

// ClientConfig — конфигурация outbound-транспорта (Dialer).
type ClientConfig struct {
        TransportConfig
        ServerAddr  string `json:"serverAddr"`  // Адрес Backup-Emulator сервера
        UUID        string `json:"uuid"`        // UUID пользователя VLESS
        SocksListen string `json:"socksListen"` // Локальный SOCKS5 inbound, дефолт: 127.0.0.1:1080
        Insecure    bool   `json:"insecure"`    // Пропуск верификации TLS (только для тестов)
        // CertFingerprint — SHA-256 (hex) сертификата сервера; при непустом
        // значении включается пиннинг вместо CA-верификации.
        CertFingerprint string `json:"certFingerprint"`

        // DialContext — кастомный диалер для TCP-соединений к серверу.
        // nil → стандартный net.Dialer (текущее поведение: Linux/OpenWrt/desktop).
        // Не-nil → используется в http.Transport.DialContext.
        //
        // На Android: Xray's internet.DialSystem передаётся сюда →
        // каждый TCP-коннект к серверу вызывает VpnService.protect() →
        // трафик туннеля НЕ идёт обратно в TUN (нет петли).
        //
        // json:"-" — runtime-only, не сериализуется в JSON config.
        DialContext func(ctx context.Context, network, addr string) (net.Conn, error) `json:"-"`
}

// defaultEndpointPaths — пул несущих gRPC-методов «узла хранения» по
// умолчанию: 10 сервисов / 18 методов (bidi-стримы). Первые три —
// исходный пул ранних версий (обратная совместимость: ссылки со старым
// endpoints= и клиенты со старыми дефолтами продолжают работать).
func defaultEndpointPaths() []string {
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

// ApplyDefaults заполняет значения по умолчанию из ТЗ.
func (tc *TransportConfig) ApplyDefaults() {
        if len(tc.EndpointPaths) == 0 {
                tc.EndpointPaths = defaultEndpointPaths()
        }
        // UserAgent: пусто → пул агентов BackupPC (выбор при каждом dial).
        tc.BackupPC.applyDefaults()
        if tc.MinPaddingSize == 0 {
                tc.MinPaddingSize = 32
        }
        if tc.MaxPaddingSize == 0 {
                tc.MaxPaddingSize = 1400
        }
        if tc.PingBaseInterval.D() == 0 {
                tc.PingBaseInterval = Duration{20 * time.Second}
        }
        if tc.PingJitterMax.D() == 0 {
                tc.PingJitterMax = Duration{15 * time.Second}
        }
        if tc.BalancingInterval.D() == 0 {
                tc.BalancingInterval = Duration{5 * time.Second}
        }
        if tc.MinTxThreshold == 0 {
                tc.MinTxThreshold = 16384
        }
        if tc.MaxSessionDuration.D() == 0 {
                tc.MaxSessionDuration = Duration{30 * time.Minute}
        }
        if tc.MaxSessionBytes == 0 {
                tc.MaxSessionBytes = 2 * 1024 * 1024 * 1024
        }
        if tc.MaxWriteChunk == 0 {
                // 64 КиБ на кадр: вчетверо меньше gRPC-сообщений/сисколов на байт
                // при том же фрейминге (кадр ≤ 0xFFFF + паддинг 32..1400);
                // синхронизировано с дефолтом сервера (xray-backuppc).
                tc.MaxWriteChunk = 65535
        }
        if tc.FakeUploadChunk == 0 {
                tc.FakeUploadChunk = 512 * 1024
        }
        if tc.IdleTimeout.D() == 0 {
                tc.IdleTimeout = Duration{90 * time.Second}
        }
        if tc.DialRetries == 0 {
                tc.DialRetries = 3
        }
        if tc.RotationGrace.D() == 0 {
                tc.RotationGrace = Duration{250 * time.Millisecond}
        }
        if tc.RotationHandoff.D() == 0 {
                tc.RotationHandoff = Duration{3 * time.Second}
        }
}

// Validate проверяет границы значений (padding — uint16, лимиты — положительные).
func (tc *TransportConfig) Validate() error {
        if len(tc.EndpointPaths) == 0 {
                return errors.New("config: endpointPaths пуст")
        }
        for i, p := range tc.EndpointPaths {
                if !strings.HasPrefix(p, "/") {
                        return fmt.Errorf("config: endpointPaths[%d] должен начинаться с '/': %q", i, p)
                }
        }
        if tc.MinPaddingSize < 0 || tc.MaxPaddingSize > 0xFFFF || tc.MinPaddingSize > tc.MaxPaddingSize {
                return fmt.Errorf("config: некорректные границы паддинга [%d..%d] (0..65535, min<=max)",
                        tc.MinPaddingSize, tc.MaxPaddingSize)
        }
        if tc.MaxWriteChunk < 64 || tc.MaxWriteChunk > 0xFFFF {
                return fmt.Errorf("config: maxWriteChunk должен быть в [64..65535]: %d", tc.MaxWriteChunk)
        }
        if tc.PingBaseInterval.D() <= 0 {
                return errors.New("config: pingBaseInterval должен быть > 0")
        }
        if tc.PingJitterMax.D() < 0 {
                return errors.New("config: pingJitterMax не может быть отрицательным")
        }
        if tc.BalancingInterval.D() < 0 {
                return errors.New("config: balancingInterval не может быть отрицательным")
        }
        if tc.MinTxThreshold < 0 || tc.MaxSessionBytes <= 0 {
                return errors.New("config: minTxThreshold >= 0 и maxSessionBytes > 0 обязательны")
        }
        if tc.MaxSessionDuration.D() <= 0 {
                return errors.New("config: maxSessionDuration должен быть > 0")
        }
        if tc.FakeUploadChunk < 0 {
                return errors.New("config: fakeUploadChunk не может быть отрицательным")
        }
        bc := &tc.BackupPC
        if bc.IncrementalEvery.D() < 0 || bc.FullEvery.D() < 0 {
                return errors.New("config: интервалы backuppc не могут быть отрицательными")
        }
        if bc.IncrementalMinBytes < 0 || bc.IncrementalMaxBytes < bc.IncrementalMinBytes ||
                bc.FullMinBytes < 0 || bc.FullMaxBytes < bc.FullMinBytes {
                return errors.New("config: некорректные границы объемов backuppc (min<=max, min>=0)")
        }
        if bc.NightStartHour < 0 || bc.NightStartHour > 23 || bc.NightEndHour < 0 || bc.NightEndHour > 23 {
                return errors.New("config: ночное окно backuppc — часы 0..23")
        }
        return nil
}

// randPadding — криптографически случайный размер паддинга кадра (ТЗ 3.1).
func (tc *TransportConfig) randPadding() (int, error) {
        return randIntRange(tc.MinPaddingSize, tc.MaxPaddingSize)
}

// randomEndpoint — случайный gRPC-метод из endpointPaths (несущий вызов;
// по ТЗ 3.4 каждая ротация идет на случайный «путь» — теперь метод).
func (tc *TransportConfig) randomEndpoint() string {
        if len(tc.EndpointPaths) == 0 {
                return "/backuppc.BackupService/BackupStream"
        }
        i, err := randIntRange(0, len(tc.EndpointPaths)-1)
        if err != nil {
                i = 0
        }
        return tc.EndpointPaths[i]
}

// --- Криптографические помощники (без math/rand) ---

// randIntRange — равномерно случайное [min, max] через crypto/rand.
func randIntRange(min, max int) (int, error) {
        if max < min {
                min, max = max, min
        }
        if max == min {
                return min, nil
        }
        n, err := rand.Int(rand.Reader, big.NewInt(int64(max-min+1)))
        if err != nil {
                return min, err
        }
        return min + int(n.Int64()), nil
}

// randDurationRange — случайная длительность в [min, max].
func randDurationRange(min, max time.Duration) time.Duration {
        span := int64(max - min)
        if span <= 0 {
                return min
        }
        n, err := rand.Int(rand.Reader, big.NewInt(span))
        if err != nil {
                return min
        }
        return min + time.Duration(n.Int64())
}

// randomSessionID — 128-битный идентификатор бэкап-сессии (hex).
func randomSessionID() string {
        b := make([]byte, 16)
        if _, err := rand.Read(b); err != nil {
                return strconv.FormatInt(time.Now().UnixNano(), 16)
        }
        return hex.EncodeToString(b)
}

// ParseUUID — разбор UUID (с дефисами и без) в 16 байт.
func ParseUUID(s string) ([16]byte, error) {
        var id [16]byte
        clean := strings.ReplaceAll(strings.TrimSpace(s), "-", "")
        if len(clean) != 32 {
                return id, fmt.Errorf("uuid: некорректная длина %d (ожидалось 32 hex-символа)", len(clean))
        }
        raw, err := hex.DecodeString(clean)
        if err != nil {
                return id, fmt.Errorf("uuid: %w", err)
        }
        copy(id[:], raw)
        return id, nil
}

// LoadServerConfig читает и валидирует JSON-профиль сервера.
func LoadServerConfig(path string) (*ServerConfig, error) {
        cfg := &ServerConfig{}
        if err := loadJSON(path, cfg); err != nil {
                return nil, err
        }
        cfg.ApplyDefaults()
        if cfg.Listen == "" {
                cfg.Listen = "0.0.0.0:8443"
        }
        if err := cfg.Validate(); err != nil {
                return nil, err
        }
        if _, err := ParseUUID(cfg.UUID); err != nil {
                return nil, fmt.Errorf("config: %w", err)
        }
        return cfg, nil
}

// LoadClientConfig читает и валидирует JSON-профиль клиента.
func LoadClientConfig(path string) (*ClientConfig, error) {
        cfg := &ClientConfig{}
        if err := loadJSON(path, cfg); err != nil {
                return nil, err
        }
        cfg.ApplyDefaults()
        if cfg.SocksListen == "" {
                cfg.SocksListen = "127.0.0.1:1080"
        }
        if err := cfg.Validate(); err != nil {
                return nil, err
        }
        if cfg.ServerAddr == "" {
                return nil, errors.New("config: serverAddr обязателен")
        }
        if _, err := url.Parse("https://" + cfg.ServerAddr); err != nil {
                return nil, fmt.Errorf("config: некорректный serverAddr: %w", err)
        }
        if _, err := ParseUUID(cfg.UUID); err != nil {
                return nil, fmt.Errorf("config: %w", err)
        }
        return cfg, nil
}

func loadJSON(path string, v any) error {
        if path == "" {
                return nil
        }
        data, err := os.ReadFile(path)
        if err != nil {
                return fmt.Errorf("config: %w", err)
        }
        if err := json.Unmarshal(data, v); err != nil {
                return fmt.Errorf("config: %s: %w", path, err)
        }
        return nil
}
