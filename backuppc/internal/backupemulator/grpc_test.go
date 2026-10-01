package backupemulator

import (
	"bytes"
	"encoding/binary"
	"io"
	"strings"
	"testing"
)

// TestGrpcMsgRoundTrip — gRPC-обвязка: кадры ТЗ, записанные как
// gRPC-сообщения, читаются обратно байт-в-байт (несущий канал).
func TestGrpcMsgRoundTrip(t *testing.T) {
	cfg := testCfg()

	// серверный писатель — пишет в буфер (flusher не нужен)
	var buf bytes.Buffer
	w := newGrpcMsgWriter(&buf)

	// эмуляция записи: три кадра DATA + padding-only + EOF-маркер
	payloads := [][]byte{
		bytes.Repeat([]byte("A"), 16384),
		bytes.Repeat([]byte("B"), 100),
		{},
	}
	var frames []int
	emu := NewEmulatedConn(grpcRWC{w: w}, cfg)
	for _, p := range payloads {
		n, err := emu.Write(p)
		if err != nil {
			t.Fatal(err)
		}
		frames = append(frames, n)
	}
	if _, err := emu.WritePadding(3000); err != nil {
		t.Fatal(err)
	}
	if err := emu.WriteEOF(); err != nil {
		t.Fatal(err)
	}

	// читатель: gRPC-сообщения из буфера
	r := &grpcMsgReader{r: bytes.NewReader(buf.Bytes())}
	emuR := NewEmulatedConn(grpcRWC{r: r}, cfg)
	var got []byte
	var gotSizes []int
	for {
		b := make([]byte, 4096)
		n, err := emuR.Read(b)
		if n > 0 {
			got = append(got, b[:n]...)
			gotSizes = append(gotSizes, n)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("чтение: %v", err)
		}
	}
	if len(got) != 16384+100 {
		t.Fatalf("объем payload: %d != %d", len(got), 16384+100)
	}
	if !bytes.HasPrefix(got, bytes.Repeat([]byte("A"), 4096)) {
		t.Fatal("поток A искажен")
	}
	if !bytes.HasSuffix(got, bytes.Repeat([]byte("B"), 100)) {
		t.Fatal("поток B искажен")
	}
	if len(frames) != 3 || frames[0] != 16384 || frames[2] != 0 {
		t.Fatalf("размеры записей: %v", frames)
	}
	if len(gotSizes) == 0 {
		t.Fatal("нет прочитанных кусков")
	}
}

// grpcRWC — минимальный io.ReadWriteCloser поверх писателя/читателя.
type grpcRWC struct {
	w io.Writer
	r io.Reader
}

func (g grpcRWC) Write(p []byte) (int, error) { return g.w.Write(p) }
func (g grpcRWC) Read(p []byte) (int, error) {
	if g.r == nil {
		return 0, io.EOF
	}
	return g.r.Read(p)
}
func (g grpcRWC) Close() error { return nil }

// TestGrpcMsgFraming — формат сообщений: [0x00][len BE u32][кадр].
func TestGrpcMsgFraming(t *testing.T) {
	var buf bytes.Buffer
	w := newGrpcMsgWriter(&buf)
	frame := []byte{0x00, 0x01, 0x00, 0x20, 'h', 'i'} // payload=1, padding=0x20
	if _, err := w.Write(frame); err != nil {
		t.Fatal(err)
	}
	out := buf.Bytes()
	if len(out) != grpcHdrLen+len(frame) {
		t.Fatalf("длина: %d", len(out))
	}
	if out[0] != 0 {
		t.Fatalf("флаг сжатия: %d", out[0])
	}
	if binary.BigEndian.Uint32(out[1:5]) != uint32(len(frame)) {
		t.Fatalf("длина сообщения: %d", binary.BigEndian.Uint32(out[1:5]))
	}
	if !bytes.Equal(out[5:], frame) {
		t.Fatal("кадр искажен")
	}

	// пустая запись не порождает сообщений
	n := buf.Len()
	if k, err := w.Write(nil); k != 0 || err != nil {
		t.Fatalf("пустая запись: %d %v", k, err)
	}
	if buf.Len() != n {
		t.Fatal("пустая запись породила сообщение")
	}
}

// TestGrpcMsgReaderRejectsFlags — сжатые сообщения отклоняются.
func TestGrpcMsgReaderRejectsFlags(t *testing.T) {
	msg := make([]byte, 10)
	msg[0] = 1 // grpc-encoding != identity
	r := &grpcMsgReader{r: bytes.NewReader(msg)}
	buf := make([]byte, 8)
	if _, err := r.Read(buf); err == nil || !strings.Contains(err.Error(), "сжатия") {
		t.Fatalf("ожидалась ошибка сжатия: %v", err)
	}
}

// TestGrpcMsgReaderRejectsOversize — гигантские объявления длины отклоняются.
func TestGrpcMsgReaderRejectsOversize(t *testing.T) {
	msg := make([]byte, 5)
	binary.BigEndian.PutUint32(msg[1:5], 10<<20) // 10 МиБ — за лимитом
	r := &grpcMsgReader{r: bytes.NewReader(msg)}
	buf := make([]byte, 8)
	if _, err := r.Read(buf); err == nil || !strings.Contains(err.Error(), "превышает") {
		t.Fatalf("ожидалась ошибка лимита: %v", err)
	}
}

// TestGrpcMsgReaderPartialReads — чтение малыми буферами через границы
// сообщений (EmulatedConn читает 4-байтовые заголовки).
func TestGrpcMsgReaderPartialReads(t *testing.T) {
	var buf bytes.Buffer
	w := newGrpcMsgWriter(&buf)
	msgs := [][]byte{
		{0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4},
		{0x00, 0x02, 0x00, 0x00, 5, 6},
		{0x00, 0x00, 0x01, 0x00, 7},
	}
	for _, m := range msgs {
		if _, err := w.Write(m); err != nil {
			t.Fatal(err)
		}
	}

	r := &grpcMsgReader{r: bytes.NewReader(buf.Bytes())}
	var got []byte
	one := make([]byte, 1)
	for {
		n, err := r.Read(one)
		got = append(got, one[:n]...)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	want := []byte{0, 0, 0, 4, 1, 2, 3, 4, 0, 2, 0, 0, 5, 6, 0, 0, 1, 0, 7}
	if !bytes.Equal(got, want) {
		t.Fatalf("поток через границы сообщений искажен:\ngot  %v\nwant %v", got, want)
	}
}
