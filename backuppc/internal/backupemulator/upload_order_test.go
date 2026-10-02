package backupemulator

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

// TestE2EUploadRotationOrder — упорядоченность upload при ротациях чанков
// под backpressure. Таргет-«раковина» первые 350 мс вообще не читает:
// клиент успевает пролить весь payload (16 чанков по 64 КиБ), upload-насосы
// чанков копятся на пайпе сессии. Затем раковина всё дочитывает.
//
// Регрессия: без upload-эстафеты преемник начинал писать в пайп раньше,
// чем предшественник дочитывал своё тело, — байты доходили ВСЕ (счетчик
// сходится), но в перемешанном порядке (SHA-256 расходится). Зеркало
// download-эстафеты <-prevDone из handleChunkStream.
func TestE2EUploadRotationOrder(t *testing.T) {
	uuidStr := genTestUUID()
	cfg := fastCfg()
	cfg.MaxSessionBytes = 64 * 1024 // 16 чанков на 1 МиБ
	cfg.MaxSessionDuration = Dur(30 * time.Second)
	cfg.RotationHandoff = Dur(3 * time.Second)

	srvCfg := &ServerConfig{Listen: "127.0.0.1:0", UUID: uuidStr}
	srvCfg.TransportConfig = cfg
	srvCfg.Host = "backup.local"
	srv, err := NewServer(srvCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve(srvLn) }()

	clCfg := &ClientConfig{
		ServerAddr:      srvLn.Addr().String(),
		SocksListen:     "127.0.0.1:0",
		UUID:            uuidStr,
		Insecure:        true,
		TransportConfig: cfg,
	}
	client, err := NewClient(clCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	clLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = client.Serve(clLn) }()

	// sink-таргет: ворота закрыты 350 мс, затем читает всё до EOF.
	sinkLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan []byte, 1)
	go func() {
		conn, aerr := sinkLn.Accept()
		if aerr != nil {
			got <- nil
			return
		}
		time.Sleep(350 * time.Millisecond) // backpressure: насосы копятся
		data, _ := io.ReadAll(conn)
		conn.Close()
		got <- data
	}()

	const total = 1024 * 1024
	payload := make([]byte, total)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(payload)

	socks, err := net.Dial("tcp", clLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer socks.Close()
	target := sinkLn.Addr().String()
	host, portStr, _ := net.SplitHostPort(target)
	port, _ := strconv.Atoi(portStr)
	if err := socksCONNECT(socks, host, port); err != nil {
		t.Fatalf("socks CONNECT: %v", err)
	}

	writeDone := make(chan error, 1)
	go func() {
		_, werr := socks.Write(payload)
		if werr == nil {
			if tc, ok := socks.(*net.TCPConn); ok {
				werr = tc.CloseWrite() // upload-плечо клиента завершено
			}
		}
		writeDone <- werr
	}()

	// Пайплайн-upload может упереться в окна HTTP/2 задолго до открытия
	// ворот: ждем записи не дольше времени теста, ошибки — фейл.
	select {
	case werr := <-writeDone:
		if werr != nil {
			t.Fatalf("клиент не пролил payload: %v", werr)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("клиент завис при заливке payload (ротации не продвинулись)")
	}

	select {
	case data := <-got:
		if len(data) != total {
			t.Fatalf("таргет получил %d байт, ожидалось %d", len(data), total)
		}
		have := sha256.Sum256(data)
		if !bytes.Equal(have[:], want[:]) {
			t.Fatal("upload искажен: байты дошли, но не в порядке (SHA-256 расходится)")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("таргет не отдал поток (сессия не добилась)")
	}

	// метрики агрегируются в aggClose по факту Close сессии — дожидаемся
	socks.Close()
	deadline := time.Now().Add(3 * time.Second)
	var cm ClientMetrics
	for time.Now().Before(deadline) {
		cm = client.Metrics()
		if cm.TxPayload > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("client: chunks=%d rotations=%d tx=%d", cm.Chunks, cm.Rotations, cm.TxPayload)
	if cm.Chunks < 8 {
		t.Fatalf("ожидалось ≥8 чанков при аплоаде 1 МиБ (лимит 64 КиБ), got %d", cm.Chunks)
	}
}
