package backupemulator

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"
)

// BalanceDecision — чистая функция решения балансировщика (ТЗ 4.2):
// если за окно скачивание идет (dRx > 0), а аплоад стоит (dTx < MinTxThreshold),
// генерируется фейковый аплоад объемом FakeUploadChunk — «бэкап логов сессии».
func BalanceDecision(dTx, dRx int64, cfg *TransportConfig) int {
	if cfg == nil || cfg.FakeUploadChunk <= 0 {
		return 0
	}
	if dRx > 0 && dTx < cfg.MinTxThreshold {
		return cfg.FakeUploadChunk
	}
	return 0
}

// jitterInterval — плавающий интервал пинга (ТЗ 4.1): Base ± Random.
// Возвращает полную длительность до следующего пинга.
func jitterInterval(cfg *TransportConfig) time.Duration {
	base := cfg.PingBaseInterval.D()
	jmax := cfg.PingJitterMax.D()
	if jmax <= 0 {
		return base
	}
	delta := randDurationRange(-jmax, jmax)
	v := base + delta
	if v < 0 {
		v = 0
	}
	return v
}

// pingPaddingSize — размер мусорного хвоста пинга: пустой чанк бэкапа
// (кадр с payload=0 и небольшим паддингом).
func pingPaddingSize() int {
	n, err := randIntRange(16, 64)
	if err != nil {
		return 32
	}
	return n
}

// spawnTrafficBalancing — фоновый поток выравнивания плеч (ТЗ 4.2):
// горутина мониторит счетчики tx/rx логической сессии и при асимметрии
// (скачивание без аплоада) асинхронно вливает на сервер зашифрованный
// мусор, маскируемый под инкрементальные логи бэкапа.
func (lc *LogicalConn) spawnTrafficBalancer() {
	if lc.cfg.BalancingInterval.D() <= 0 || lc.cfg.FakeUploadChunk <= 0 {
		return
	}
	lc.wg.Add(1)
	go func() {
		defer lc.wg.Done()
		ticker := time.NewTicker(lc.cfg.BalancingInterval.D())
		defer ticker.Stop()

		var lastTx, lastRx int64
		for {
			select {
			case <-lc.ctx.Done():
				return
			case <-ticker.C:
				tx := atomic.LoadInt64(&lc.txPayload)
				rx := atomic.LoadInt64(&lc.rxPayload)
				dTx, dRx := tx-lastTx, rx-lastRx
				lastTx, lastRx = tx, rx

				if n := BalanceDecision(dTx, dRx, lc.cfg); n > 0 {
					w, err := lc.WritePadding(n)
					if err != nil {
						return // сокет закрыт — тушим горутину
					}
					lc.logger.Log(context.Background(), slog.LevelDebug, "fake upload injected",
						"session", lc.shortID(), "bytes", w,
						"window_tx", dTx, "window_rx", dRx)
				}
			}
		}
	}()
}
