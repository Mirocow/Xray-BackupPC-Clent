package backupemulator

// Эмуляция трафика BackupPC: сессии маскируются под поток периодических
// заданий резервного копирования (BackupPC-стиль):
//
//   - идентификатор сессии — «задание» BackupPC: "ws-finance-03.1174.6f3a2b1"
//     (хост из корпоративного пула . номер бэкапа . nonce);
//   - User-Agent — пул агентов резервного копирования (rsync/BackupPC);
//   - планировщик заданий: инкрементные «бэкапы» в течение дня,
//     полные — в ночном окне (по умолчанию 22:00–06:00), в простое сессии;
//   - каждый псевдо-бэкап — последовательность всплесков 16–120 КБ
//     с паузами 30–300 мс (rsync-паттерн передачи файлов), мусор уходит
//     padding-only кадрами (прозрачен для VLESS-логики, ТЗ 3.2/4.2).
//
// Периодичность синхронизирована с ротацией чанков (ТЗ 3.4): жизненный
// цикл сессии [0.5..1.5]×MaxSessionDuration статистически неотличим от
// длительности инкрементного задания BackupPC.

import (
	"crypto/rand"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Пул «хостов», якобы бэкапящихся на узел хранения (стиль BackupPC:
// рабочие станции, файловые и прочие серверы).
var backuppcHosts = []string{
	"srv-dc-01", "srv-dc-02", "srv-fs-01", "srv-fs-02", "srv-mail-01",
	"srv-db-01", "srv-web-03", "srv-app-05", "srv-backup-01", "nas-arch-01",
	"nas-arch-02", "ws-finance-03", "ws-finance-07", "ws-hr-12",
	"ws-dev-05", "ws-dev-11", "ws-sales-09", "ws-mgmt-02", "ws-qa-06",
	"ws-support-04",
}

// Пул User-Agent агентов резервного копирования.
var backuppcUserAgents = []string{
	"BackupPC-Agent/4.2.1 (rsync 3.2.7; linux x86_64)",
	"BackupPC-Transfer/3.3.2 (rsync 3.1.3; linux)",
	"backup-worker/2.7 (Storage::Chunk; perl 5.36)",
	"rsync-backup-client/3.2.7 (linux x86_64)",
}

// backuppcSessionRe — формат идентификатора «задания»: host.jobnum.nonce8.
var backuppcSessionRe = regexp.MustCompile(
	`^[a-z0-9][a-z0-9-]{2,31}\.[0-9]{1,6}\.[0-9a-f]{8}$`)

// BackupPCConfig — настройки эмуляции периодических бекапов (ТЗ, раздел 4).
type BackupPCConfig struct {
	// Enabled — включить генерацию псевдо-заданий (nil или true — включено
	// по умолчанию, false — отключено).
	Enabled *bool `json:"enabled"`
	// IdleOnly — генерировать псевдо-бэкапы только при простое сессии
	// (нет пользовательского трафика ≥ 10 c), чтобы не раздувать объем
	// при активном использовании (по умолчанию true).
	IdleOnly bool `json:"idleOnly"`
	// IncrementalEvery — целевой интервал инкрементных «бэкапов»
	// (±40% джиттера), дефолт 25m.
	IncrementalEvery Duration `json:"incrementalEvery"`
	// IncrementalMinBytes / IncrementalMaxBytes — объем инкрементного
	// «бэкапа», дефолты 2..8 МиБ.
	IncrementalMinBytes int `json:"incrementalMinBytes"`
	IncrementalMaxBytes int `json:"incrementalMaxBytes"`
	// FullEvery — целевой интервал полных «бэкапов», дефолт 8h.
	FullEvery Duration `json:"fullEvery"`
	// FullMinBytes / FullMaxBytes — объем полного «бэкапа»,
	// дефолты 32..128 МиБ.
	FullMinBytes int `json:"fullMinBytes"`
	FullMaxBytes int `json:"fullMaxBytes"`
	// NightStartHour / NightEndHour — ночное окно полных бэкапов
	// (BackupPC blackout), дефолт 22:00–06:00.
	NightStartHour int `json:"nightStartHour"`
	NightEndHour   int `json:"nightEndHour"`
}

// applyBackupPCDefaults — значения по умолчанию.
func (bc *BackupPCConfig) applyDefaults() {
	if bc.IncrementalEvery.D() == 0 {
		bc.IncrementalEvery = Dur(25 * time.Minute)
	}
	if bc.IncrementalMinBytes == 0 {
		bc.IncrementalMinBytes = 2 << 20
	}
	if bc.IncrementalMaxBytes == 0 {
		bc.IncrementalMaxBytes = 8 << 20
	}
	if bc.FullEvery.D() == 0 {
		bc.FullEvery = Dur(8 * time.Hour)
	}
	if bc.FullMinBytes == 0 {
		bc.FullMinBytes = 32 << 20
	}
	if bc.FullMaxBytes == 0 {
		bc.FullMaxBytes = 128 << 20
	}
	if bc.NightStartHour == 0 && bc.NightEndHour == 0 {
		bc.NightStartHour, bc.NightEndHour = 22, 6
	}
}

// EnabledOn — эмуляция включена (nil → включено по умолчанию).
func (bc *BackupPCConfig) EnabledOn() bool {
	return bc.Enabled == nil || *bc.Enabled
}

// BoolPtr — хелпер для конфигураций в тестах и примерах.
func BoolPtr(v bool) *bool { return &v }

// validBackupPCSessionID — идентификатор выглядит как задание BackupPC.
func validBackupPCSessionID(s string) bool {
	return backuppcSessionRe.MatchString(s)
}

// newBackupPCSessionID — идентификатор «задания» BackupPC:
// "ws-finance-03.1174.6f3a2b1" (хост.номерБэкапа.nonce).
func newBackupPCSessionID() string {
	host := backuppcHosts[randIntOr(0, len(backuppcHosts)-1, 0)]
	job := 100 + randIntOr(0, 9900, 0)
	var nonce [4]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		// детерминированный fallback (практически недостижимо)
		n := time.Now().UnixNano()
		nonce[0], nonce[1], nonce[2], nonce[3] = byte(n), byte(n>>8), byte(n>>16), byte(n>>24)
	}
	return fmt.Sprintf("%s.%d.%x", host, job, nonce)
}

// pickBackupPCUserAgent — случайный User-Agent из пула агентов бэкапа.
func pickBackupPCUserAgent() string {
	return backuppcUserAgents[randIntOr(0, len(backuppcUserAgents)-1, 0)]
}

// backuppcJobKind — вид псевдо-задания.
type backuppcJobKind int

const (
	backuppcJobIncremental backuppcJobKind = iota
	backuppcJobFull
)

func (k backuppcJobKind) String() string {
	if k == backuppcJobFull {
		return "full"
	}
	return "incr"
}

// backuppcJobPlan — план следующего псевдо-задания.
type backuppcJobPlan struct {
	Kind  backuppcJobKind
	Bytes int
	Delay time.Duration // пауза до запуска (джиттер ±40% от целевого интервала)
}

// backuppcNextJob — расписание следующего задания: ночью полные «бэкапы»
// по FullEvery, иначе инкрементные по IncrementalEvery; интервал и объем
// рандомизированы (±40% и [min..max] соответственно).
func backuppcNextJob(cfg *BackupPCConfig, now time.Time) backuppcJobPlan {
	night := backuppcInNightWindow(now, cfg.NightStartHour, cfg.NightEndHour)
	if night && cfg.FullEvery.D() > 0 {
		return backuppcJobPlan{
			Kind:  backuppcJobFull,
			Bytes: randIntOr(cfg.FullMinBytes, cfg.FullMaxBytes, cfg.FullMinBytes),
			Delay: jitterFraction(cfg.FullEvery.D(), 0.4),
		}
	}
	base := cfg.IncrementalEvery.D()
	return backuppcJobPlan{
		Kind:  backuppcJobIncremental,
		Bytes: randIntOr(cfg.IncrementalMinBytes, cfg.IncrementalMaxBytes, cfg.IncrementalMinBytes),
		Delay: jitterFraction(base, 0.4),
	}
}

// backuppcInNightWindow — попадание момента времени в ночное окно
// (окно может переходить через полночь: 22:00–06:00).
func backuppcInNightWindow(now time.Time, start, end int) bool {
	h := now.Hour()
	if start == end {
		return false
	}
	if start < end {
		return h >= start && h < end
	}
	return h >= start || h < end // через полночь
}

// jitterFraction — случайное отклонение от базовой длительности:
// base ± fraction*base.
func jitterFraction(base time.Duration, fraction float64) time.Duration {
	if base <= 0 {
		return 0
	}
	span := time.Duration(float64(base) * fraction)
	return base + randDurationRange(-span, span)
}

// backupBurst — один всплеск «передачи файлов» внутри псевдо-бэкапа.
type backupBurst struct {
	Size int           // мусорные байты всплеска
	Gap  time.Duration // пауза до следующего всплеска
}

// planBackupBursts — раскладка total байт по всплескам 16–120 КиБ
// с паузами 30–300 мс: имитация последовательной передачи файлов
// (rsync: файл → скан → файл).
func planBackupBursts(total int) []backupBurst {
	if total <= 0 {
		return nil
	}
	var out []backupBurst
	for rem := total; rem > 0; {
		size := randIntOr(16<<10, 120<<10, 16<<10)
		if size > rem {
			size = rem
		}
		gap := randDurationRange(30*time.Millisecond, 300*time.Millisecond)
		out = append(out, backupBurst{Size: size, Gap: gap})
		rem -= size
	}
	return out
}

// backuppcSessionHost — имя «хоста» из идентификатора сессии (для логов).
func backuppcSessionHost(id string) string {
	if i := strings.IndexByte(id, '.'); i > 0 {
		return id[:i]
	}
	return id
}

// randIntOr — randIntRange с fallback-значением при ошибке crypto/rand.
func randIntOr(min, max, fallback int) int {
	v, err := randIntRange(min, max)
	if err != nil {
		return fallback
	}
	return v
}

// formatBackupBytes — человекочитаемый объем для логов.
func formatBackupBytes(n int) string {
	switch {
	case n >= 1<<20 && n%(1<<20) == 0:
		return strconv.Itoa(n>>20) + "MiB"
	case n >= 1<<10:
		return strconv.Itoa(n>>10) + "KiB"
	default:
		return strconv.Itoa(n) + "B"
	}
}
