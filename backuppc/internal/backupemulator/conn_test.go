package backupemulator

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"
)

func testCfg() *TransportConfig {
	cfg := &TransportConfig{
		EndpointPaths:      []string{"/api/v2/storage/chunks", "/api/v1/upload"},
		MinPaddingSize:     32,
		MaxPaddingSize:     1400,
		PingBaseInterval:   Dur(50 * time.Millisecond),
		PingJitterMax:      Dur(30 * time.Millisecond),
		BalancingInterval:  Dur(10 * time.Millisecond),
		MinTxThreshold:     1024,
		MaxSessionDuration: Dur(30 * time.Minute),
		MaxSessionBytes:    2 << 30,
		MaxWriteChunk:      16384,
		FakeUploadChunk:    64 * 1024,
	}
	cfg.ApplyDefaults()
	return cfg
}

func discardLogger() *slog.Logger {
	if os.Getenv("BE_DEBUG") != "" {
		return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// duplex — дуплексный поток в памяти на паре io.Pipe.
func duplex() (io.ReadWriteCloser, io.ReadWriteCloser) {
	ar, aw := io.Pipe()
	br, bw := io.Pipe()
	return &duplexEnd{r: ar, w: bw}, &duplexEnd{r: br, w: aw}
}

type duplexEnd struct {
	r *io.PipeReader
	w *io.PipeWriter
}

func (d *duplexEnd) Read(p []byte) (int, error)  { return d.r.Read(p) }
func (d *duplexEnd) Write(p []byte) (int, error) { return d.w.Write(p) }
func (d *duplexEnd) Close() error {
	d.r.Close()
	return d.w.Close()
}

// TestFrameRoundTrip — кадрирование со случайными размерами payload,
// интерливингом padding-only кадров (пинги/фейк-аплоад) и EOF-маркером:
// читатель обязан получить исходный поток байт без мусора.
func TestFrameRoundTrip(t *testing.T) {
	cfg := testCfg()
	a, b := duplex()
	ca := NewEmulatedConn(a, cfg)
	cb := NewEmulatedConn(b, cfg)

	payloads := [][]byte{
		randBytes(t, 1),
		randBytes(t, 64),
		randBytes(t, 1500), // > maxPadding
		randBytes(t, 20000),
		randBytes(t, 70000), // > MaxWriteChunk → нарезка на кадры
		randBytes(t, 3),
	}

	go func() {
		for i, p := range payloads {
			if _, err := ca.Write(p); err != nil {
				t.Errorf("write[%d]: %v", i, err)
				return
			}
			// пинг между полезными записями — должен быть прозрачен
			if _, err := ca.WritePadding(1024); err != nil {
				t.Errorf("padding[%d]: %v", i, err)
				return
			}
		}
		if err := ca.WriteEOF(); err != nil {
			t.Errorf("eof: %v", err)
		}
	}()

	var got bytes.Buffer
	buf := make([]byte, 4096)
	for {
		n, err := cb.Read(buf)
		got.Write(buf[:n])
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("read: %v", err)
		}
	}

	var want bytes.Buffer
	for _, p := range payloads {
		want.Write(p)
	}
	if !bytes.Equal(got.Bytes(), want.Bytes()) {
		t.Fatalf("round-trip: поток искажен (got %d Б, want %d Б)", got.Len(), want.Len())
	}
}

// TestWireFormat — точная структура кадра на проводе (ТЗ 3.1):
// [2B payload BE][2B padding BE][payload][padding].
func TestWireFormat(t *testing.T) {
	cfg := &TransportConfig{MinPaddingSize: 100, MaxPaddingSize: 100, MaxWriteChunk: 16384}
	cfg.ApplyDefaults()

	ar, aw := io.Pipe() // write → aw, read → ar
	end := &duplexEnd{r: ar, w: aw}
	emu := NewEmulatedConn(end, cfg)

	payload := []byte("VLESS-TEST-PAYLOAD")

	go func() {
		if _, err := emu.Write(payload); err != nil {
			t.Errorf("write: %v", err)
		}
	}()

	wire := make([]byte, 4+len(payload)+100)
	if _, err := io.ReadFull(ar, wire); err != nil {
		t.Fatalf("read wire: %v", err)
	}
	pl := int(binary.BigEndian.Uint16(wire[0:2]))
	pd := int(binary.BigEndian.Uint16(wire[2:4]))
	if pl != len(payload) {
		t.Fatalf("payload len: got %d, want %d", pl, len(payload))
	}
	if pd != 100 {
		t.Fatalf("padding len: got %d, want 100", pd)
	}
	if !bytes.Equal(wire[4:4+pl], payload) {
		t.Fatal("payload искажен на проводе")
	}
}

// TestPaddingBounds — паддинг всегда в [min, max] (ТЗ 3.1).
func TestPaddingBounds(t *testing.T) {
	cfg := testCfg()
	for i := 0; i < 500; i++ {
		p, err := cfg.randPadding()
		if err != nil {
			t.Fatalf("randPadding: %v", err)
		}
		if p < cfg.MinPaddingSize || p > cfg.MaxPaddingSize {
			t.Fatalf("паддинг вне границ: %d ∉ [%d..%d]", p, cfg.MinPaddingSize, cfg.MaxPaddingSize)
		}
	}
}

// TestReadPartialBuffers — Read с буферами меньше кадра (pending-логика).
func TestReadPartialBuffers(t *testing.T) {
	cfg := testCfg()
	a, b := duplex()
	ca := NewEmulatedConn(a, cfg)
	cb := NewEmulatedConn(b, cfg)

	payload := randBytes(t, 5000)
	go func() {
		_, _ = ca.Write(payload)
		_ = ca.WriteEOF()
	}()

	var got []byte
	one := make([]byte, 1) // экстремальный случай: по байту
	for {
		n, err := cb.Read(one)
		got = append(got, one[:n]...)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("read: %v", err)
		}
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("побайтовое чтение: got %d Б, want %d Б", len(got), len(payload))
	}
}

// TestReadPayloadFrame — режим целых кадров: padding-only пропускается,
// EOF-маркер возвращает ErrLogicalEOF.
func TestReadPayloadFrame(t *testing.T) {
	cfg := testCfg()
	a, b := duplex()
	ca := NewEmulatedConn(a, cfg)
	cb := NewEmulatedConn(b, cfg)

	go func() {
		_, _ = ca.Write([]byte("hello"))
		_, _ = ca.WritePadding(512)
		_, _ = ca.Write([]byte("world"))
		_ = ca.WriteEOF()
	}()

	first, err := cb.ReadPayloadFrame()
	if err != nil || string(first) != "hello" {
		t.Fatalf("первый кадр: %q, err=%v", first, err)
	}
	putFrameBuf(first)
	second, err := cb.ReadPayloadFrame()
	if err != nil || string(second) != "world" {
		t.Fatalf("второй кадр: %q, err=%v", second, err)
	}
	putFrameBuf(second)
	_, err = cb.ReadPayloadFrame()
	if err != ErrLogicalEOF {
		t.Fatalf("ожидался ErrLogicalEOF, got %v", err)
	}
}

// TestFramePoolReuse — пулы отдают и принимают буферы корректно.
func TestFramePoolReuse(t *testing.T) {
	before := FramePoolMetrics()
	for i := 0; i < 100; i++ {
		b := getFrameBuf(100 + i*100)
		if cap(b) < 100+i*100 {
			t.Fatalf("буфер меньше запрошенного: cap=%d", cap(b))
		}
		putFrameBuf(b)
	}
	after := FramePoolMetrics()
	if after.Get-before.Get != 100 {
		t.Fatalf("Get: %d != 100", after.Get-before.Get)
	}
	if after.Put-before.Put != 100 {
		t.Fatalf("Put: %d != 100", after.Put-before.Put)
	}
}

// TestCloseIdempotent — Close не паникует при повторном вызове.
func TestCloseIdempotent(t *testing.T) {
	a, _ := duplex()
	emu := NewEmulatedConn(a, testCfg())
	if err := emu.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := emu.Close(); err != nil {
		t.Fatalf("close 2: %v", err)
	}
	if _, err := emu.Write([]byte("x")); err != ErrClosed {
		t.Fatalf("write после close: %v", err)
	}
}

func randBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// BenchmarkEmuWrite — аллокации на кадр (sync.Pool, ТЗ 7).
func BenchmarkEmuWrite(b *testing.B) {
	cfg := testCfg()
	ar, aw := io.Pipe()
	go func() { io.Copy(io.Discard, ar) }()
	emu := NewEmulatedConn(&duplexEnd{r: ar, w: aw}, cfg)
	payload := make([]byte, 16384)
	b.SetBytes(16384)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := emu.Write(payload); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkEmuRead — чтение кадров 16 КиБ.
func BenchmarkEmuRead(b *testing.B) {
	cfg := testCfg()
	a, c := duplex()
	writer := NewEmulatedConn(a, cfg)
	reader := NewEmulatedConn(c, cfg)
	payload := make([]byte, 16384)
	go func() {
		for {
			if _, err := writer.Write(payload); err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 32768)
	b.SetBytes(16384)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := reader.Read(buf); err != nil {
			b.Fatal(err)
		}
	}
}
