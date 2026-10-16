package backuppcvpn

// UserManager — слой 3 (xray): реестр клиентов «как в Xray».
//
// Динамическое добавление/удаление пользователей (email + UUID) без
// перезапуска сервера — семантика Xray HandlerService.AlterInbound
// (AddUser/RemoveUser). Каждый UUID:
//   - ключ HMAC несущего канала (X-Backup-Auth, ТЗ 6);
//   - идентификатор VLESS-запроса (слой 2);
//   - единица учета трафика и квот (слой 3).
//
// Персистентность — users.json (атомарная запись tmp+rename).

import (
        "crypto/rand"
        "encoding/hex"
        "encoding/json"
        "errors"
        "fmt"
        "log/slog"
        "os"
        "sort"
        "strings"
        "sync"
        "sync/atomic"
        "time"
)

// UserSeed — стартовое описание клиента в конфиге сервера.
type UserSeed struct {
        Email      string `json:"email"`
        ExternalID string `json:"externalId,omitempty"` // Marvia-style: opaque ID for bots/billing
        UUID       string `json:"uuid"`
        Level      int    `json:"level"`
        ExpiryUnix int64  `json:"expiryUnix"`
        QuotaBytes int64  `json:"quotaBytes"`
}

// User — учетная запись клиента.
type User struct {
        Email string `json:"email"`
        // ExternalID — opaque ID для внешних систем (бот, биллинг).
        // Когда непустой — admin UI и API должны показывать его
        // вместо email (privacy: email не нужен для VPN-сервиса,
        // это просто contact info который админ может не хранить).
        //
        // MVP (audit 2026-10-12, Marvia-inspired): поле добавлено, но
        // email остаётся primary key для lookup (byEmail map). Full migration
        // к external_id-only — отдельная задача, см. docs/PRIVACY-MIGRATION.md.
        ExternalID string `json:"externalId,omitempty"`
        UUID       string `json:"uuid"`
        Level      int    `json:"level"`
        ExpiryUnix int64  `json:"expiryUnix"` // 0 = бессрочно
        QuotaBytes int64  `json:"quotaBytes"` // 0 = безлимит (up+down)
        Disabled   bool   `json:"disabled"`
        AddedAt    int64  `json:"addedAt"`
        MaxConcurrentSessions int    `json:"maxConcurrentSessions,omitempty"`
        MaxConcurrentChunks   int    `json:"maxConcurrentChunks,omitempty"`
        CpuWeight             int    `json:"cpuWeight,omitempty"`
        MaxCpuPercent         int    `json:"maxCpuPercent,omitempty"` // max CPU% per client (0=no limit, 15=15%)
        MaxRateUp             int64  `json:"maxRateUp,omitempty"`     // max upload bytes/sec (0=no limit)
        MaxRateDown           int64  `json:"maxRateDown,omitempty"`   // max download bytes/sec (0=no limit)
        IsPeer                bool   `json:"isPeer,omitempty"`        // true = this "user" is a peer server in cluster
        // MaxDevices — лимит одновременных устройств на аккаунт (по RemoteAddr).
        // 0 = без лимита (по умолчанию).
        // Если SingleDeviceMode = true — поле игнорируется, лимит = 1.
        MaxDevices int `json:"maxDevices,omitempty"`
        // SingleDeviceMode — форсировать лимит 1 устройство на аккаунт
        // (override серверного MaxDevicesPerAccount для этого юзера).
        // Новое устройство блокирует вход, пока старое активно.
        SingleDeviceMode bool `json:"singleDeviceMode,omitempty"`

        uuidB     [16]byte     // бинарный UUID (HMAC/VLESS)
        upBytes   atomic.Int64 // завершенный аплоад (payload)
        downBytes atomic.Int64 // завершенный даунлоад (payload)
}

// DisplayID — что показывать в UI/логах как идентификатор пользователя.
// Если есть ExternalID — он (privacy-friendly), иначе email (legacy).
//
// Marvia-style: admin не должен видеть email если у клиента есть
// external_id (например, Telegram ID от бота). Email = контактная info,
// не идентификатор.
func (u *User) DisplayID() string {
        if u.ExternalID != "" {
                return u.ExternalID
        }
        return u.Email
}

// UserInfo — DTO для панели и API (копия, безопасная для передачи).
type UserInfo struct {
        Email      string `json:"email"`
        ExternalID string `json:"externalId,omitempty"` // MVP: surfaced for admin UI display
        UUID       string `json:"uuid"`
        Level                 int    `json:"level"`
        ExpiryUnix            int64  `json:"expiryUnix"`
        QuotaBytes            int64  `json:"quotaBytes"`
        Disabled              bool   `json:"disabled"`
        AddedAt               int64  `json:"addedAt"`
        UsedBytes             int64  `json:"usedBytes"`
        MaxConcurrentSessions int    `json:"maxConcurrentSessions,omitempty"`
        MaxConcurrentChunks   int    `json:"maxConcurrentChunks,omitempty"`
        CpuWeight             int    `json:"cpuWeight,omitempty"`
        MaxCpuPercent         int    `json:"maxCpuPercent,omitempty"`
        MaxRateUp             int64  `json:"maxRateUp,omitempty"`
        MaxRateDown           int64  `json:"maxRateDown,omitempty"`
        IsPeer                bool   `json:"isPeer,omitempty"`
        MaxDevices            int    `json:"maxDevices,omitempty"`
        SingleDeviceMode      bool   `json:"singleDeviceMode,omitempty"`
        // UpBytes/DownBytes — накопленный трафик по направлениям
        // (завершенные сессии; живые добаляет панель отдельно).
        UpBytes   int64 `json:"upBytes"`
        DownBytes int64 `json:"downBytes"`
}

// UserManager — потокобезопасный реестр.
type UserManager struct {
        mu      sync.RWMutex
        order   []*User
        byEmail map[string]*User
        byUUID  map[string]*User
        // byExternalID — lookup by ExternalID (Marvia-style: opaque ID
        // for bots/billing). Empty external_id → NOT in this map.
        // Lookup() checks byExternalID first, then byEmail (backward compat).
        byExternalID map[string]*User
        path    string // users.json; "" = только память
        logger  *slog.Logger

        // usersKey — AES-256 key для шифрования users.json at rest (Marvia-
        // inspired: защита при утечке БД). Нулевой массив = шифрование ОТКЛЮЧЕНО
        // (поведение как до этого поля — plaintext JSON). Заполняется через
        // SetUsersKey() из Server на старте.
        //
        // In-memory хранилище (User.uuidB) ВСЁ РАВНО содержит plaintext UUID —
        // это нужно для HMAC auth verification (BackupAuthHeader использует
        // uuidB как HMAC key). Шифрование защищает ТОЛЬКО on-disk persistence.
        usersKey [UsersKeyLen]byte
        usersKeySet bool

        // trafficPath — файл накопительного трафика клиентов (traffic.json);
        // dirty — атомный флаг «есть несохраненные байты» (сбрасывается
        // при FlushTraffic). Живые байты активных сессий в файл НЕ пишутся —
        // только завершенные, чтобы после рестарта не потерять квоты.
        trafficPath  string
        trafficDirty atomic.Bool

        // onRemove — callback при удалении пользователя (используется Server,
        // чтобы почистить userSessionCount/userChunkCount/userBulkCount sync.Map
        // entries и не допустить утечку по «used-once» email-ключам).
        onRemove func(email string)
        // onAdd — callback при добавлении пользователя (Server использует для
        // plugin.HookOnUserAdd dispatch).
        onAdd func(email, uuid string)
}

// SetUsersKey — устанавливает AES-256 key для шифрования users.json.
// Вызывается Server-ом на старте после LoadOrCreateUsersKey().
// Если key — нулевой массив, шифрование остаётся ОТКЛЮЧЕННЫМ (plaintext).
func (m *UserManager) SetUsersKey(key [UsersKeyLen]byte) {
        m.mu.Lock()
        m.usersKey = key
        m.usersKeySet = true
        m.mu.Unlock()
}

// NewUserManager — пустой реестр (path="" — без персистентности).
func NewUserManager(path string, logger *slog.Logger) *UserManager {
        if logger == nil {
                logger = slog.Default()
        }
        return &UserManager{
                byEmail:      map[string]*User{},
                byUUID:       map[string]*User{},
                byExternalID: map[string]*User{},
                path:    path,
                logger:  logger.With("component", "users"),
        }
}

// LoadSeeds — загрузка users.json; при его отсутствии — создание
// реестра из стартовых описаний конфига (легаси-uuid становится
// клиентом "default").
func (m *UserManager) LoadSeeds(seeds []UserSeed) error {
        if m.path != "" {
                if _, err := os.Stat(m.path); err == nil {
                        if err := m.load(); err != nil {
                                return err
                        }
                        m.loadTraffic()
                        m.logger.Info("users store loaded", "path", m.path, "users", len(m.order))
                        return nil
                }
        }
        for i, s := range seeds {
                if _, err := m.Add(s.Email, s.UUID, s.Level, s.ExpiryUnix, s.QuotaBytes); err != nil {
                        return fmt.Errorf("users: seed[%d] %q: %w", i, s.Email, err)
                }
        }
        if len(seeds) > 0 {
                m.logger.Info("users seeded from config", "users", len(seeds))
        }
        return m.Persist()
}

// load — чтение users.json.
//
// ENCRYPTION (audit 2026-10-12, Marvia-inspired): если usersKey установлен
// через SetUsersKey, файл расшифровывается AES-256-GCM перед JSON-unmarshal.
// Старый plaintext формат поддерживается автоматически (если decrypt не
// находит наш magic prefix → трактует как plaintext JSON — миграция).
func (m *UserManager) load() error {
        data, err := os.ReadFile(m.path)
        if err != nil {
                return fmt.Errorf("users: %w", err)
        }
        // Decrypt if encryption key is set. decryptBytes is a no-op if the
        // file doesn't start with our magic prefix (handles legacy plaintext).
        if m.usersKeySet {
                data, err = decryptBytes(m.usersKey, data)
                if err != nil {
                        return fmt.Errorf("users: decrypt %s: %w", m.path, err)
                }
        }
        var doc struct {
                Users []*User `json:"users"`
        }
        if err := json.Unmarshal(data, &doc); err != nil {
                return fmt.Errorf("users: %s: %w", m.path, err)
        }
        for _, u := range doc.Users {
                id, err := ParseUUID(u.UUID)
                if err != nil {
                        m.logger.Warn("users: пропуск некорректного uuid", "email", u.Email, "err", err.Error())
                        continue
                }
                u.uuidB = id
                m.insertLocked(u)
        }
        // If file was plaintext (no magic prefix) and encryption key is set,
        // re-save as encrypted immediately to upgrade on-disk format.
        if m.usersKeySet && len(data) > 0 && string(data[:min(len(data), 4)]) != string(encryptedMagic) {
                m.logger.Info("users: encrypting plaintext file at rest (migration)", "path", m.path)
                _ = m.persistLocked() // ignore error — encryption is best-effort
        }
        return nil
}

// min — helper for the migration check above.
func min(a, b int) int {
        if a < b {
                return a
        }
        return b
}

// insertLocked — вставка под mu (перед вызовом проверить уникальность).
// Ключ byUUID — 32-hex без дефисов (канон бинарного UUID).
// Ключ byExternalID — только если external_id непустой.
func (m *UserManager) insertLocked(u *User) {
        m.order = append(m.order, u)
        m.byEmail[u.Email] = u
        m.byUUID[hex.EncodeToString(u.uuidB[:])] = u
        if u.ExternalID != "" {
                m.byExternalID[u.ExternalID] = u
        }
}

// Persist — атомарная запись реестра.
//
// ENCRYPTION (audit 2026-10-12, Marvia-inspired): если usersKey установлен,
// JSON MarshalIndent → AES-256-GCM encrypt → write to disk. На диске
// файл выглядит как бинарный blob с magic prefix "ENC1" — без ключа
// утечка users.json не даёт ничего полезного.
func (m *UserManager) Persist() error {
        if m.path == "" {
                return nil
        }
        return m.persistLocked()
}

// persistLocked — actual persist logic. Called from Persist() (with mu
// already held via RLock) and from load() migration path.
func (m *UserManager) persistLocked() error {
        m.mu.RLock()
        doc := struct {
                Users []*User `json:"users"`
        }{Users: m.order}
        usersKey := m.usersKey
        usersKeySet := m.usersKeySet
        m.mu.RUnlock()

        data, err := json.MarshalIndent(&doc, "", "  ")
        if err != nil {
                return err
        }
        // Encrypt if key is set. Plain JSON otherwise (legacy / test mode).
        if usersKeySet {
                data, err = encryptBytes(usersKey, data)
                if err != nil {
                        return fmt.Errorf("users: encrypt: %w", err)
                }
        }
        tmp := m.path + ".tmp"
        if err := os.WriteFile(tmp, data, 0o600); err != nil {
                return fmt.Errorf("users: %w", err)
        }
        if err := os.Rename(tmp, m.path); err != nil {
                return fmt.Errorf("users: %w", err)
        }
        return nil
}

// GenerateUUID — случайный UUID v4 (канонический формат с дефисами).
func GenerateUUID() string {
        var b [16]byte
        if _, err := rand.Read(b[:]); err != nil {
                return "00000000-0000-4000-8000-000000000000"
        }
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        h := hex.EncodeToString(b[:])
        return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// Add — новый клиент; uuid="" → генерация. Возвращает созданную запись.
func (m *UserManager) Add(email, uuidStr string, level int, expiry, quota int64) (*User, error) {
        email = strings.TrimSpace(strings.ToLower(email))
        if email == "" {
                return nil, errors.New("users: email обязателен")
        }
        if strings.ContainsAny(email, " \t\r\n") {
                return nil, errors.New("users: email содержит пробельные символы")
        }
        if uuidStr == "" {
                uuidStr = GenerateUUID()
        }
        id, err := ParseUUID(uuidStr)
        if err != nil {
                return nil, fmt.Errorf("users: %w", err)
        }
        uuidStr = canonicalUUID(uuidStr)

        m.mu.Lock()
        if m.byEmail[email] != nil {
                m.mu.Unlock()
                return nil, fmt.Errorf("users: клиент %q уже существует", email)
        }
        if m.byUUID[hex.EncodeToString(id[:])] != nil {
                m.mu.Unlock()
                return nil, fmt.Errorf("users: uuid %s уже занят", uuidStr)
        }
        if expiry < 0 || quota < 0 {
                m.mu.Unlock()
                return nil, errors.New("users: expiryUnix и quotaBytes не могут быть отрицательными")
        }
        u := &User{
                Email:      email,
                UUID:       uuidStr,
                Level:      level,
                ExpiryUnix: expiry,
                QuotaBytes: quota,
                AddedAt:    time.Now().Unix(),
        }
        u.uuidB = id
        m.insertLocked(u)
        m.mu.Unlock()

        // персистентность вне mu (Persist берет RLock)
        if err := m.Persist(); err != nil {
                m.mu.Lock()
                m.removeLocked(email)
                m.mu.Unlock()
                return nil, err
        }
        m.logger.Info("client added", "email", email, "uuid", uuidStr, "level", level)
        // Notify onAdd hook (Server uses for plugin.HookOnUserAdd dispatch).
        if m.onAdd != nil {
                m.onAdd(email, uuidStr)
        }
        return u, nil
}

// Remove — удаление клиента.
func (m *UserManager) Remove(email string) error {
        email = strings.TrimSpace(strings.ToLower(email))
        m.mu.Lock()
        removed := m.removeLocked(email)
        m.mu.Unlock()
        if !removed {
                return fmt.Errorf("users: клиент %q не найден", email)
        }
        if err := m.Persist(); err != nil {
                return err
        }
        // Notify hook (Server cleans userSessionCount/userChunkCount/userBulkCount
        // sync.Map entries) — без этого sync.Map растёт без границ при churn'е
        // клиентов (admin API users/remove — частая операция). См. audit C3.
        if m.onRemove != nil {
                m.onRemove(email)
        }
        m.logger.Info("client removed", "email", email)
        return nil
}

// SetOnRemove — регистрирует callback, вызываемый при Remove(email).
// Используется Server для cleanup'а per-user счётчиков (sync.Map entries).
func (m *UserManager) SetOnRemove(fn func(email string)) {
        m.mu.Lock()
        m.onRemove = fn
        m.mu.Unlock()
}

// SetOnAdd — регистрирует callback при Add(email, uuid).
// Используется Server для plugin.HookOnUserAdd dispatch.
func (m *UserManager) SetOnAdd(fn func(email, uuid string)) {
        m.mu.Lock()
        m.onAdd = fn
        m.mu.Unlock()
}

// removeLocked — удаление под mu; true — было что удалять.
// Also removes from byExternalID if user has external_id set.
func (m *UserManager) removeLocked(email string) bool {
        u := m.byEmail[email]
        if u == nil {
                return false
        }
        delete(m.byEmail, email)
        delete(m.byUUID, hex.EncodeToString(u.uuidB[:]))
        if u.ExternalID != "" {
                delete(m.byExternalID, u.ExternalID)
        }
        for i, x := range m.order {
                if x == u {
                        m.order = append(m.order[:i], m.order[i+1:]...)
                        break
                }
        }
        return true
}

// Update — изменение полей (nil = не трогать).
func (m *UserManager) Update(email string, level *int, expiry *int64, quota *int64, disabled *bool) (*User, error) {
        email = strings.TrimSpace(strings.ToLower(email))
        m.mu.Lock()
        u := m.byEmail[email]
        if u == nil {
                m.mu.Unlock()
                return nil, fmt.Errorf("users: клиент %q не найден", email)
        }
        if level != nil {
                u.Level = *level
        }
        if expiry != nil {
                if *expiry < 0 {
                        m.mu.Unlock()
                        return nil, errors.New("users: expiryUnix не может быть отрицательным")
                }
                u.ExpiryUnix = *expiry
        }
        if quota != nil {
                if *quota < 0 {
                        m.mu.Unlock()
                        return nil, errors.New("users: quotaBytes не может быть отрицательным")
                }
                u.QuotaBytes = *quota
        }
        if disabled != nil {
                u.Disabled = *disabled
        }
        m.mu.Unlock()

        if err := m.Persist(); err != nil {
                return nil, err
        }
        m.logger.Info("client updated", "email", email)
        return u, nil
}

// Lookup — find user by external_id (primary) or email (fallback).
// Marvia-style: external_id is the primary identifier when set.
func (m *UserManager) Lookup(id string) *User {
        id = strings.TrimSpace(id)
        m.mu.RLock()
        defer m.mu.RUnlock()
        // Check byExternalID first (case-sensitive, opaque ID).
        if u, ok := m.byExternalID[id]; ok {
                return u
        }
        // Fall back to email (case-insensitive).
        return m.byEmail[strings.ToLower(id)]
}

// LookupExternalID — find user by external_id.
func (m *UserManager) LookupExternalID(externalID string) *User {
        m.mu.RLock()
        defer m.mu.RUnlock()
        return m.byExternalID[strings.TrimSpace(externalID)]
}

// SetExternalID — set external_id for a user (identified by email).
// Adds to byExternalID map for lookup. Removes old external_id from
// map if user had a different one before.
func (m *UserManager) SetExternalID(email, externalID string) error {
        email = strings.TrimSpace(strings.ToLower(email))
        externalID = strings.TrimSpace(externalID)
        m.mu.Lock()
        defer m.mu.Unlock()
        u := m.byEmail[email]
        if u == nil {
                return fmt.Errorf("users: SetExternalID: user not found: %s", email)
        }
        // Remove old external_id from map if set.
        if u.ExternalID != "" && u.ExternalID != externalID {
                delete(m.byExternalID, u.ExternalID)
        }
        u.ExternalID = externalID
        if externalID != "" {
                m.byExternalID[externalID] = u
        }
        m.trafficDirty.Store(true)
        return nil
}

// UpdateResources — update per-client resource limits (nil = unchanged).
func (m *UserManager) UpdateResources(email string, maxSess, maxChunks, cpuWeight, maxCpu *int, rateUp, rateDown *int64, maxDevices *int, singleDeviceMode *bool) {
        email = strings.TrimSpace(strings.ToLower(email))
        m.mu.Lock()
        u := m.byEmail[email]
        if u == nil {
                m.mu.Unlock()
                return
        }
        if maxSess != nil {
                u.MaxConcurrentSessions = *maxSess
        }
        if maxChunks != nil {
                u.MaxConcurrentChunks = *maxChunks
        }
        if cpuWeight != nil {
                u.CpuWeight = *cpuWeight
        }
        if maxCpu != nil {
                u.MaxCpuPercent = *maxCpu
        }
        if rateUp != nil {
                u.MaxRateUp = *rateUp
        }
        if rateDown != nil {
                u.MaxRateDown = *rateDown
        }
        if maxDevices != nil {
                u.MaxDevices = *maxDevices
        }
        if singleDeviceMode != nil {
                u.SingleDeviceMode = *singleDeviceMode
        }
        m.mu.Unlock()
        _ = m.Persist()
}

// SetTrafficStore — файл накопительного трафика (dataDir/traffic.json);
// вызывается до LoadSeeds, чтобы стартовые байты поднялись с диска.
func (m *UserManager) SetTrafficStore(path string) { m.trafficPath = path }

// loadTraffic — подъем накопительных байтов из traffic.json.
func (m *UserManager) loadTraffic() {
        if m.trafficPath == "" {
                return
        }
        data, err := os.ReadFile(m.trafficPath)
        if err != nil {
                return // первый запуск — файла еще нет
        }
        var doc map[string]trafficRec
        if err := json.Unmarshal(data, &doc); err != nil {
                m.logger.Warn("users: некорректный traffic.json, счетчики обнулены", "err", err.Error())
                return
        }
        m.mu.RLock()
        defer m.mu.RUnlock()
        loaded := 0
        for _, u := range m.order {
                if rec, ok := doc[u.Email]; ok {
                        if rec.Up > 0 {
                                u.upBytes.Add(rec.Up)
                        }
                        if rec.Down > 0 {
                                u.downBytes.Add(rec.Down)
                        }
                        loaded++
                }
        }
        if loaded > 0 {
                m.logger.Info("users: накопительный трафик поднят", "path", m.trafficPath, "clients", loaded)
        }
}

// trafficRec — запись файла накоплений одного клиента.
type trafficRec struct {
        Up   int64 `json:"up"`
        Down int64 `json:"down"`
}

// FlushTraffic — атомарная запись накопительного трафика (вызывается
// периодически панелью и при graceful-остановке). true — была запись.
func (m *UserManager) FlushTraffic() bool {
        if m.trafficPath == "" || !m.trafficDirty.Swap(false) {
                return false
        }
        m.mu.RLock()
        doc := make(map[string]trafficRec, len(m.order))
        for _, u := range m.order {
                doc[u.Email] = trafficRec{Up: u.upBytes.Load(), Down: u.downBytes.Load()}
        }
        m.mu.RUnlock()
        data, err := json.MarshalIndent(doc, "", "  ")
        if err != nil {
                m.trafficDirty.Store(true)
                return false
        }
        tmp := m.trafficPath + ".tmp"
        if err := os.WriteFile(tmp, data, 0o600); err != nil {
                m.trafficDirty.Store(true)
                m.logger.Warn("users: не записан traffic.json", "err", err.Error())
                return false
        }
        if err := os.Rename(tmp, m.trafficPath); err != nil {
                m.trafficDirty.Store(true)
                return false
        }
        return true
}

// List — снимок реестра, отсортированный по email.
func (m *UserManager) List() []UserInfo {
        m.mu.RLock()
        defer m.mu.RUnlock()
        out := make([]UserInfo, 0, len(m.order))
        for _, u := range m.order {
                out = append(out, u.Info())
        }
        sort.Slice(out, func(i, j int) bool { return out[i].Email < out[j].Email })
        return out
}

// Snapshot — живые указатели (для итерации HMAC-аутентификации).
// Возвращенные записи валидны без мьютекса: поля фиксированы после Add,
// мутируют только атомарные счетчики и Update (уровень/квота — не
// критичны для гонки чтения).
//
// NOTE (audit F6/F36): allocates []*User slice + copy per call. Hot path
// is verifyAuthUser (called on every probe — 1000/s under probe-storm).
// For 50 users → 50K allocs/s + 1000 RLock ops. Prefer Iter() below
// for hot-path callers (no alloc, no slice copy).
func (m *UserManager) Snapshot() []*User {
        m.mu.RLock()
        defer m.mu.RUnlock()
        out := make([]*User, len(m.order))
        copy(out, m.order)
        return out
}

// Iter — iterate users under RLock WITHOUT allocating a slice.
// Caller's f callback is invoked for each user; if f returns false,
// iteration stops. Caller MUST NOT mutate UserManager inside f
// (RLock held — would deadlock on Lock).
//
// Hot path: verifyAuthUser uses this to scan for HMAC match on every
// probe. Was: Snapshot() allocated []*User + copy per call.
// With 1000 probes/s × 50 users = 50K allocs/s eliminated.
func (m *UserManager) Iter(f func(*User) bool) {
        m.mu.RLock()
        defer m.mu.RUnlock()
        for _, u := range m.order {
                if !f(u) {
                        return
                }
        }
}

// LookupUUIDBytes — поиск по бинарному UUID (VLESS-сверка).
func (m *UserManager) LookupUUIDBytes(id [16]byte) *User {
        key := hex.EncodeToString(id[:])
        m.mu.RLock()
        defer m.mu.RUnlock()
        return m.byUUID[key]
}

// LookupEmail — поиск по email.
func (m *UserManager) LookupEmail(email string) *User {
        email = strings.TrimSpace(strings.ToLower(email))
        m.mu.RLock()
        defer m.mu.RUnlock()
        return m.byEmail[email]
}

// Count — количество клиентов.
func (m *UserManager) Count() int {
        m.mu.RLock()
        defer m.mu.RUnlock()
        return len(m.order)
}

// AddTraffic — учет трафика завершенной сессии (uuid в любом формате).
// Байты попадают в накопительные счетчики (квоты) и помечаются к
// сохранению в traffic.json; живые сессии учитываются отдельно
// (Server.userLiveSplit), поэтому «Использовано» в панели видно сразу.
func (m *UserManager) AddTraffic(uuidStr string, up, down int64) {
        key := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(uuidStr)), "-", "")
        m.mu.RLock()
        u := m.byUUID[key]
        m.mu.RUnlock()
        if u == nil || (up == 0 && down == 0) {
                return
        }
        u.upBytes.Add(up)
        u.downBytes.Add(down)
        m.trafficDirty.Store(true)
}

// UUIDBytes — бинарный UUID (ключ HMAC, сверка VLESS).
func (u *User) UUIDBytes() [16]byte { return u.uuidB }

// UsedBytes — завершенный трафик клиента (payload, оба плеча).
func (u *User) UsedBytes() int64 { return u.upBytes.Load() + u.downBytes.Load() }

// UpBytes / DownBytes — по направлениям.
func (u *User) UpBytes() int64   { return u.upBytes.Load() }
func (u *User) DownBytes() int64 { return u.downBytes.Load() }

// Active — допущен ли клиент: не отключен, не истек, не превысил квоту
// (used — накопленный + live-байты активных сессий).
func (u *User) Active(now time.Time, liveBytes int64) bool {
        if u.Disabled {
                return false
        }
        if u.ExpiryUnix > 0 && now.Unix() >= u.ExpiryUnix {
                return false
        }
        if u.QuotaBytes > 0 && u.UsedBytes()+liveBytes >= u.QuotaBytes {
                return false
        }
        return true
}

// Info — DTO-копия.
func (u *User) Info() UserInfo {
        return UserInfo{
                Email:                 u.Email,
                ExternalID:            u.ExternalID,
                UUID:                  u.UUID,
                Level:                 u.Level,
                ExpiryUnix:            u.ExpiryUnix,
                QuotaBytes:            u.QuotaBytes,
                Disabled:              u.Disabled,
                AddedAt:               u.AddedAt,
                UsedBytes:             u.UsedBytes(),
                MaxConcurrentSessions: u.MaxConcurrentSessions,
                MaxConcurrentChunks:   u.MaxConcurrentChunks,
                CpuWeight:             u.CpuWeight,
                MaxCpuPercent:         u.MaxCpuPercent,
                MaxRateUp:             u.MaxRateUp,
                MaxRateDown:           u.MaxRateDown,
                IsPeer:                u.IsPeer,
                MaxDevices:            u.MaxDevices,
                SingleDeviceMode:      u.SingleDeviceMode,
                UpBytes:               u.upBytes.Load(),
                DownBytes:             u.downBytes.Load(),
        }
}

// canonicalUUID — нижний регистр с дефисами.
func canonicalUUID(s string) string {
        clean := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), "-", "")
        if len(clean) != 32 {
                return s
        }
        return clean[0:8] + "-" + clean[8:12] + "-" + clean[12:16] + "-" + clean[16:20] + "-" + clean[20:32]
}

// constTimeStringEqual — сравнение строк за постоянное время.
func constTimeStringEqual(a, b string) bool {
        if len(a) != len(b) {
                return false
        }
        var diff byte
        for i := 0; i < len(a); i++ {
                diff |= a[i] ^ b[i]
        }
        return diff == 0
}
