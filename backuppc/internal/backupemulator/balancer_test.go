package backupemulator

import (
	"strings"
	"testing"
	"time"
)

// TestBalanceDecision — логика окна балансировщика (ТЗ 4.2):
// rx растет, tx ниже порога → инжект FakeUploadChunk.
func TestBalanceDecision(t *testing.T) {
	cfg := testCfg() // MinTxThreshold=16384, FakeUploadChunk=64KiB

	if got := BalanceDecision(0, 1<<20, cfg); got != cfg.FakeUploadChunk {
		t.Fatalf("скачивание без аплоада: инжект %d, want %d", got, cfg.FakeUploadChunk)
	}
	if got := BalanceDecision(cfg.MinTxThreshold+1, 1<<20, cfg); got != 0 {
		t.Fatalf("аплоад выше порога: инжект %d, want 0", got)
	}
	if got := BalanceDecision(0, 0, cfg); got != 0 {
		t.Fatalf("нет скачивания: инжект %d, want 0", got)
	}
	if got := BalanceDecision(100, 1<<20, &TransportConfig{}); got != 0 {
		t.Fatalf("балансировщик выключен: инжект %d, want 0", got)
	}
}

// TestJitterIntervalBounds — пинги всегда Base ± JitterMax (ТЗ 4.1).
func TestJitterIntervalBounds(t *testing.T) {
	cfg := &TransportConfig{
		PingBaseInterval: Dur(20 * time.Second),
		PingJitterMax:    Dur(15 * time.Second),
	}
	min := cfg.PingBaseInterval.D() - cfg.PingJitterMax.D()
	max := cfg.PingBaseInterval.D() + cfg.PingJitterMax.D()
	for i := 0; i < 2000; i++ {
		v := jitterInterval(cfg)
		if v < min || v > max {
			t.Fatalf("джиттер вне диапазона: %v ∉ [%v..%v]", v, min, max)
		}
	}
	// разброс должен реально присутствовать (не константа)
	seen := map[int64]bool{}
	for i := 0; i < 200; i++ {
		seen[jitterInterval(cfg).Nanoseconds()] = true
	}
	if len(seen) < 50 {
		t.Fatalf("джиттер вырожден: всего %d уникальных значений", len(seen))
	}
}

// TestRandomEndpoint — случайный gRPC-метод из endpointPaths (ТЗ 3.4).
func TestRandomEndpoint(t *testing.T) {
	cfg := testCfg()
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		p := cfg.randomEndpoint()
		seen[p] = true
		if !strings.HasPrefix(p, "/backuppc.") && p[0] != '/' {
			t.Fatalf("метод без слэша: %q", p)
		}
	}
	if len(seen) < 2 {
		t.Fatalf("методы не рандомизируются: %v", seen)
	}
}
