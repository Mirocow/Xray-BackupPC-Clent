package preprocess

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"
	"testing"
	"time"

	"backuppc"

	"github.com/xtls/xray-core/core"
	"golang.org/x/net/proxy"

	_ "github.com/xtls/xray-core/main/distro/all"
)

// TestE2ENativeXray — сквозной прогон «нативного» пути OneXray:
//
//	приложение → socks-inbound Xray → диспетчер → backuppc outbound
//	  → VLESS + чанки gRPC-канала → сервер xray-backuppc → HTTP-таргет.
//
// Конфигурация проходит тот же конвейер, что и в кастомном libXray:
// NormalizeJSON → core.LoadConfig → Apply → core.New → Start.
func TestE2ENativeXray(t *testing.T) {
	// 1. Транспортный сервер (как xray-backuppc).
	uuidStr := genTestUUID()
	srvCfg := &backuppc.ServerConfig{
		Listen: "127.0.0.1:0",
		UUID:   uuidStr,
	}
	srvCfg.TransportConfig = fastTransportConfig()
	srvCfg.IdleTimeout = backuppc.Dur(700 * time.Millisecond) // быстрая уборка сессии для метрик
	srvCfg.Host = "backup.local"
	srv, err := backuppc.NewServer(srvCfg, discardLogger())
	if err != nil {
		t.Fatal(err)
	}
	srvLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve(srvLn) }()
	defer srv.Shutdown(context.Background())

	// 2. HTTP-таргет за туннелем: echo-файл с троттлингом (чтобы успели
	// сработать ротации чанков).
	content := make([]byte, 1<<20) // 1 МиБ
	if _, err := rand.Read(content); err != nil {
		t.Fatal(err)
	}
	wantHash := sha256.Sum256(content)
	targetMux := http.NewServeMux()
	targetMux.HandleFunc("/file.bin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(len(content)))
		const piece = 64 << 10
		for off := 0; off < len(content); off += piece {
			end := off + piece
			if end > len(content) {
				end = len(content)
			}
			if _, err := w.Write(content[off:end]); err != nil {
				return
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			time.Sleep(10 * time.Millisecond)
		}
	})
	targetLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = http.Serve(targetLn, targetMux) }()
	targetAddr := targetLn.Addr().String()

	// 3. Xray-инстанс с app-подобным JSON: socks-inbound + backuppc-outbound.
	socksLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	socksPort := socksLn.Addr().(*net.TCPAddr).Port
	_ = socksLn.Close() // Xray слушает сам

	appJSON := fmt.Sprintf(`{
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "tag": "socksIn",
            "protocol": "socks",
            "listen": "127.0.0.1",
            "port": %d,
            "settings": {"auth": "noauth", "udp": false}
          }],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "backuppc",
              "settings": {
                "serverAddr": %q,
                "uuid": %q,
                "insecure": true,
                "endpointPaths": ["/backuppc.BackupService/BackupStream", "/backuppc.ChunkService/PutChunk"],
                "maxSessionDuration": "300ms",
                "maxSessionBytes": 131072,
                "pingBaseInterval": "25ms",
                "pingJitterMax": "15ms",
                "balancingInterval": "100ms",
                "minPaddingSize": 32,
                "maxPaddingSize": 1400
              }
            },
            {"tag": "direct", "protocol": "freedom"}
          ]
        }`, socksPort, srvLn.Addr().String(), uuidStr)

	config, err := BuildConfig([]byte(appJSON))
	if err != nil {
		t.Fatalf("BuildConfig: %v", err)
	}
	slog.SetLogLoggerLevel(slog.LevelError)
	instance, err := core.New(config)
	if err != nil {
		t.Fatalf("core.New: %v", err)
	}
	if err := instance.Start(); err != nil {
		t.Fatalf("instance.Start: %v", err)
	}
	defer instance.Close()

	// 4. HTTP-запрос через SOCKS5 ядра Xray.
	dialer := newSocks5Dialer(t, fmt.Sprintf("127.0.0.1:%d", socksPort))
	client := &http.Client{
		Transport: &http.Transport{DialContext: dialer.(proxy.ContextDialer).DialContext},
		Timeout:   90 * time.Second,
	}

	t0 := time.Now()
	resp, err := client.Get("http://" + targetAddr + "/file.bin")
	if err != nil {
		t.Fatalf("GET через backuppc-туннель: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("статус = %d", resp.StatusCode)
	}
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("чтение тела: %v", err)
	}
	t.Logf("GET+body: %v", time.Since(t0).Round(time.Millisecond))
	client.CloseIdleConnections()
	t.Logf("CloseIdleConnections @ %v", time.Since(t0).Round(time.Millisecond))
	gotHash := sha256.Sum256(got)
	if gotHash != wantHash {
		t.Fatalf("SHA-256 не совпал: получено %d байт", len(got))
	}

	// 5. Сервер видел сессию и трафик (нативная атрибуция протокола;
	// метрики собираются асинхронно при закрытии логической сессии).
	deadline := time.Now().Add(10 * time.Second)
	var m backuppc.ServerMetrics
	for time.Now().Before(deadline) {
		m = srv.Metrics()
		if m.Sessions >= 1 && m.BytesDown >= int64(len(content))/2 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if m.Sessions < 1 {
		t.Fatalf("сервер не увидел сессий: %+v", m)
	}
	if m.BytesDown < int64(len(content))/2 {
		t.Fatalf("сервер видел мало трафика: %d байт из %d", m.BytesDown, len(content))
	}
	if m.Chunks < 2 {
		t.Fatalf("ротации чанков не произошли (chunks=%d) — нативный путь должен переносить эстафету", m.Chunks)
	}
	t.Logf("native e2e: %d байт, сессий %d, чанков %d, проб отклонено %d",
		len(got), m.Sessions, m.Chunks, m.ProbeNoSession+m.ProbeBadAuth)
}

// TestE2EPlainTrafficUnaffected — конфиг без backuppc работает штатно
// (регресс: preprocess не ломает обычные конфиги ядра).
func TestE2EPlainTrafficUnaffected(t *testing.T) {
	socksLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	socksPort := socksLn.Addr().(*net.TCPAddr).Port
	_ = socksLn.Close()

	plainJSON := fmt.Sprintf(`{
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "tag": "socksIn", "protocol": "socks",
            "listen": "127.0.0.1", "port": %d,
            "settings": {"auth": "noauth", "udp": false}
          }],
          "outbounds": [{"tag": "direct", "protocol": "freedom"}]
        }`, socksPort)

	config, err := BuildConfig([]byte(plainJSON))
	if err != nil {
		t.Fatalf("BuildConfig: %v", err)
	}
	slog.SetLogLoggerLevel(slog.LevelError)
	instance, err := core.New(config)
	if err != nil {
		t.Fatalf("core.New: %v", err)
	}
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	defer instance.Close()

	// echo-таргет
	echoLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := echoLn.Accept()
			if err != nil {
				return
			}
			go func() { _, _ = io.Copy(c, c); c.Close() }()
		}
	}()

	dialer := newSocks5Dialer(t, fmt.Sprintf("127.0.0.1:%d", socksPort))
	conn, err := dialer.Dial("tcp", echoLn.Addr().String())
	if err != nil {
		t.Fatalf("dial через socks: %v", err)
	}
	defer conn.Close()
	msg := []byte("plain-config-regression")
	if _, err := conn.Write(msg); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("echo: %v", err)
	}
	if string(buf) != string(msg) {
		t.Fatalf("echo = %q", buf)
	}
}

func fastTransportConfig() backuppc.TransportConfig {
	return backuppc.TransportConfig{
		EndpointPaths:      []string{"/backuppc.BackupService/BackupStream", "/backuppc.ChunkService/PutChunk"},
		MinPaddingSize:     32,
		MaxPaddingSize:     1400,
		PingBaseInterval:   backuppc.Dur(25 * time.Millisecond),
		PingJitterMax:      backuppc.Dur(15 * time.Millisecond),
		BalancingInterval:  backuppc.Dur(100 * time.Millisecond),
		MinTxThreshold:     4096,
		MaxSessionDuration: backuppc.Dur(2 * time.Second),
		MaxSessionBytes:    128 * 1024,
		MaxWriteChunk:      16384,
		FakeUploadChunk:    64 * 1024,
		IdleTimeout:        backuppc.Dur(20 * time.Second),
		DialRetries:        3,
		RotationGrace:      backuppc.Dur(120 * time.Millisecond),
		RotationHandoff:    backuppc.Dur(2 * time.Second),
	}
}

func discardLogger() *slog.Logger {
	return slog.New(slog.DiscardHandler)
}

func newSocks5Dialer(tb testing.TB, addr string) proxy.Dialer {
	tb.Helper()
	dialer, err := proxy.SOCKS5("tcp", addr, nil, proxy.Direct)
	if err != nil {
		tb.Fatalf("socks5 dialer: %v", err)
	}
	return dialer
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

func debugLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
}
