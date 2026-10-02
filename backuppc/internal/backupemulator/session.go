package backupemulator

import (
	"bufio"
	"errors"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"context"
)

// downloadQueueCap — емкость очереди download-плеча (слоты по ≤16 КБ):
// бэклог на время ротации (~1 рукопожатие) с backpressure на target.
const downloadQueueCap = 128

// logicalSession — серверная логическая VLESS-сессия, склеенная из
// последовательных gRPC-вызовов с одним X-Backup-Session-ID (ТЗ 3.4).
//
// Направления:
//   - upload:  кадры каждого вызова → upload-пайп → target (TCP);
//     EOF-маркер (0,0) → полузакрытие записи target;
//   - download: target → queue (пул-буферы ≤16 КБ) → активный pump,
//     записывающий кадры в тело ответа текущего вызова.
//
// Эстафета ротации: END_STREAM тела запроса чанка N без маркера →
// pump N продолжает отдавать очередь, пока не зарегистрируется pump
// чанка N+1 (registerPump закрывает successor-канал) либо не истечет
// RotationHandoff. Преемник зарегистрирован → мгновенная передача
// очереди без разрыва download-потока.
type logicalSession struct {
	id     string
	cfg    *TransportConfig
	srv    *Server
	logger *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc

	queue     chan []byte // download: payload-чанки из пула
	uploadW   *io.PipeWriter
	uploadR   *io.PipeReader
	target    net.Conn
	mu        sync.Mutex
	lastChunk int64 // последний принятый индекс чанка (-1 — еще нет)
	done      bool
	terminal  string

	// successorSignal — сигнал «зарегистрирован преемник» для
	// текущего pump; защищен mu.
	successorSignal chan struct{}

	sessionEOF chan struct{} // закрыт: клиент закончил логическую сессию
	eofOnce    sync.Once
	eofReason  string

	relayDone chan struct{} // закрыт: target read EOF (download исчерпан)
	relayOnce sync.Once

	pumpDone chan struct{} // done-канал последнего зарегистрированного pump
	pumps    int32         // активные чанк-хендлеры

	// uploadChain — done-канал последнего зарегистрированного
	// upload-насоса: эстафета ПОРЯДКА payload (зеркало pumpDone).
	// Преемник не пишет в пайп сессии, пока предшественник не дочитает
	// своё тело запроса. Без этого насосы соседних чанков перемешивают
	// байты: счетчик сходится, SHA-256 — нет.
	uploadChain chan struct{}

	idleTimer *time.Timer

	createdAt time.Time
	chunks    int64
	bytesUp   int64
	bytesDown int64
}

func newLogicalSession(srv *Server, id string) *logicalSession {
	ctx, cancel := context.WithCancel(context.Background())
	sess := &logicalSession{
		id:          id,
		cfg:         &srv.cfg.TransportConfig,
		srv:         srv,
		logger:      srv.logger.With("session", shortSessionID(id)),
		ctx:         ctx,
		cancel:      cancel,
		queue:       make(chan []byte, downloadQueueCap),
		sessionEOF:  make(chan struct{}),
		relayDone:   make(chan struct{}),
		pumpDone:    make(chan struct{}),
		uploadChain: make(chan struct{}),
		lastChunk:   -1,
		createdAt:   time.Now(),
	}
	// начальный pumpDone закрыт: чанк 0 не ждет предшественника
	close(sess.pumpDone)
	// начальное звено upload-цепи закрыто: upload-насос чанка 0 не ждет
	close(sess.uploadChain)
	// upload-пайп: payload кадров → target
	sess.uploadR, sess.uploadW = io.Pipe()
	// idle-таймер: логическая сессия без чанков закрывается без RST
	sess.idleTimer = time.AfterFunc(sess.cfg.IdleTimeout.D(), func() {
		sess.finish("idle-timeout")
	})
	return sess
}

func shortSessionID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// accept — допускает чанк с индексом idx (строгая последовательность:
// защита от replay/gap при зондировании).
func (s *logicalSession) accept(idx uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return false
	}
	if int64(idx) != s.lastChunk+1 {
		return false
	}
	s.lastChunk = int64(idx)
	atomic.AddInt64(&s.chunks, 1)
	return true
}

// touch — сброс idle-таймера при активности; false, если сессия завершена.
func (s *logicalSession) touch() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return false
	}
	s.idleTimer.Reset(s.cfg.IdleTimeout.D())
	return true
}

// registerPump — регистрация download-насоса чанка: возвращает его
// done-канал, done-канал предшественника (порядок отдачи очереди) и
// successor-канал, который закроется при регистрации СЛЕДУЮЩЕГО насоса
// (мгновенная эстафета без таймеров).
func (s *logicalSession) registerPump() (myDone, prevDone, successor chan struct{}, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return nil, nil, nil, false
	}
	myDone = make(chan struct{})
	successor = make(chan struct{})
	if s.successorSignal != nil {
		close(s.successorSignal) // будим предшественника: преемник здесь
	}
	s.successorSignal = successor
	prevDone = s.pumpDone
	s.pumpDone = myDone
	atomic.AddInt32(&s.pumps, 1)
	return myDone, prevDone, successor, true
}

// linkUploadChain — звено эстафеты upload-насосов: возвращает done-канал
// ПРЕДШЕСТВЕННИКА и регистрирует наш. Вызывается из handleChunkStream до
// запуска насоса и до любых блокировок: порядок звеньев строго совпадает с
// порядком чанков (последовательность гарантирует accept под mu — запрос
// чанка N+1 физически не может прийти раньше, чем хендлер N дошел до
// этого места).
func (s *logicalSession) linkUploadChain(done chan struct{}) <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev := s.uploadChain
	s.uploadChain = done
	return prev
}

// successorRegistered — принял ли уже эстафету чанк с индексом больше
// idx (строгая последовательность accept делает это точным индикатором).
func (s *logicalSession) successorRegistered(idx uint32) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return int64(idx) < s.lastChunk
}

// markEOF — клиент завершил логическую сессию (маркер 0/0 либо обрыв логики).
func (s *logicalSession) markEOF(reason string) {
	s.mu.Lock()
	s.eofReason = reason
	s.mu.Unlock()
	s.eofOnce.Do(func() {
		close(s.sessionEOF)
	})
}

// reason — причина завершения по EOF, если маркер получен.
func (s *logicalSession) eofReasonOr(def string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.eofReason != "" {
		return s.eofReason
	}
	return def
}

// finish — терминальное завершение сессии: закрыть target, остановить idle.
// Вызывается из pump при отдаче всей очереди либо из idle-таймера.
func (s *logicalSession) finish(reason string) {
	s.mu.Lock()
	if s.done {
		s.mu.Unlock()
		return
	}
	s.done = true
	s.terminal = reason
	s.mu.Unlock()

	s.cancel()
	s.idleTimer.Stop()
	if s.target != nil {
		_ = s.target.Close() // расшевелит Read → relayDone
	}
	s.logger.Info("session finished", "reason", reason,
		"chunks", atomic.LoadInt64(&s.chunks),
		"bytes_up", atomic.LoadInt64(&s.bytesUp),
		"bytes_down", atomic.LoadInt64(&s.bytesDown),
		"lifetime", time.Since(s.createdAt).Round(time.Millisecond).String())
	s.srv.gcSession(s)
}

// gc — попытка удалить сессию из реестра (когда pumps == 0 и сессия done).
func (s *logicalSession) gc() {
	if atomic.LoadInt32(&s.pumps) == 0 {
		s.srv.gcSession(s)
	}
}

// --- Upload: кадры чанков → target ---

// pumpUpload — насос upload-плеча чанка: читает кадры из тела запроса
// и пишет payload в общий пайп сессии (→ io.Copy(target)).
//
// idx — индекс чанка: если upload-плечо СТАРОГО чанка обрывается после
// регистрации преемника (эстафета уже у него), это штатная уборка
// ротации — END_STREAM мог не успеть покинуть буферы клиента, и сессию
// гасить нельзя (иначе ротация превращалась бы в обрыв на каждом чанке).
//
// prevUpload — done-канал upload-насоса предшествующего чанка: пока он
// не закрыт, СВОЕ тело писать в пайп нельзя (эстафета порядка). Иначе
// payload чанков N и N+1 перемешивается — байты дойдут все, но не по
// порядку: под backpressure target насос N может отставать на несколько
// кадров, а насос N+1 уже читает свежее тело. Ожидание ограничено
// жизнью сессии (idle-таймер/finish гасят зависшие тела).
func (s *logicalSession) pumpUpload(emu *EmulatedConn, uploadDone chan<- struct{}, idx uint32, prevUpload <-chan struct{}) {
	defer close(uploadDone)
	if prevUpload != nil {
		select {
		case <-prevUpload:
			// предшественник дочитал своё тело — порядок гарантирован
		case <-s.ctx.Done():
			return // сессия погашена: тело неважно
		}
	}
	for {
		payload, err := emu.ReadPayloadFrame()
		if err != nil {
			switch {
			case errors.Is(err, ErrLogicalEOF):
				// graceful: клиент закончил логическую сессию —
				// полузакрываем запись target, download продолжает добиваться
				s.markEOF("ok")
				_ = s.uploadW.Close()
				s.srv.addBytesUp(emu.Stats().RxPayload)
				return
			case errors.Is(err, io.EOF):
				// чистый END_STREAM без маркера — ротация (ТЗ 3.4),
				// пайп остается открытым для следующего чанка
				s.srv.addBytesUp(emu.Stats().RxPayload)
				return
			default:
				if s.successorRegistered(idx) {
					// преемник уже принял эстафету: обрыв upload-плеча
					// старого чанка — уборка ротации, не аборт
					s.logger.Debug("old chunk upload torn down after successor",
						"chunk", idx, "err", err.Error())
					s.srv.addBytesUp(emu.Stats().RxPayload)
					return
				}
				// сброс стрима (h2 CANCEL/NO_ERROR) при закрытии клиентом —
				// штатная ситуация teardown; настоящий мусор — «corrupt»
				if isStreamReset(err) {
					s.logger.Debug("upload stream reset", "err", err.Error())
					s.markEOF("aborted")
				} else {
					s.logger.Warn("upload stream corrupt", "err", err.Error())
					s.markEOF("corrupt")
				}
				_ = s.uploadW.CloseWithError(err)
				s.srv.addBytesUp(emu.Stats().RxPayload)
				s.finish(s.eofReasonOr("aborted"))
				return
			}
		}
		if len(payload) > 0 {
			atomic.AddInt64(&s.bytesUp, int64(len(payload)))
			if _, werr := s.uploadW.Write(payload); werr != nil {
				putFrameBuf(payload)
				return
			}
		}
		putFrameBuf(payload)
	}
}

// --- Download: target → queue → pump чанка ---

// startRelays — запуск релея после VLESS-хендшейка и набора target.
func (s *logicalSession) startRelays(target net.Conn, br *bufio.Reader) {
	s.mu.Lock()
	s.target = target
	s.mu.Unlock()

	// VLESS-ответ — первый кадр очереди (порядок FIFO сохраняется)
	s.enqueue(BuildVlessResponse())

	// upload: остаток bufio + пайп → target
	go func() {
		_, _ = io.Copy(target, br)
		if tc, ok := target.(*net.TCPConn); ok {
			_ = tc.CloseWrite() // полузакрытие: клиент закончил upload
		}
	}()

	// download: target → queue (единственный буфер на сессию, без alloc в цикле — ТЗ 7)
	go func() {
		defer s.relayOnce.Do(func() { close(s.relayDone) })
		buf := make([]byte, 16384)
		for {
			n, err := target.Read(buf)
			if n > 0 {
				if qerr := s.enqueue(buf[:n]); qerr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
}

// enqueue — дробление на слоты ≤16 КБ и постановка в очередь с backpressure.
func (s *logicalSession) enqueue(b []byte) error {
	for len(b) > 0 {
		n := len(b)
		if n > 16384 {
			n = 16384
		}
		f := getFrameBuf(n)
		copy(f, b[:n])
		select {
		case s.queue <- f[:n]:
			atomic.AddInt64(&s.bytesDown, int64(n))
		case <-s.ctx.Done():
			putFrameBuf(f)
			return ErrClosed
		}
		b = b[n:]
	}
	return nil
}

// pump — download-насос чанка: пишет кадры из очереди в тело ответа.
// Возвращает причину завершения для трейлера X-Backup-Status:
// "" — эстафета ротации (преемник заберет очередь).
//
// События:
//   - uploadDone (END_STREAM без маркера) — ротация: продолжаем отдавать
//     очередь, ждем преемника (successor) до RotationHandoff;
//   - successor закрыт — преемник зарегистрирован: мгновенная эстафета;
//   - sessionEOF (маркер 0/0) — финал: добиваем download до relayDone/idle;
//   - relayDone / ctx.Done — терминальные причины.
func (s *logicalSession) pump(emu *EmulatedConn, chunkUpload <-chan struct{}, successor <-chan struct{}) string {
	uploadDone := chunkUpload
	final := false // клиент прислал EOF-маркер: добиваем download до конца
	var handoffTimer *time.Timer
	var handoffC <-chan time.Time
	defer func() {
		if handoffTimer != nil {
			handoffTimer.Stop()
		}
	}()

	for {
		// 1) неблокирующее вытряхивание очереди
		for draining := true; draining; {
			select {
			case f := <-s.queue:
				if err := s.writeFrame(emu, f); err != nil {
					return "client-closed"
				}
			default:
				draining = false
			}
		}

		// 2) ожидание событий
		select {
		case f := <-s.queue:
			if err := s.writeFrame(emu, f); err != nil {
				return "client-closed"
			}

		case <-uploadDone:
			// тело чанка прочитано до конца без маркера — ротация:
			// очередь продолжаем отдавать, ждем преемника
			if final {
				uploadDone = nil
				continue
			}
			uploadDone = nil
			if successor == nil {
				return ""
			}
			handoffTimer = time.NewTimer(s.cfg.RotationHandoff.D())
			handoffC = handoffTimer.C

		case <-successor:
			// преемник зарегистрирован — передаем очередь, но НЕ
			// раньше, чем дочитано СВОЕ тело запроса: выход хендлера
			// с недочитанным телом = h2-сервер шлет RST NO_ERROR,
			// и хвост payload чанка теряется (эстафета upload-
			// порядка преемника строится на этом теле).
			s.awaitOwnUpload(uploadDone)
			return ""

		case <-handoffC:
			// преемник не пришел за окно — клиент ушел без ротации;
			// тело все равно должно быть дочитано (иначе RST/потеря)
			s.awaitOwnUpload(uploadDone)
			return ""

		case <-s.sessionEOF:
			final = true
			uploadDone = nil
			if handoffTimer != nil {
				handoffTimer.Stop()
				handoffC = nil
			}

		case <-s.relayDone:
			return s.drainFinal(emu, s.eofReasonOr("upstream-closed"))

		case <-s.ctx.Done():
			return s.drainFinal(emu, "idle-timeout")
		}
	}
}

// awaitOwnUpload — дождаться дочитывания СВОЕГО тела запроса до выхода
// хендлера чанка. Go http2-сервер отменяет тело запроса (RST NO_ERROR),
// как только хендлер вернул управление, — недочитанный хвост payload
// был бы потерян, а вместе с ним и порядок эстафеты upload-насосов.
// uploadDone==nil — тело уже дочитано (насос завершился) или финальный
// режим; ожидание также снимается смертью сессии.
func (s *logicalSession) awaitOwnUpload(uploadDone <-chan struct{}) {
	if uploadDone == nil {
		return
	}
	select {
	case <-uploadDone:
	case <-s.ctx.Done():
	}
}

// drainFinal — добивка очереди до пустоты (источники уже остановлены).
func (s *logicalSession) drainFinal(emu *EmulatedConn, reason string) string {
	for {
		select {
		case f := <-s.queue:
			if err := s.writeFrame(emu, f); err != nil {
				return "client-closed"
			}
		default:
			return reason
		}
	}
}

// writeFrame — кадрирование payload (EmulatedConn добавит паддинг) + flush.
func (s *logicalSession) writeFrame(emu *EmulatedConn, f []byte) error {
	_, err := emu.Write(f)
	putFrameBuf(f)
	return err
}

// pumpExit — фиксация выхода насоса: трейлер, done-канал, GC.
func (s *logicalSession) pumpExit(myDone chan struct{}, trailer string) {
	if trailer != "" {
		s.finish(trailer)
	}
	close(myDone)
	atomic.AddInt32(&s.pumps, -1)
	s.gc()
}

// isStreamReset — сброс HTTP/2-стрима клиентом (CANCEL/NO_ERROR) при
// закрытии: штатный teardown, а не протокольный мусор.
func isStreamReset(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	for _, marker := range []string{"NO_ERROR", "CANCEL", "stream closed", "broken pipe"} {
		if strings.Contains(msg, marker) {
			return true
		}
	}
	return false
}
