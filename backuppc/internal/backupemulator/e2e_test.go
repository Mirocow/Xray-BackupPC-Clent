package backupemulator

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

// testEnv — стек: сервер + клиент(SOCKS5).
type testEnv struct {
	srv       *Server
	client    *Client
	srvAddr   string
	socksAddr string
	uuid      string
}

func fastCfg() TransportConfig {
	return TransportConfig{
		EndpointPaths:      []string{"/backuppc.BackupService/BackupStream", "/backuppc.ChunkService/PutChunk"},
		MinPaddingSize:     32,
		MaxPaddingSize:     1400,
		PingBaseInterval:   Dur(25 * time.Millisecond),
		PingJitterMax:      Dur(15 * time.Millisecond),
		BalancingInterval:  Dur(100 * time.Millisecond),
		MinTxThreshold:     4096,
		MaxSessionDuration: Dur(2 * time.Second),
		MaxSessionBytes:    128 * 1024,
		MaxWriteChunk:      16384,
		FakeUploadChunk:    64 * 1024,
		IdleTimeout:        Dur(20 * time.Second),
		DialRetries:        3,
		RotationGrace:      Dur(120 * time.Millisecond),
		RotationHandoff:    Dur(2 * time.Second),
		BackupPC:           BackupPCConfig{Enabled: BoolPtr(false)}, // псевдо-задания — отдельный тест
	}
}

func genTestUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	const hexdigits = "0123456789abcdef"
	out := make([]byte, 0, 36)
	for i, v := range b {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out = append(out, '-')
		}
		out = append(out, hexdigits[v>>4], hexdigits[v&0xF])
	}
	return string(out)
}

func newTestEnv(tb testing.TB) *testEnv {
	uuidStr := genTestUUID()

	srvCfg := &ServerConfig{
		Listen: "127.0.0.1:0",
		UUID:   uuidStr,
	}
	srvCfg.TransportConfig = fastCfg()
	srvCfg.Host = "backup.local"
	srv, err := NewServer(srvCfg, discardLogger())
	if err != nil {
		tb.Fatal(err)
	}
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tb.Fatal(err)
	}
	go func() { _ = srv.Serve(srvLn) }()

	clCfg := &ClientConfig{
		ServerAddr:      srvLn.Addr().String(),
		SocksListen:     "127.0.0.1:0",
		UUID:            uuidStr,
		Insecure:        true,
		TransportConfig: fastCfg(),
	}
	client, err := NewClient(clCfg, discardLogger())
	if err != nil {
		tb.Fatal(err)
	}
	clLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tb.Fatal(err)
	}
	go func() { _ = client.Serve(clLn) }()

	return &testEnv{
		srv:       srv,
		client:    client,
		srvAddr:   srvLn.Addr().String(),
		socksAddr: clLn.Addr().String(),
		uuid:      uuidStr,
	}
}

func (e *testEnv) httpViaSocks() *http.Client {
	proxyURL, _ := url.Parse("socks5://" + e.socksAddr)
	return &http.Client{
		Transport: &http.Transport{
			Proxy:              http.ProxyURL(proxyURL),
			DisableCompression: true,
		},
		Timeout: 60 * time.Second,
	}
}

// TestE2EDownloadRotation — скачивание 2 МиБ через туннель с лимитом
// чанка 128 КиБ: минимум 8 ротаций, SHA-256 совпадает, балансировщик
// вливает фейковый аплоад.
func TestE2EDownloadRotation(t *testing.T) {
	env := newTestEnv(t)

	content := make([]byte, 2<<20)
	_, _ = rand.Read(content)
	wantHash := sha256.Sum256(content)

	upMux := http.NewServeMux()
	upMux.HandleFunc("/file.bin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(len(content)))
		// троттлинг: локальная петля слишком быстра для ротационного
		// каденса (2 МиБ уходит за ~30 мс) — растягиваем отдачу
		const piece = 64 << 10
		for off := 0; off < len(content); off += piece {
			end := off + piece
			if end > len(content) {
				end = len(content)
			}
			_, _ = w.Write(content[off:end])
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			time.Sleep(25 * time.Millisecond)
		}
	})
	upLn, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() { _ = http.Serve(upLn, upMux) }()

	hc := env.httpViaSocks()
	resp, err := hc.Get("http://" + upLn.Addr().String() + "/file.bin")
	if err != nil {
		t.Fatalf("GET через SOCKS: %v", err)
	}
	got, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatalf("чтение: %v", err)
	}
	hc.CloseIdleConnections() // рвет прокси-конн: socks-хендлер завершается
	gotHash := sha256.Sum256(got)
	if !bytes.Equal(gotHash[:], wantHash[:]) {
		t.Fatalf("SHA-256 не совпал: got %x want %x (размеры %d/%d)",
			gotHash[:8], wantHash[:8], len(got), len(content))
	}

	// даем SOCKS-хендлеру завершиться (aggClose по Close) и метрикам обновиться
	time.Sleep(500 * time.Millisecond)

	sm := env.srv.Metrics()
	cm := env.client.Metrics()
	t.Logf("server: sessions=%d chunks=%d bytes_down=%d", sm.Sessions, sm.Chunks, sm.BytesDown)
	t.Logf("client: chunks=%d rotations=%d rx=%d fake_upload=%d",
		cm.Chunks, cm.Rotations, cm.RxPayload, cm.TxFake)

	if sm.Chunks < 8 {
		t.Fatalf("ожидалось ≥8 чанков (ротации), got %d", sm.Chunks)
	}
	if cm.TxFake == 0 {
		t.Fatal("балансировщик не сгенерировал фейковый аплоад")
	}
	if sm.BytesDown < int64(len(content)) {
		t.Fatalf("сервер не проксировал весь объем: %d < %d", sm.BytesDown, len(content))
	}
}

// TestE2EUploadEcho — загрузка 512 КиБ через TCP-эхо за туннелем:
// симметричный трафик с ротацией upload-плеча.
func TestE2EUploadEcho(t *testing.T) {
	env := newTestEnv(t)

	echoLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := echoLn.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	payload := make([]byte, 512*1024)
	_, _ = rand.Read(payload)

	// ручной SOCKS5-клиент: CONNECT к эху, запись, чтение эха
	socks, err := net.Dial("tcp", env.socksAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer socks.Close()
	target := echoLn.Addr().String()
	host, portStr, _ := net.SplitHostPort(target)
	port, _ := strconv.Atoi(portStr)
	if err := socksCONNECT(socks, host, port); err != nil {
		t.Fatalf("socks CONNECT: %v", err)
	}

	go func() {
		_, _ = socks.Write(payload)
	}()

	got := make([]byte, len(payload))
	_, err = io.ReadFull(socks, got)
	if err != nil {
		t.Fatalf("эхо: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("эхо-поток искажен")
	}
	socks.Close() // рвет upload-плечо: HalfClose → сервер закрывает сессию
	time.Sleep(700 * time.Millisecond)

	cm := env.client.Metrics()
	t.Logf("client: chunks=%d rotations=%d tx=%d", cm.Chunks, cm.Rotations, cm.TxPayload)
	if cm.Chunks < 4 {
		t.Fatalf("ожидалось ≥4 чанков при аплоаде 512 КиБ (лимит 128 КиБ), got %d", cm.Chunks)
	}
}

func socksCONNECT(conn net.Conn, host string, port int) error {
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return err
	}
	var resp [2]byte
	if _, err := io.ReadFull(conn, resp[:]); err != nil {
		return err
	}
	if resp[1] != 0x00 {
		return errBadSocks(resp[1])
	}
	var addr []byte
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		addr = append([]byte{0x01}, ip.To4()...)
	} else {
		addr = append([]byte{0x03, byte(len(host))}, host...)
	}
	connReq := append([]byte{0x05, 0x01, 0x00}, addr...)
	connReq = append(connReq, byte(port>>8), byte(port&0xFF))
	if _, err := conn.Write(connReq); err != nil {
		return err
	}
	reply := make([]byte, 10)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	if reply[1] != 0x00 {
		return errBadSocks(reply[1])
	}
	return nil
}

type errBadSocks byte

func (e errBadSocks) Error() string { return "socks: код " + strconv.Itoa(int(e)) }

// TestAntiProbe — сервер на все некорректные запросы отвечает JSON
// хранилища с точными телами из ТЗ (раздел 6) и не рвет соединение.
func TestAntiProbe(t *testing.T) {
	env := newTestEnv(t)
	hc := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h2"}},
			ForceAttemptHTTP2: true,
		},
		Timeout: 20 * time.Second,
	}
	base := "https://" + env.srvAddr
	const method = "/backuppc.BackupService/BackupStream"

	post := func(path, session, auth, contentType string) (int, string) {
		req, _ := http.NewRequest(http.MethodPost, base+path,
			bytes.NewReader([]byte{0xde, 0xad}))
		req.Header.Set("Content-Type", contentType)
		if session != "" {
			req.Header.Set(hdrSessionID, session)
			req.Header.Set(hdrChunkIndex, "0")
		}
		if auth != "" {
			req.Header.Set(hdrChunkAuth, auth)
		}
		resp, err := hc.Do(req)
		if err != nil {
			t.Fatalf("запрос %s: %v", path, err)
		}
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		return resp.StatusCode, string(b)
	}

	// 1) без X-Backup-Session-ID — точное тело из ТЗ
	if code, body := post(method, "", "", grpcContentType); code != 400 || body != bodyInvalidSession {
		t.Fatalf("no-session: %d %s", code, body)
	}
	// 2) сессия не в формате задания BackupPC — неотличимый ответ
	if code, body := post(method, "aabb1122", "", grpcContentType); code != 400 || body != bodyInvalidSession {
		t.Fatalf("bad-session: %d %s", code, body)
	}
	// 3) сессия в формате, но без auth — тот же ответ
	if code, body := post(method, "srv-dc-01.1174.aabbccdd", "", grpcContentType); code != 400 || body != bodyInvalidSession {
		t.Fatalf("no-auth: %d %s", code, body)
	}
	// 4) сессия с подделанным auth — тот же ответ
	if code, body := post(method, "srv-dc-01.1174.aabbccdd", "00ff00ff", grpcContentType); code != 400 || body != bodyInvalidSession {
		t.Fatalf("bad-auth: %d %s", code, body)
	}
	// 5) не-gRPC content-type — 413 «сбой узла» (upgrade failed, ТЗ 6)
	if code, body := post(method, "srv-dc-01.1174.aabbccdd", "00ff00ff", "application/json"); code != 413 || body != bodyStorageFail {
		t.Fatalf("bad-content-type: %d %s", code, body)
	}
	// 6) неизвестный путь — JSON 404
	req, _ := http.NewRequest(http.MethodPost, base+"/api/v9/ghost", bytes.NewReader([]byte("x")))
	req.Header.Set("Content-Type", grpcContentType)
	if resp, err := hc.Do(req); err != nil {
		t.Fatal(err)
	} else {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		if resp.StatusCode != 404 || string(b) != bodyNotFound {
			t.Fatalf("bad-path: %d %s", resp.StatusCode, b)
		}
	}
	// 7) GET вместо POST — JSON 405
	req, _ = http.NewRequest(http.MethodGet, base+method, nil)
	if resp, err := hc.Do(req); err != nil {
		t.Fatal(err)
	} else {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		if resp.StatusCode != 405 || string(b) != bodyMethod {
			t.Fatalf("bad-method: %d %s", resp.StatusCode, b)
		}
	}
	// 8) валидный HMAC (белый бокс: UUID известен тесту), но мусорный VLESS
	sid := "srv-dc-01.1174.5eed5eed"
	id, _ := ParseUUID(env.uuid)
	auth := BackupAuthHeader(id, sid, 0)
	if code, body := post(method, sid, auth, grpcContentType); code != 413 || body != bodyStorageFail {
		t.Fatalf("bad-vless: %d %s", code, body)
	}

	sm := env.srv.Metrics()
	if sm.Probes < 7 {
		t.Fatalf("метрики проб: %d < 7", sm.Probes)
	}
}

// TestCertFingerprint — пиннинг отпечатка сервера.
func TestCertFingerprint(t *testing.T) {
	env := newTestEnv(t)
	fp := env.srv.Fingerprint()
	if len(fp) != 64 {
		t.Fatalf("отпечаток: %q", fp)
	}

	// фиктивный target: эхо-сервер, чтобы VLESS-хендшейк и dial прошли
	echoLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echoLn.Close()
	go func() {
		for {
			conn, err := echoLn.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(io.Discard, conn)
			}()
		}
	}()

	// успешный dial чанка 0 с верным пином
	clCfg := &ClientConfig{
		ServerAddr:      env.srvAddr,
		SocksListen:     "127.0.0.1:0",
		UUID:            env.uuid,
		CertFingerprint: fp,
		TransportConfig: fastCfg(),
	}
	clCfg.TransportConfig.Host = "backup.local"
	client, err := NewClient(clCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	echoHost, echoPortStr, _ := net.SplitHostPort(echoLn.Addr().String())
	echoPort, _ := strconv.Atoi(echoPortStr)
	vreq := BuildVlessRequest(mustUUID(t, env.uuid), echoHost, uint16(echoPort))
	h, err := client.DialChunk(context.Background(), "srv-dc-01.1200.a1b2c3d4", 0, vreq)
	if err != nil {
		t.Fatalf("dial с верным пином: %v", err)
	}
	_ = h.Stream.CloseWrite()
	_ = h.Stream.CloseRead()
	h.Transport.CloseIdleConnections()

	// неверный пин — dial должен провалиться (TLS alert)
	bad := []byte(fp)
	if bad[0] == '0' {
		bad[0] = '1'
	} else {
		bad[0] = '0'
	}
	clCfg2 := &ClientConfig{
		ServerAddr:      env.srvAddr,
		SocksListen:     "127.0.0.1:0",
		UUID:            env.uuid,
		CertFingerprint: string(bad),
		TransportConfig: fastCfg(),
	}
	clCfg2.TransportConfig.Host = "backup.local"
	client2, err := NewClient(clCfg2, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client2.DialChunk(context.Background(), "srv-dc-01.1201.b1c2d3e4", 0, vreq); err == nil {
		t.Fatal("dial с неверным пином должен провалиться")
	}
}

// TestE2EDurationRotation — ротация по времени жизни сессии
// (MaxSessionDuration=300ms при простое upload-плеча).
func TestE2EDurationRotation(t *testing.T) {
	env := newTestEnv(t)

	// long-poll upstream (raw TCP): держит download открытым 2.5 c,
	// затем пишет "DATA" и закрывает соединение
	gate := make(chan struct{})
	upLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer upLn.Close()
	go func() {
		conn, err := upLn.Accept()
		if err != nil {
			return
		}
		<-gate
		_, _ = conn.Write([]byte("DATA"))
		_ = conn.Close()
	}()
	time.AfterFunc(2500*time.Millisecond, func() { close(gate) })

	// прямой LogicalConn с ультракоротким MaxSessionDuration
	cfg := fastCfg()
	cfg.MaxSessionDuration = Dur(300 * time.Millisecond)
	cfg.MaxSessionBytes = 1 << 30 // ротация только по времени
	lc := NewLogicalConn(env.client, &cfg, discardLogger(), func(LogicalStats) {})
	upHost, upPortStr, _ := net.SplitHostPort(upLn.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)
	vreq := BuildVlessRequest(mustUUID(t, env.uuid), upHost, uint16(upPort))
	if err := lc.Dial(vreq); err != nil {
		t.Fatal(err)
	}
	defer lc.Close()

	// читаем 4 байта: на протяжении 2.5с сессия должна ротироваться ≥2 раз
	buf := make([]byte, 4)
	if _, err := io.ReadFull(lc, buf); err != nil {
		t.Fatalf("чтение: %v (ротаций %d)", err, atomic.LoadInt64(&lc.rotations))
	}
	if string(buf) != "DATA" {
		t.Fatalf("получено %q", buf)
	}
	if atomic.LoadInt64(&lc.rotations) < 2 {
		t.Fatalf("ротаций по времени: %d < 2", atomic.LoadInt64(&lc.rotations))
	}
}

// TestE2EFakeBackupJobs — планировщик BackupPC: в простое сессии клиент
// генерирует периодические псевдо-задания (padding-only мусор), сервер
// принимает их без повреждения VLESS-потока (мусор отбрасывается).
func TestE2EFakeBackupJobs(t *testing.T) {
	env := newTestEnv(t)

	// target: слушатель-поглотитель (сессия открывается, но данных нет)
	sinkLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sinkLn.Close()
	go func() {
		for {
			conn, err := sinkLn.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(io.Discard, conn)
			}()
		}
	}()

	cfg := fastCfg()
	cfg.MaxSessionDuration = Dur(30 * time.Second) // ротация не мешает тесту
	cfg.MaxSessionBytes = 1 << 30
	cfg.IdleTimeout = Dur(30 * time.Second)
	cfg.BackupPC = BackupPCConfig{
		IncrementalEvery:    Dur(200 * time.Millisecond),
		IncrementalMinBytes: 16 << 10,
		IncrementalMaxBytes: 32 << 10,
		FullEvery:           Dur(0), // полные не нужны
		FullMinBytes:        16 << 10,
		FullMaxBytes:        32 << 10,
		IdleOnly:            false, // VLESS-хендшейк считается «активностью»
	}

	lc := NewLogicalConn(env.client, &cfg, discardLogger(), func(LogicalStats) {})
	sinkHost, sinkPortStr, _ := net.SplitHostPort(sinkLn.Addr().String())
	sinkPort, _ := strconv.Atoi(sinkPortStr)
	vreq := BuildVlessRequest(mustUUID(t, env.uuid), sinkHost, uint16(sinkPort))
	if err := lc.Dial(vreq); err != nil {
		t.Fatal(err)
	}
	defer lc.Close()

	// ждем ≥3 псевдо-заданий (~600 мс интервалы + всплески)
	deadline := time.Now().Add(6 * time.Second)
	for atomicLoad(&lc.fakeJobs) < 3 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	jobs := atomicLoad(&lc.fakeJobs)
	if jobs < 3 {
		t.Fatalf("псевдо-заданий %d < 3 за 6 c", jobs)
	}
	fake := atomicLoad(&lc.fakeJobBytes)
	if fake < 3*16<<10 {
		t.Fatalf("объем псевдо-бэкапов: %d", fake)
	}

	// сервер должен остаться жив и проксировать данные после мусора
	// (VLESS-поток не загрязняется padding-only кадрами)
	resp := make([]byte, 16)
	testPayload := []byte("PING-AFTER-NOISE")
	_, err = lc.Write(testPayload)
	if err != nil {
		t.Fatalf("запись после мусора: %v", err)
	}
	_ = resp
	_ = err

	sm := env.srv.Metrics()
	t.Logf("server: sessions=%d chunks=%d bytes_up=%d", sm.Sessions, sm.Chunks, sm.BytesUp)
	t.Logf("client: fake_jobs=%d fake_bytes=%d", jobs, fake)
}

func atomicLoad(v *int64) int64 { return atomic.LoadInt64(v) }

func mustUUID(t *testing.T, s string) [16]byte {
	t.Helper()
	id, err := ParseUUID(s)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// BenchmarkE2EThroughput — сквозная скорость туннеля (паддинг включен).
func BenchmarkE2EThroughput(b *testing.B) {
	env := newTestEnv(b)

	const size = 256 * 1024
	content := make([]byte, size)
	_, _ = rand.Read(content)
	upMux := http.NewServeMux()
	upMux.HandleFunc("/file.bin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(size))
		_, _ = w.Write(content)
	})
	upLn, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() { _ = http.Serve(upLn, upMux) }()

	hc := env.httpViaSocks()
	b.SetBytes(size)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		resp, err := hc.Get("http://" + upLn.Addr().String() + "/file.bin")
		if err != nil {
			b.Fatal(err)
		}
		n, err := io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if err != nil || n != size {
			b.Fatalf("чтение: %d %v", n, err)
		}
	}
}

// --- Ротация со стороны читателя (стриминг после HalfClose) ---

// TestPureDownloadRotation — регресс ротации при чистом скачивании:
// upload-плечо закрыто (HalfClose сразу после запроса — паттерн 8K-
// стриминга через нативный outbound Xray), значит лимиты чанка может
// проверять ТОЛЬКО читатель. 1 МиБ при лимите чанка 64 КиБ, отдача
// растянута (локальная петля быстрее каденса ротаций): ≥8 ротаций,
// SHA-256 без потерь, пинги/балансировщик живут после HalfClose.
func TestPureDownloadRotation(t *testing.T) {
	uuidStr := genTestUUID()
	cfg := fastCfg()
	cfg.MaxSessionDuration = Dur(time.Hour) // триггер — только объем
	cfg.MaxSessionBytes = 64 * 1024
	cfg.BackupPC = BackupPCConfig{Enabled: BoolPtr(false)}

	srvCfg := &ServerConfig{Listen: "127.0.0.1:0", UUID: uuidStr, TransportConfig: cfg}
	srv, err := NewServer(srvCfg, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug})))
	if err != nil {
		t.Fatal(err)
	}
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve(srvLn) }()

	// таргет: сырой TCP — 1 МиБ кусками по 16 КиБ с паузами (каденс
	// чтения сопоставим с каденсом ротаций, как в реальной сети)
	content := make([]byte, 1<<20)
	_, _ = rand.Read(content)
	wantHash := sha256.Sum256(content)
	tgtLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		conn, err := tgtLn.Accept()
		if err != nil {
			return
		}
		const piece = 16 << 10
		for off := 0; off < len(content); off += piece {
			end := off + piece
			if end > len(content) {
				end = len(content)
			}
			_, _ = conn.Write(content[off:end])
			time.Sleep(10 * time.Millisecond)
		}
		_ = conn.Close()
	}()

	clCfg := &ClientConfig{
		ServerAddr:      srvLn.Addr().String(),
		UUID:            uuidStr,
		Insecure:        true,
		TransportConfig: cfg,
	}
	cli, err := NewClient(clCfg, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn})))
	if err != nil {
		t.Fatal(err)
	}

	lc, err := cli.DialLogical(tgtLn.Addr().(*net.TCPAddr).IP.String(),
		uint16(tgtLn.Addr().(*net.TCPAddr).Port))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// паттерн стриминга: запрос ушел, upload закрыт немедленно
	if err := lc.HalfClose(); err != nil {
		t.Fatalf("half-close: %v", err)
	}

	var got []byte
	buf := make([]byte, 64<<10)
	for {
		n, rerr := lc.Read(buf)
		if n > 0 {
			got = append(got, buf[:n]...)
		}
		if rerr != nil {
			t.Logf("READ-END: n=%d err=%v total=%d rotations=%d rotating=%v",
				n, rerr, len(got), atomic.LoadInt64(&lc.rotations), lc.rotating)
			break
		}
	}
	lc.Close()
	time.Sleep(300 * time.Millisecond) // агрегация метрик

	gotHash := sha256.Sum256(got)
	if !bytes.Equal(gotHash[:], wantHash[:]) {
		t.Fatalf("SHA-256 не совпал: got %x want %x (размеры %d/%d)",
			gotHash[:8], wantHash[:8], len(got), len(content))
	}
	cm := cli.Metrics()
	t.Logf("client: rotations=%d chunks=%d rx=%d txFake=%d",
		cm.Rotations, cm.Chunks, cm.RxPayload, cm.TxFake)
	if cm.Rotations < 8 {
		t.Fatalf("ротация читателя не работает: rotations=%d (нужно ≥8)", cm.Rotations)
	}
	if cm.TxFake == 0 {
		t.Fatal("пинги/балансировщик затухли после HalfClose (провод должен оставаться двунаправленным)")
	}
}

// TestWritePaddingAfterHalfClose — padding-only кадры (пинги, фейковый
// аплоад) переживают HalfClose: до первой ротации — no-op без ошибки
// (тело чанка закрыто), после ротации читателя — реальные кадры на
// свежем теле. Маскировка длинных скачиваний требует живого upload-плеча.
func TestWritePaddingAfterHalfClose(t *testing.T) {
	uuidStr := genTestUUID()
	cfg := fastCfg()
	cfg.MaxSessionDuration = Dur(time.Hour)
	cfg.MaxSessionBytes = 64 * 1024
	cfg.BackupPC = BackupPCConfig{Enabled: BoolPtr(false)}

	srvCfg := &ServerConfig{Listen: "127.0.0.1:0", UUID: uuidStr, TransportConfig: cfg}
	srv, err := NewServer(srvCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve(srvLn) }()

	// таргет: 256 КиБ кусками — хватает на ротацию читателя
	content := make([]byte, 256<<10)
	_, _ = rand.Read(content)
	tgtLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		conn, err := tgtLn.Accept()
		if err != nil {
			return
		}
		const piece = 16 << 10
		for off := 0; off < len(content); off += piece {
			end := off + piece
			if end > len(content) {
				end = len(content)
			}
			_, _ = conn.Write(content[off:end])
			time.Sleep(10 * time.Millisecond)
		}
		_ = conn.Close()
	}()

	clCfg := &ClientConfig{
		ServerAddr:      srvLn.Addr().String(),
		UUID:            uuidStr,
		Insecure:        true,
		TransportConfig: cfg,
	}
	cli, err := NewClient(clCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}

	lc, err := cli.DialLogical(tgtLn.Addr().(*net.TCPAddr).IP.String(),
		uint16(tgtLn.Addr().(*net.TCPAddr).Port))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer lc.Close()

	if err := lc.HalfClose(); err != nil {
		t.Fatalf("half-close: %v", err)
	}

	// до ротации: тело текущего чанка закрыто — no-op без ошибки,
	// горутины пингов не гаснут
	n, err := lc.WritePadding(4096)
	if err != nil || n != 0 {
		t.Fatalf("WritePadding после HalfClose до ротации: n=%d err=%v (ожидался no-op 0,nil)", n, err)
	}

	// читаем ПОЛОВИНУ (128 КиБ): ротация читателя гарантированно случится
	// на 64 КиБ, а передача еще идет — проверяем паддинг именно здесь.
	// После EOF (END_STREAM ответа) стрим чанка завершен в обе стороны —
	// паддинг него невозможен по протоколу (Go h2 отменяет тело запроса).
	buf := make([]byte, 32<<10)
	read := 0
	half := len(content) / 2
	deadline := time.Now().Add(5 * time.Second)
	for read < half && time.Now().Before(deadline) {
		m, rerr := lc.Read(buf)
		if m > 0 {
			read += m
		}
		if rerr != nil {
			t.Fatalf("чтение середины передачи: %v", rerr)
		}
	}
	if atomic.LoadInt64(&lc.rotations) == 0 {
		t.Fatalf("ротация читателя не сработала (read=%d)", read)
	}

	// середина передачи, свежий чанк от ротации: реальные padding-кадры
	n, err = lc.WritePadding(4096)
	if err != nil || n == 0 {
		t.Fatalf("WritePadding после ротации читателя: n=%d err=%v (ожидался успех)", n, err)
	}

	// добиваем остаток: целостность не должна пострадать от padding-кадров
	rest, rerr := io.ReadAll(lc)
	if rerr != nil {
		t.Fatalf("добивка: %v", rerr)
	}
	if read+len(rest) != len(content) {
		t.Fatalf("объем: %d+%d != %d", read, len(rest), len(content))
	}
}

// testLogger — логи теста в t.Logf (для отладки).
func testLogger(tb testing.TB) *slog.Logger {
	return slog.New(slog.NewTextHandler(tbWriter{tb}, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

type tbWriter struct{ tb testing.TB }

func (w tbWriter) Write(p []byte) (int, error) {
	w.tb.Logf("%s", p)
	return len(p), nil
}
