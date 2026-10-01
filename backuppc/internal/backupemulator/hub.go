package backupemulator

import (
        "context"
        "errors"
        "fmt"
        "io"
        "log/slog"
        "net"
        "sync"
        "sync/atomic"
        "time"
)

// ChunkDialer — фабрика физических чанков (HTTP/2-стримов).
// Реализация клиента — в client.go.
type ChunkDialer interface {
        // DialChunk устанавливает новый чанк логической сессии.
        // firstPayload непуст только для чанка 0 (VLESS-заголовок уходит
        // в тело запроса до RoundTrip, чтобы сервер отвечал 200 только
        // после валидного хендшейка).
        DialChunk(ctx context.Context, sessionID string, index uint32, firstPayload []byte) (*ChunkHandle, error)
}

// ChunkStream — io.ReadWriteCloser над плечами gRPC-вызова чанка:
// Write → gRPC-сообщения в тело запроса (upload),
// Read → gRPC-сообщения из тела ответа (download).
type ChunkStream struct {
        pw   *io.PipeWriter // END_STREAM при CloseWrite
        mw   *grpcMsgWriter // кадры ТЗ → gRPC-сообщения тела запроса
        mr   *grpcMsgReader // gRPC-сообщения тела ответа → кадры ТЗ
        body io.ReadCloser  // закрывается сервером (pump) при ротации/EOF
}

func (s *ChunkStream) Read(p []byte) (int, error) {
        if s.mr == nil {
                return 0, ErrClosed
        }
        return s.mr.Read(p)
}

func (s *ChunkStream) Write(p []byte) (int, error) {
        if s.mw == nil {
                return 0, ErrClosed
        }
        return s.mw.Write(p)
}

// CloseWrite — полузакрытие upload-плеча: END_STREAM (graceful).
func (s *ChunkStream) CloseWrite() error {
        if s.pw == nil {
                return nil
        }
        return s.pw.Close()
}

// CloseRead — закрытие download-плеча.
func (s *ChunkStream) CloseRead() error {
        if s.body == nil {
                return nil
        }
        return s.body.Close()
}

// Close закрывает оба плеча.
func (s *ChunkStream) Close() error {
        _ = s.CloseWrite()
        return s.CloseRead()
}

// ChunkHandle — физический чанк со своим TLS/HTTP/2-соединением
// (по ТЗ 3.4 каждое ротация = полностью новое рукопожатие).
type ChunkHandle struct {
        Stream    *ChunkStream
        Transport ChunkCloser
        Emu       *EmulatedConn
        index     uint32
        // next — звено цепочки ротаций: читатель переходит на него по EOF
        // (строго по порядку, без пропуска промежуточных ответов).
        next atomic.Pointer[ChunkHandle]
}

// ChunkCloser — освобождение транспорта чанка (http.Transport).
type ChunkCloser interface {
        CloseIdleConnections()
}

// switchingStream — поток за EmulatedConn логической сессии: запись
// уходит в активный чанк записи, чтение — из активного чанка чтения,
// с переходом на следующий чанк по EOF (graceful adoption). При EOF
// во время ротации — короткое ожидание преемника (эстафета).
type switchingStream struct {
        lc *LogicalConn
}

func (s *switchingStream) Write(p []byte) (int, error) {
        h := s.lc.writeCur // только под lc.wmu
        if h == nil {
                return 0, ErrClosed
        }
        return h.Stream.Write(p)
}

func (s *switchingStream) Read(p []byte) (int, error) {
        for {
                h := s.lc.readCur.Load()
                if h == nil {
                        return 0, io.EOF
                }
                n, err := h.Stream.Read(p)
                if err == io.EOF {
                        // ЦЕПОЧКА ротаций: строго следующий чанк (не последний) —
                        // так читатель не пропускает данные промежуточных ответов.
                        next := h.next.Load()
                        if next != nil {
                                if s.lc.readCur.CompareAndSwap(h, next) {
                                        s.lc.retireChunk(h)
                                }
                                continue // плавный переход на следующий чанк
                        }
                        // хвост цепи: возможно, идет ротация — ждем звена
                        if s.lc.waitForNextChunk(h, nextChunkWait) {
                                continue
                        }
                        return 0, io.EOF
                }
                return n, err
        }
}

func (s *switchingStream) Close() error { return nil }

// nextChunkWait — сколько читатель готов ждать преемника на EOF старого
// чанка (перекрывает RTT + TLS-рукопожатие новой цепочки).
const nextChunkWait = 2 * time.Second

// waitForNextChunk — EOF на хвосте цепи cur: true, если цепь продлилась
// (появилось следующее звено) в течение ротации.
func (lc *LogicalConn) waitForNextChunk(cur *ChunkHandle, d time.Duration) bool {
        deadline := time.NewTimer(d)
        defer deadline.Stop()
        for {
                lc.rotMu.Lock()
                ch := lc.nextCh
                active := lc.rotating
                lc.rotMu.Unlock()
                if cur.next.Load() != nil {
                        return true
                }
                if !active {
                        return false
                }
                select {
                case <-ch:
                        // ротация завершилась (успех или провал) — перепроверяем звено
                        return cur.next.Load() != nil
                case <-deadline.C:
                        return false
                }
        }
}

// LogicalStats — метрики логической сессии (агрегируются клиентом).
type LogicalStats struct {
        SessionID    string
        Chunks       int64
        Rotations    int64
        TxPayload    int64
        RxPayload    int64
        TxFake       int64 // фейковый аплоад балансировщика (байт мусора)
        TxPadding    int64 // паддинг всех кадров (включая пинги)
        FakeJobs     int64 // псевдо-задания BackupPC (штук)
        FakeJobBytes int64 // суммарный «объем бэкапов» (байт мусора)
}

// LogicalConn — логическая прокси-сессия поверх ротации gRPC-вызовов чанков
// (ТЗ 3.4). Реализует net.Conn: Write кадрирует данные в текущий чанк
// (с ротацией по лимитам времени/объема), Read читает из текущего чанка и при
// EOF плавно переходит на следующий. Для DPI каждая ротация выглядит как
// очередной вызов загрузчика чанков backuppc.*; сессия в целом — как поток
// периодических бекапов BackupPC (см. backuppc.go).
type LogicalConn struct {
        dialer ChunkDialer
        cfg    *TransportConfig
        logger *slog.Logger

        sessionID string

        wmu       sync.Mutex // писатели: релей, пинги, балансировщик, ротация
        writeCur  *ChunkHandle
        writeDone bool // upload-плечо закрыто (HalfClose/Close)

        readCur   atomic.Pointer[ChunkHandle]
        chainTail atomic.Pointer[ChunkHandle] // хвост цепочки ротаций (читатель идет по цепи)
        // readEmu — ЕДИНЫЙ кодек чтения логической сессии: его rwc —
        // switchingStream, который при EOF текущего чанка переходит на следующий.
        // pending-состояние кадра переживает ротацию (EOF всегда на границе кадра).
        readEmu *EmulatedConn

        index         uint32
        chunkBytes    int64 // атомик: payload текущего чанка, ОБА направления (триггер ротации по объему)
        chunkDeadline time.Time

        txPayload int64
        rxPayload int64
        txFake    int64
        txPadding int64
        rotations int64

        fakeJobs     int64 // псевдо-задания BackupPC
        fakeJobBytes int64
        lastDataAt   atomic.Int64 // unix-nano последнего пользовательского payload

        rotMu    sync.Mutex     // состояние ротации (для ожидания читателем)
        rotating bool
        nextCh   chan struct{} // сигнал завершения текущей ротации

        ctx    context.Context
        cancel context.CancelFunc
        wg     sync.WaitGroup

        closed    atomic.Bool
        closeOnce sync.Once

        onClose func(LogicalStats) // агрегация в Client
}

// NewLogicalConn — создает логическую сессию (без набора чанка 0 —
// его открывает Dial с VLESS-заголовком).
func NewLogicalConn(dialer ChunkDialer, cfg *TransportConfig, logger *slog.Logger, onClose func(LogicalStats)) *LogicalConn {
        ctx, cancel := context.WithCancel(context.Background())
        lc := &LogicalConn{
                dialer:    dialer,
                cfg:       cfg,
                logger:    logger,
                sessionID: newBackupPCSessionID(), // «задание» BackupPC: host.jobnum.nonce
                ctx:       ctx,
                cancel:    cancel,
                onClose:   onClose,
        }
        lc.lastDataAt.Store(time.Now().UnixNano())
        lc.readEmu = NewEmulatedConn(&switchingStream{lc: lc}, cfg)
        return lc
}

// Dial открывает чанк 0 с VLESS-заголовком и запускает фоновые
// потоки маскировки (джиттер-пинги и балансировщик).
func (lc *LogicalConn) Dial(firstPayload []byte) error {
        h, err := lc.dialer.DialChunk(lc.ctx, lc.sessionID, 0, firstPayload)
        if err != nil {
                return fmt.Errorf("dial chunk 0: %w", err)
        }
        lc.wmu.Lock()
        lc.writeCur = h
        lc.readCur.Store(h)
        lc.chainTail.Store(h)
        lc.index = 0
        lc.chunkBytes = 0
        lc.chunkDeadline = lc.nextChunkDeadline()
        lc.wmu.Unlock()

        lc.spawnJitterKeepAlive() // ТЗ 4.1
        lc.spawnTrafficBalancer() // ТЗ 4.2
        lc.spawnBackupPCJobs()    // периодические псевдо-бэкапы BackupPC

        // VLESS-заголовок ответа сервера ([version][addons len=0]) — первый кадр
        if err := lc.consumeVlessResponse(); err != nil {
                return fmt.Errorf("vless response: %w", err)
        }

        lc.logger.Info("backup job opened",
                "session", lc.shortID(), "chunk", 0, "method", lc.cfg.randomEndpoint(),
                "host", backuppcSessionHost(lc.sessionID))
        return nil
}

// consumeVlessResponse — чтение и валидация 2-байтного заголовка ответа.
func (lc *LogicalConn) consumeVlessResponse() error {
        var hdr [2]byte
        if _, err := io.ReadFull(lc.readEmu, hdr[:]); err != nil {
                return err
        }
        if hdr[0] != vlessVersion {
                return fmt.Errorf("неожиданная версия ответа %d", hdr[0])
        }
        return nil
}

// nextChunkDeadline — случайное время жизни сессии в диапазоне
// [0.5 .. 1.5] × MaxSessionDuration (ТЗ 3.4: при максимуме 30m это 15–45 минут).
func (lc *LogicalConn) nextChunkDeadline() time.Time {
        max := lc.cfg.MaxSessionDuration.D()
        lifetime := randDurationRange(max/2, max*3/2)
        return time.Now().Add(lifetime)
}

// Write — запись полезной нагрузки в текущий чанк с ротацией по лимитам.
func (lc *LogicalConn) Write(b []byte) (int, error) {
        lc.wmu.Lock()
        defer lc.wmu.Unlock()
        if err := lc.ensureFresh(); err != nil {
                return 0, err
        }
        n, err := lc.emu().Write(b)
        if n > 0 {
                atomic.AddInt64(&lc.txPayload, int64(n))
                atomic.AddInt64(&lc.chunkBytes, int64(n))
                lc.lastDataAt.Store(time.Now().UnixNano())
        }
        return n, err
}

// WritePadding — фейковый аплоад / пинги (мимо VLESS-логики, ТЗ 4.2).
func (lc *LogicalConn) WritePadding(n int) (int, error) {
        lc.wmu.Lock()
        defer lc.wmu.Unlock()
        if err := lc.ensureFresh(); err != nil {
                return 0, err
        }
        w, err := lc.emu().WritePadding(n)
        if w > 0 {
                atomic.AddInt64(&lc.txFake, int64(w))
        }
        return w, err
}

// HalfClose — полузакрытие upload-плеча: маркер EOF + END_STREAM.
// Download-плечо продолжает работать до io.EOF от сервера.
func (lc *LogicalConn) HalfClose() error {
        lc.wmu.Lock()
        defer lc.wmu.Unlock()
        if lc.writeDone || lc.writeCur == nil {
                return nil
        }
        lc.writeDone = true
        _ = lc.emu().WriteEOF()
        return lc.writeCur.Stream.CloseWrite()
}

// Read — чтение из текущего чанка, при EOF — переход на следующий.
// Объем также кормит триггер ротации (объем сессии = оба плеча, ТЗ 3.4).
func (lc *LogicalConn) Read(b []byte) (int, error) {
        n, err := lc.readEmu.Read(b)
        if n > 0 {
                atomic.AddInt64(&lc.rxPayload, int64(n))
                atomic.AddInt64(&lc.chunkBytes, int64(n))
                lc.lastDataAt.Store(time.Now().UnixNano())
        }
        return n, err
}

// Close — graceful-завершение: маркер EOF, полузакрытие upload,
// остановка фоновых потоков, освобождение чанков и метрики.
func (lc *LogicalConn) Close() error {
        lc.closeOnce.Do(func() {
                lc.closed.Store(true)
                lc.cancel()

                lc.wmu.Lock()
                if !lc.writeDone && lc.writeCur != nil {
                        lc.writeDone = true
                        _ = lc.emu().WriteEOF()
                        _ = lc.writeCur.Stream.CloseWrite()
                }
                lc.wmu.Unlock()

                // даем серверу момент закрыть свой ответ, затем подчищаем чанки
                go func() {
                        lc.wg.Wait()
                        if h := lc.readCur.Load(); h != nil {
                                _ = h.Stream.CloseRead()
                        }
                        if h := lc.chainTail.Load(); h != nil && h != lc.readCur.Load() {
                                _ = h.Stream.CloseRead()
                        }
                        if h := lc.writeCur; h != nil && h != lc.readCur.Load() {
                                _ = h.Stream.CloseRead()
                        }
                }()

                lc.logger.Info("backup session closed", "session", lc.shortID(),
                        "chunks", atomic.LoadInt64(&lc.rotations)+1)
                if lc.onClose != nil {
                        lc.onClose(lc.collectStats())
                }
        })
        return nil
}

// --- net.Conn интерфейс ---

func (lc *LogicalConn) LocalAddr() net.Addr  { return logicalAddr{} }
func (lc *LogicalConn) RemoteAddr() net.Addr { return logicalAddr{} }

// SetDeadline и производные — no-op: транспорт управляет таймингами сам
// (джиттер-пинги, ротация), приложение deadline не навязывает.
func (lc *LogicalConn) SetDeadline(t time.Time) error      { return nil }
func (lc *LogicalConn) SetReadDeadline(t time.Time) error  { return nil }
func (lc *LogicalConn) SetWriteDeadline(t time.Time) error { return nil }

type logicalAddr struct{}

func (logicalAddr) Network() string { return "backup-emulator" }
func (logicalAddr) String() string  { return "backup/logical" }

// --- Внутреннее ---

func (lc *LogicalConn) emu() *EmulatedConn {
        if h := lc.writeCur; h != nil {
                return h.Emu
        }
        return nil
}

// ensureFresh — проверка триггеров ротации (ТЗ 3.4): вызывается под wmu
// перед каждой записью (включая пинги и фейковый аплоад, поэтому
// lifetime сессии соблюдается даже при простое upload-плеча).
func (lc *LogicalConn) ensureFresh() error {
        if lc.writeDone || lc.writeCur == nil {
                return ErrClosed
        }
        if atomic.LoadInt64(&lc.chunkBytes) >= lc.cfg.MaxSessionBytes || time.Now().After(lc.chunkDeadline) {
                return lc.rotate()
        }
        return nil
}

// rotate — искусственное дробление сессии (ТЗ 3.4):
//  1. набор нового чанка (независимое TLS/HTTP/2-рукопожатие, случайный
//     gRPC-метод); сервер при регистрации преемника мгновенно передает
//     ему download-очередь (эстафета session.go);
//  2. писатель переключается на новый чанк немедленно;
//  3. END_STREAM старого чанка — сервер добивает хвост;
//  4. читатель переходит на новый чанк по EOF старого (graceful adoption).
func (lc *LogicalConn) rotate() error {
        lc.rotMu.Lock()
        lc.rotating = true
        nextCh := make(chan struct{})
        lc.nextCh = nextCh
        lc.rotMu.Unlock()
        defer func() {
                lc.rotMu.Lock()
                lc.rotating = false
                close(nextCh)
                lc.rotMu.Unlock()
        }()

        // 1) END_STREAM старого чанка: серверный pump переходит в режим
        // ожидания преемника и продолжает отдавать download-очередь
        // (RotationHandoff); тело запроса дочитывается без RST.
        old := lc.writeCur
        if old != nil {
                if cerr := old.Stream.CloseWrite(); cerr != nil && !errors.Is(cerr, io.ErrClosedPipe) {
                        lc.logger.Warn("chunk close-write", "err", cerr.Error())
                }
        }
        lc.index++
        var nh *ChunkHandle
        var err error
        for attempt := 1; attempt <= lc.cfg.DialRetries; attempt++ {
                nh, err = lc.dialer.DialChunk(lc.ctx, lc.sessionID, lc.index, nil)
                if err == nil {
                        break
                }
                lc.logger.Warn("rotation dial retry",
                        "attempt", attempt, "err", err.Error())
                select {
                case <-lc.ctx.Done():
                        lc.writeCur = nil
                        return ErrClosed
                case <-time.After(time.Duration(attempt) * 300 * time.Millisecond):
                }
        }
        if err != nil {
                lc.writeCur = nil
                return fmt.Errorf("rotation dial: %w", err)
        }
        // звено цепочки: предыдущий хвост указывает на новый чанк,
        // читатель последовательно пройдет все звенья без потери данных
        if tail := lc.chainTail.Load(); tail != nil {
                tail.next.Store(nh)
        }
        lc.chainTail.Store(nh)
        lc.writeCur = nh // писатель переключается немедленно
        atomic.StoreInt64(&lc.chunkBytes, 0)
        lc.chunkDeadline = lc.nextChunkDeadline()
        atomic.AddInt64(&lc.rotations, 1)
        lc.logger.Info("session rotated",
                "session", lc.shortID(), "chunk", lc.index,
                "method", lc.cfg.randomEndpoint())
        return nil
}

// retireChunk — освобождение старого чанка читателем (после adoption).
func (lc *LogicalConn) retireChunk(h *ChunkHandle) {
        if h == nil {
                return
        }
        _ = h.Stream.CloseRead()
        if h.Transport != nil {
                h.Transport.CloseIdleConnections()
        }
}

func (lc *LogicalConn) shortID() string {
        if len(lc.sessionID) > 8 {
                return lc.sessionID[:8]
        }
        return lc.sessionID
}

func (lc *LogicalConn) collectStats() LogicalStats {
        return LogicalStats{
                SessionID:    lc.sessionID,
                Chunks:       int64(lc.index) + 1,
                Rotations:    atomic.LoadInt64(&lc.rotations),
                TxPayload:    atomic.LoadInt64(&lc.txPayload),
                RxPayload:    atomic.LoadInt64(&lc.rxPayload),
                TxFake:       atomic.LoadInt64(&lc.txFake),
                FakeJobs:     atomic.LoadInt64(&lc.fakeJobs),
                FakeJobBytes: atomic.LoadInt64(&lc.fakeJobBytes),
        }
}

// --- Планировщик периодических псевдо-бэкапов BackupPC ---

// spawnBackupPCJobs — фоновый генератор «потока периодических бекапов»
// (эмуляция BackupPC): в простое сессии (IdleOnly) или всегда запускает
// псевдо-задания — всплески мусорного аплоада rsync-паттерном
// (16–120 КиБ, паузы 30–300 мс), инкрементные днем, полные ночью.
// Мусор уходит padding-only кадрами: серверный upload-насос отбрасывает
// его, VLESS-поток не загрязняется (ТЗ 4.2 — общий механизм с балансировщиком).
func (lc *LogicalConn) spawnBackupPCJobs() {
        bc := &lc.cfg.BackupPC
        if !bc.EnabledOn() || bc.IncrementalEvery.D() <= 0 && bc.FullEvery.D() <= 0 {
                return
        }
        lc.wg.Add(1)
        go func() {
                defer lc.wg.Done()
                for {
                        plan := backuppcNextJob(bc, time.Now())
                        select {
                        case <-lc.ctx.Done():
                                return
                        case <-time.After(plan.Delay):
                        }
                        if bc.IdleOnly && lc.userActiveRecently(10*time.Second) {
                                continue // сессия занята пользовательским трафиком — откладываем
                        }
                        lc.runFakeBackup(plan)
                }
        }()
}

// userActiveRecently — был ли пользовательский payload за последние d.
func (lc *LogicalConn) userActiveRecently(d time.Duration) bool {
        last := time.Unix(0, lc.lastDataAt.Load())
        return time.Since(last) < d
}

// runFakeBackup — исполнение псевдо-задания BackupPC: всплески мусора
// с rsync-паттерном пауз (план из planBackupBursts).
func (lc *LogicalConn) runFakeBackup(plan backuppcJobPlan) {
        bursts := planBackupBursts(plan.Bytes)
        sent := 0
        for _, b := range bursts {
                select {
                case <-lc.ctx.Done():
                        return
                case <-time.After(b.Gap):
                }
                w, err := lc.WritePadding(b.Size)
                if err != nil {
                        return // сокет закрыт — тушим
                }
                sent += w
        }
        atomic.AddInt64(&lc.fakeJobs, 1)
        atomic.AddInt64(&lc.fakeJobBytes, int64(sent))
        lc.logger.Info("fake backup job emulated",
                "session", lc.shortID(), "kind", plan.Kind.String(),
                "bytes", sent, "bursts", len(bursts))
}
