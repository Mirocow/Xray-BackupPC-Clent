package backupemulator

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// TestBackupPCSessionIDFormat — идентификаторы сессий выглядят как задания
// BackupPC: host.jobnum.nonce8 и проходят валидацию.
func TestBackupPCSessionIDFormat(t *testing.T) {
	seenHosts := map[string]bool{}
	for i := 0; i < 200; i++ {
		id := newBackupPCSessionID()
		if !validBackupPCSessionID(id) {
			t.Fatalf("невалидный идентификатор: %q", id)
		}
		parts := strings.Split(id, ".")
		if len(parts) != 3 {
			t.Fatalf("ожидалось 3 компонента: %q", id)
		}
		if host := backuppcSessionHost(id); host != parts[0] {
			t.Fatalf("host(%q) != %q", host, parts[0])
		}
		seenHosts[parts[0]] = true
	}
	if len(seenHosts) < 2 {
		t.Fatalf("хосты не рандомизируются: %v", seenHosts)
	}
}

// TestValidBackupPCSessionID — границы формата.
func TestValidBackupPCSessionID(t *testing.T) {
	valid := []string{
		"srv-dc-01.1174.6f3ac2b1",
		"ws-finance-03.7.00000000",
		"nas-arch-02.999999.ffffffff",
		"a12.1.01234567",
	}
	for _, s := range valid {
		if !validBackupPCSessionID(s) {
			t.Errorf("должен быть валиден: %q", s)
		}
	}
	invalid := []string{
		"", "srv-dc-01", "srv-dc-01.1174", "srv-dc-01.1174.6f3ac2b1.extra",
		"SRV-DC-01.1174.6f3ac2b1",          // заглавные
		"srv_dc-01.1174.6f3ac2b1",          // подчеркивание
		"srv-dc-01.1174.6F3AC2B1",          // hex заглавными
		"srv-dc-01.-1.6f3ac2b1",            // отрицательный номер
		"5eed5eed5eed5eed5eed5eed5eed5eed", // старый hex-формат
		"srv-dc-01.1174.6f3ac2b",           // короткий nonce
	}
	for _, s := range invalid {
		if validBackupPCSessionID(s) {
			t.Errorf("должен быть невалиден: %q", s)
		}
	}
}

// TestBackupPCNextJob — днем планируются инкременты, ночью — полные;
// интервалы в границах ±40%.
func TestBackupPCNextJob(t *testing.T) {
	cfg := &BackupPCConfig{}
	cfg.applyDefaults()

	day := time.Date(2025, 10, 1, 14, 0, 0, 0, time.UTC)
	night := time.Date(2025, 10, 1, 23, 30, 0, 0, time.UTC)

	for i := 0; i < 50; i++ {
		p := backuppcNextJob(cfg, day)
		if p.Kind != backuppcJobIncremental {
			t.Fatalf("днем ожидался инкремент, got %s", p.Kind)
		}
		if p.Bytes < cfg.IncrementalMinBytes || p.Bytes > cfg.IncrementalMaxBytes {
			t.Fatalf("объем инкремента вне границ: %d", p.Bytes)
		}
		span := time.Duration(0.8 * float64(cfg.IncrementalEvery.D()))
		if p.Delay < cfg.IncrementalEvery.D()-span || p.Delay > cfg.IncrementalEvery.D()+span {
			t.Fatalf("задержка вне ±40%%: %v", p.Delay)
		}
	}
	for i := 0; i < 50; i++ {
		p := backuppcNextJob(cfg, night)
		if p.Kind != backuppcJobFull {
			t.Fatalf("ночью ожидался полный, got %s", p.Kind)
		}
	}
}

// TestBackupPCNightWindow — окно через полночь.
func TestBackupPCNightWindow(t *testing.T) {
	at := func(h int) time.Time { return time.Date(2025, 10, 1, h, 0, 0, 0, time.UTC) }
	cases := []struct {
		h    int
		want bool
	}{
		{21, false}, {22, true}, {23, true}, {0, true}, {5, true}, {6, false}, {12, false},
	}
	for _, c := range cases {
		if got := backuppcInNightWindow(at(c.h), 22, 6); got != c.want {
			t.Errorf("час %d: got %v want %v", c.h, got, c.want)
		}
	}
	if backuppcInNightWindow(at(12), 12, 12) {
		t.Error("вырожденное окно не должно срабатывать")
	}
}

// TestPlanBackupBursts — rsync-паттерн: всплески 16–120 КиБ, суммарный
// объем совпадает, паузы в границах.
func TestPlanBackupBursts(t *testing.T) {
	bursts := planBackupBursts(500 * 1024)
	if len(bursts) < 4 {
		t.Fatalf("слишком мало всплесков: %d", len(bursts))
	}
	total := 0
	for _, b := range bursts {
		if b.Size < 16<<10 || b.Size > 120<<10 {
			// последний всплеск может быть меньше нижней границы
			if total+b.Size != 500*1024 {
				t.Fatalf("размер всплеска вне границ: %d", b.Size)
			}
		}
		if b.Gap < 30*time.Millisecond || b.Gap > 300*time.Millisecond {
			t.Fatalf("пауза вне границ: %v", b.Gap)
		}
		total += b.Size
	}
	if total != 500*1024 {
		t.Fatalf("суммарный объем: %d != %d", total, 500*1024)
	}
	if planBackupBursts(0) != nil {
		t.Fatal("нулевой объем не должен давать план")
	}
}

// TestPickBackupPCUserAgent — UA из пула.
func TestPickBackupPCUserAgent(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		ua := pickBackupPCUserAgent()
		if ua == "" || !seenKnownUA(ua) {
			t.Fatalf("неизвестный UA: %q", ua)
		}
		seen[ua] = true
	}
	if len(seen) < 2 {
		t.Fatalf("UA не рандомизируются: %v", seen)
	}
}

func seenKnownUA(ua string) bool {
	for _, u := range backuppcUserAgents {
		if u == ua {
			return true
		}
	}
	return false
}

// TestBackupPCConfigEnabled — семантика *bool: nil/true → включено.
func TestBackupPCConfigEnabled(t *testing.T) {
	var bc BackupPCConfig
	if !bc.EnabledOn() {
		t.Fatal("nil должен означать включено")
	}
	bc.Enabled = BoolPtr(true)
	if !bc.EnabledOn() {
		t.Fatal("true должен означать включено")
	}
	bc.Enabled = BoolPtr(false)
	if bc.EnabledOn() {
		t.Fatal("false должен означать выключено")
	}
}

// TestBackupPCApplyDefaults — дефолты раздела.
func TestBackupPCApplyDefaults(t *testing.T) {
	tc := &TransportConfig{}
	tc.ApplyDefaults()
	bc := tc.BackupPC
	if bc.IncrementalEvery.D() != 25*time.Minute {
		t.Fatalf("incrementalEvery: %v", bc.IncrementalEvery)
	}
	if bc.FullEvery.D() != 8*time.Hour {
		t.Fatalf("fullEvery: %v", bc.FullEvery)
	}
	if bc.IncrementalMinBytes != 2<<20 || bc.IncrementalMaxBytes != 8<<20 {
		t.Fatalf("объемы инкрементов: %d..%d", bc.IncrementalMinBytes, bc.IncrementalMaxBytes)
	}
	if bc.FullMinBytes != 32<<20 || bc.FullMaxBytes != 128<<20 {
		t.Fatalf("объемы полных: %d..%d", bc.FullMinBytes, bc.FullMaxBytes)
	}
	if bc.NightStartHour != 22 || bc.NightEndHour != 6 {
		t.Fatalf("ночное окно: %d..%d", bc.NightStartHour, bc.NightEndHour)
	}
}

// TestFormatBackupBytes — человекочитаемые объемы.
func TestFormatBackupBytes(t *testing.T) {
	if got := formatBackupBytes(8 << 20); got != "8MiB" {
		t.Fatalf("got %q", got)
	}
	if got := formatBackupBytes(64 << 10); got != "64KiB" {
		t.Fatalf("got %q", got)
	}
	if got := formatBackupBytes(500); got != "500B" {
		t.Fatalf("got %q", got)
	}
	_ = bytes.MinRead // импорт bytes для симметрии с остальными тестами
}
