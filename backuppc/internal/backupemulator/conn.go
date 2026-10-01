package backupemulator

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
)

// Бинарный формат кадра (Wire Format, ТЗ 3.1):
//
//	 0        1        2        3        4       4+N      4+N+M
//	+--------+--------+--------+--------+--------+---------+
//	| Payload Length  | Padding Length  | Payload | Padding |
//	|   (2B, BE)      |   (2B, BE)      |  (N)    |  (M)    |
//	+--------+--------+--------+--------+--------+---------+
//
// Кадр (0,0) — маркер конца логической сессии (graceful EOF).
// Кадр (0,M>0) — padding-only: пинги и фейковый аплоад, прозрачны
// для полезной нагрузки (читатель сбрасывает мусор в никуда).
const (
	frameHeaderSize = 4 // 2B payload + 2B padding
	frameMaxPayload = 0xFFFF
	frameMaxPadding = 0xFFFF
	frameMaxTotal   = frameHeaderSize + frameMaxPayload + frameMaxPadding
)

// ErrClosed — попытка записи в закрытый поток.
var ErrClosed = errors.New("backupemulator: поток закрыт")

// ErrLogicalEOF — маркер (0,0) в режиме чтения целых кадров.
var ErrLogicalEOF = errors.New("backupemulator: маркер конца логической сессии")

// --- Пулы памяти (ТЗ, раздел 7: sync.Pool обязателен) ---
//
// Классы размеров: 2 КБ (пинги/мелкие кадры), 32 КБ (типовые кадры
// полезной нагрузки), 128 КБ (burst'ы балансировщика и крупные кадры).
// В циклах Read/Write выделения через make запрещены ТЗ: буферы
// берутся из пула и возвращаются после синхронной записи в сокет.

type framePoolClass struct {
	pool sync.Pool
	cap  int
}

var (
	framePool2K  = newFrameClass(2048)
	framePool32K = newFrameClass(32768)
	framePoolBig = newFrameClass(frameMaxTotal)
)

func newFrameClass(capacity int) *framePoolClass {
	return &framePoolClass{
		cap: capacity,
		pool: sync.Pool{New: func() any {
			b := make([]byte, capacity)
			return &b
		}},
	}
}

// FramePoolStats — счетчики пула для тестов и метрик.
type FramePoolStats struct{ Get, Put, Miss int64 }

var framePoolStats FramePoolStats

// FramePoolMetrics — снимок счетчиков пула.
func FramePoolMetrics() FramePoolStats {
	return FramePoolStats{
		Get:  atomic.LoadInt64(&framePoolStats.Get),
		Put:  atomic.LoadInt64(&framePoolStats.Put),
		Miss: atomic.LoadInt64(&framePoolStats.Miss),
	}
}

// getFrameBuf — буфер из пула нужного класса, len == n.
func getFrameBuf(n int) []byte {
	atomic.AddInt64(&framePoolStats.Get, 1)
	var p *framePoolClass
	switch {
	case n <= framePool2K.cap:
		p = framePool2K
	case n <= framePool32K.cap:
		p = framePool32K
	default:
		p = framePoolBig
	}
	pb := p.pool.Get().(*[]byte)
	if cap(*pb) < n {
		// защита от экзотических буферов в пуле
		atomic.AddInt64(&framePoolStats.Miss, 1)
		b := make([]byte, n)
		return b
	}
	return (*pb)[:n]
}

// putFrameBuf — возврат буфера в пул соответствующего класса.
func putFrameBuf(b []byte) {
	if b == nil || cap(b) == 0 {
		return
	}
	atomic.AddInt64(&framePoolStats.Put, 1)
	b = b[:cap(b)]
	var p *framePoolClass
	switch {
	case cap(b) <= framePool2K.cap:
		p = framePool2K
	case cap(b) <= framePool32K.cap:
		p = framePool32K
	default:
		p = framePoolBig
	}
	p.pool.Put(&b)
}

// ConnStats — метрики одного EmulatedConn (плечи трафика для балансировщика).
type ConnStats struct {
	TxPayload int64 // полезная нагрузка, отправленная вверх
	RxPayload int64 // полезная нагрузка, принятая вниз
	TxWire    int64 // байт в сокет, включая заголовки и паддинг
	RxWire    int64 // байт из сокета, включая заголовки и паддинг
}

// EmulatedConn — обертка над потоком чанка (HTTP/2-стрим), реализующая
// бинарный фрейминг ТЗ (раздел 3.2) с рандомным паддингом.
//
// Потокобезопасность: Write/WritePadding/WriteEOF сериализуются
// внутренним мьютексом (писатели: релей, джиттер-пинги, балансировщик);
// Read/ReadPayloadFrame рассчитаны на единственного читателя.
type EmulatedConn struct {
	rwc io.ReadWriteCloser
	cfg *TransportConfig

	wmu sync.Mutex // сериализация записи кадров

	hdr     [frameHeaderSize]byte // переиспользуемый заголовок (без alloc в цикле чтения)
	pending []byte                // остаток payload предыдущего кадра (стримовый Read)
	pendBuf []byte                // буфер из пула под pending
	discard []byte                // scratch для сброса паддинга (растет однократно)

	txPayload int64
	rxPayload int64
	txWire    int64
	rxWire    int64

	closed    atomic.Bool
	closeOnce sync.Once
}

// NewEmulatedConn — конструктор обертки над потоком чанка.
func NewEmulatedConn(rwc io.ReadWriteCloser, cfg *TransportConfig) *EmulatedConn {
	return &EmulatedConn{rwc: rwc, cfg: cfg}
}

// Write фреймует полезную нагрузку с рандомным паддингом (ТЗ 3.2).
// Большие записи нарезаются на кадры до MaxWriteChunk байт payload —
// длины пакетов на проводе получаются различными.
func (c *EmulatedConn) Write(b []byte) (int, error) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed.Load() {
		return 0, ErrClosed
	}
	total := 0
	for len(b) > 0 {
		seg := len(b)
		if seg > c.cfg.MaxWriteChunk {
			seg = c.cfg.MaxWriteChunk
		}
		if seg > frameMaxPayload {
			seg = frameMaxPayload
		}
		pad, err := c.cfg.randPadding()
		if err != nil {
			return total, err
		}
		n := frameHeaderSize + seg + pad
		frame := getFrameBuf(n)
		binary.BigEndian.PutUint16(frame[0:2], uint16(seg))
		binary.BigEndian.PutUint16(frame[2:4], uint16(pad))
		copy(frame[frameHeaderSize:], b[:seg])
		if pad > 0 {
			if _, err := rand.Read(frame[frameHeaderSize+seg : n]); err != nil {
				putFrameBuf(frame)
				return total, err
			}
		}
		if _, err := c.writeAll(frame[:n]); err != nil {
			putFrameBuf(frame)
			return total, err
		}
		putFrameBuf(frame)
		atomic.AddInt64(&c.txPayload, int64(seg))
		atomic.AddInt64(&c.txWire, int64(n))
		total += seg
		b = b[seg:]
	}
	return total, nil
}

// WritePadding — padding-only кадры (payload=0): джиттер-пинги (ТЗ 3.2)
// и фейковый аплоад балансировщика (ТЗ 4.2). Мусор прозрачен для
// полезной нагрузки: читающая сторона сбрасывает его автоматически.
func (c *EmulatedConn) WritePadding(n int) (int, error) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed.Load() {
		return 0, ErrClosed
	}
	written := 0
	for n > 0 {
		pad := n
		if pad > frameMaxPadding {
			pad = frameMaxPadding
		}
		total := frameHeaderSize + pad
		frame := getFrameBuf(total)
		binary.BigEndian.PutUint16(frame[0:2], 0)
		binary.BigEndian.PutUint16(frame[2:4], uint16(pad))
		if _, err := rand.Read(frame[frameHeaderSize:total]); err != nil {
			putFrameBuf(frame)
			return written, err
		}
		if _, err := c.writeAll(frame[:total]); err != nil {
			putFrameBuf(frame)
			return written, err
		}
		putFrameBuf(frame)
		atomic.AddInt64(&c.txWire, int64(total))
		written += pad
		n -= pad
	}
	return written, nil
}

// WriteEOF отправляет маркер конца логической сессии (кадр 0/0).
func (c *EmulatedConn) WriteEOF() error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed.Load() {
		return ErrClosed
	}
	_, err := c.writeAll(c.hdr[:frameHeaderSize])
	return err
}

// Read — стримовое чтение: возвращает payload байтами произвольного
// размера буфера b (остаток кадра буферизуется в pending).
// Паддинг читается и сбрасывается в никуда (ТЗ 3.2). Маркер (0,0)
// возвращается как io.EOF.
func (c *EmulatedConn) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	for {
		if len(c.pending) > 0 {
			n := copy(b, c.pending)
			c.pending = c.pending[n:]
			if len(c.pending) == 0 {
				putFrameBuf(c.pendBuf)
				c.pendBuf = nil
			}
			atomic.AddInt64(&c.rxPayload, int64(n))
			return n, nil
		}
		if _, err := io.ReadFull(c.rwc, c.hdr[:]); err != nil {
			return 0, err
		}
		pl := int(binary.BigEndian.Uint16(c.hdr[0:2]))
		pd := int(binary.BigEndian.Uint16(c.hdr[2:4]))
		if pl == 0 && pd == 0 {
			return 0, io.EOF // graceful-маркер конца логической сессии
		}
		if pl > 0 {
			buf := getFrameBuf(pl)
			if _, err := io.ReadFull(c.rwc, buf[:pl]); err != nil {
				putFrameBuf(buf)
				return 0, err
			}
			c.pendBuf = buf
			c.pending = buf[:pl]
		}
		if pd > 0 {
			if err := c.discardPadding(pd); err != nil {
				return 0, err
			}
		}
		atomic.AddInt64(&c.rxWire, int64(frameHeaderSize+pl+pd))
	}
}

// ReadPayloadFrame — чтение целого кадра (режим серверного upload-насоса):
// возвращает payload из пула (после использования вернуть putFrameBuf).
// Padding-only кадры пропускаются автоматически, маркер (0,0) — ErrLogicalEOF.
func (c *EmulatedConn) ReadPayloadFrame() ([]byte, error) {
	for {
		if _, err := io.ReadFull(c.rwc, c.hdr[:]); err != nil {
			return nil, err
		}
		pl := int(binary.BigEndian.Uint16(c.hdr[0:2]))
		pd := int(binary.BigEndian.Uint16(c.hdr[2:4]))
		if pl == 0 && pd == 0 {
			return nil, ErrLogicalEOF
		}
		atomic.AddInt64(&c.rxWire, int64(frameHeaderSize+pl+pd))
		if pl == 0 {
			// пинг / фейковый аплоад: мусор сбрасываем, кадр прозрачен
			if pd > 0 {
				if err := c.discardPadding(pd); err != nil {
					return nil, err
				}
			}
			continue
		}
		// сначала payload (формат: [hdr][payload][padding])
		buf := getFrameBuf(pl)
		if _, err := io.ReadFull(c.rwc, buf[:pl]); err != nil {
			putFrameBuf(buf)
			return nil, err
		}
		if pd > 0 {
			if err := c.discardPadding(pd); err != nil {
				putFrameBuf(buf)
				return nil, err
			}
		}
		atomic.AddInt64(&c.rxPayload, int64(pl))
		return buf[:pl], nil
	}
}

// discardPadding — чтение и утилизация мусорного хвоста (ТЗ 3.2).
// Scratch-буфер переиспользуется, растет только однократно.
func (c *EmulatedConn) discardPadding(n int) error {
	if cap(c.discard) < n {
		c.discard = make([]byte, n)
	}
	_, err := io.ReadFull(c.rwc, c.discard[:n])
	return err
}

// writeAll — полная запись буфера в сокет HTTP/2-стрима.
func (c *EmulatedConn) writeAll(b []byte) (int, error) {
	total := 0
	for len(b) > 0 {
		n, err := c.rwc.Write(b)
		total += n
		if err != nil {
			return total, err
		}
		b = b[n:]
	}
	return total, nil
}

// Stats — снимок метрик соединения.
func (c *EmulatedConn) Stats() ConnStats {
	return ConnStats{
		TxPayload: atomic.LoadInt64(&c.txPayload),
		RxPayload: atomic.LoadInt64(&c.rxPayload),
		TxWire:    atomic.LoadInt64(&c.txWire),
		RxWire:    atomic.LoadInt64(&c.rxWire),
	}
}

// Close закрывает underlying-поток (идемпотентно).
func (c *EmulatedConn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		c.closed.Store(true)
		err = c.rwc.Close()
	})
	return err
}

// --- gRPC-обвязка несущих команд (carrier over gRPC) ---
//
// Каждый кадр ТЗ ([PayloadLen][PaddingLen][Payload][Padding]) передается
// как одно gRPC-сообщение двунаправленного стрима
// backuppc.BackupService/BackupStream поверх HTTP/2 + TLS:
//
//      DATA-фрейм HTTP/2: [Compressed(1B=0)][Length(4B BE)] [кадр ТЗ]
//
// Несущие команды живут на уровне самого gRPC:
//   - метод вызова (POST /backuppc.BackupService/<Method>) — выбор "узла";
//   - метаданные X-Backup-Session-ID / X-Backup-Chunk-Index / X-Backup-Auth;
//   - END_STREAM тела запроса — конец чанка (ротация);
//   - трейлеры grpc-status / grpc-message / X-Backup-Status — статус вызова.
//
// Пустой payload кадра (padding-only) на уровне gRPC — пустые DATA-кадры
// «бэкапа», прозрачные для VLESS-логики обеих сторон.

const (
	grpcHdrLen   = 5 // 1B флаг сжатия + 4B длина сообщения (BE)
	grpcMsgMax   = frameMaxTotal
	grpcMaxFrame = 1 << 20 // верхняя страховочная граница (не достигается)
)

// grpcMsgReader — чтение gRPC-сообщений из тела HTTP/2 (запрос/ответ).
// Реализует io.Reader для EmulatedConn: байты выдаются кадрами сообщений,
// непрочитанный остаток буферизуется (пул-буферы, без alloc в цикле).
type grpcMsgReader struct {
	r       io.Reader
	hdr     [grpcHdrLen]byte
	pending []byte // остаток текущего сообщения
	pendBuf []byte // пул-буфер под остаток
}

// Read выдает байты текущего gRPC-сообщения, при исчерпании читает следующее.
func (m *grpcMsgReader) Read(p []byte) (int, error) {
	for len(m.pending) == 0 {
		if _, err := io.ReadFull(m.r, m.hdr[:]); err != nil {
			return 0, err
		}
		if m.hdr[0] != 0 {
			return 0, fmt.Errorf("grpc: флаг сжатия не поддерживается (0x%02x)", m.hdr[0])
		}
		n := binary.BigEndian.Uint32(m.hdr[1:grpcHdrLen])
		if n == 0 {
			continue // пустое сообщение — пропускаем
		}
		if n > uint32(grpcMaxFrame) {
			return 0, fmt.Errorf("grpc: сообщение %d байт превышает лимит %d", n, grpcMaxFrame)
		}
		buf := getFrameBuf(int(n))
		if _, err := io.ReadFull(m.r, buf[:n]); err != nil {
			putFrameBuf(buf)
			return 0, err
		}
		m.pendBuf = buf
		m.pending = buf[:n]
	}
	n := copy(p, m.pending)
	m.pending = m.pending[n:]
	if len(m.pending) == 0 {
		putFrameBuf(m.pendBuf)
		m.pendBuf = nil
	}
	return n, nil
}

// grpcMsgWriter — запись кадров ТЗ как gRPC-сообщений (префикс + кадр, flush).
type grpcMsgWriter struct {
	w     io.Writer
	flush func()
	hdr   [grpcHdrLen]byte
}

// newGrpcMsgWriter строит gRPC-писатель поверх тела запроса/ответа.
// Для ResponseWriter HTTP/2 выполняется flush после каждого сообщения
// (стриминг), для io.Pipe клиента flush не нужен.
func newGrpcMsgWriter(w io.Writer) *grpcMsgWriter {
	g := &grpcMsgWriter{w: w}
	if f, ok := w.(http.Flusher); ok {
		g.flush = f.Flush
	} else {
		g.flush = func() {}
	}
	return g
}

// Write оборачивает кадр ТЗ в gRPC-сообщение и отправляет его целиком.
func (g *grpcMsgWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > grpcMsgMax {
		return 0, fmt.Errorf("grpc: кадр %d байт превышает лимит сообщения %d", len(p), grpcMsgMax)
	}
	g.hdr[0] = 0
	binary.BigEndian.PutUint32(g.hdr[1:grpcHdrLen], uint32(len(p)))
	if _, err := g.w.Write(g.hdr[:]); err != nil {
		return 0, err
	}
	if _, err := g.w.Write(p); err != nil {
		return 0, err
	}
	g.flush()
	return len(p), nil
}

// --- Адаптеры потоков сервера ---

// reqStream — upload-плечо чанка на сервере: gRPC-сообщения тела запроса.
type reqStream struct{ r *grpcMsgReader }

func (s reqStream) Read(p []byte) (int, error)  { return s.r.Read(p) }
func (s reqStream) Write(p []byte) (int, error) { return 0, ErrClosed } // не используется
func (s reqStream) Close() error                { return nil }

// respStream — download-плечо чанка: gRPC-сообщения в тело ответа
// с принудительным flush (стриминг узла хранения).
type respStream struct{ w *grpcMsgWriter }

func (s respStream) Read(p []byte) (int, error) { return 0, io.EOF } // не используется
func (s respStream) Write(p []byte) (int, error) {
	return s.w.Write(p)
}
func (s respStream) Close() error { return nil }

// flushWriter — обертка Writer с flush после каждой записи
// (совместимость; gRPC-писатель делает flush сам).
type flushWriter struct {
	w io.Writer
}

func (fw *flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	if f, ok := fw.w.(http.Flusher); ok {
		f.Flush()
	}
	return n, err
}
