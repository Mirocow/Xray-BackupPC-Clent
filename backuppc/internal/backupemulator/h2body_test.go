package backupemulator

import (
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

// TestH2PipeBodyStreaming — гипотеза: Go http2-транспорт стримит тело
// запроса (io.Pipe) до получения заголовков ответа (нужно для VLESS-хендшейка).
func TestH2PipeBodyStreaming(t *testing.T) {
	var bodyRead atomic.Int64

	mux := http.NewServeMux()
	mux.HandleFunc("/probe", func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, io.LimitReader(r.Body, 20))
		bodyRead.Add(n)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		w.Write([]byte("RESPONSE-DATA"))
	})

	cert, err := SelfSignedCert([]string{"localhost"})
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			NextProtos:   []string{"h2"},
			Certificates: []tls.Certificate{cert},
		},
	}
	go func() { _ = srv.ServeTLS(ln, "", "") }()
	time.Sleep(100 * time.Millisecond)

	tr := &http.Transport{
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h2"}},
		ForceAttemptHTTP2: true,
	}
	pr, pw := io.Pipe()
	req, _ := http.NewRequest(http.MethodPost, "https://"+ln.Addr().String()+"/probe", pr)
	req.Header.Set("Content-Type", "application/octet-stream")

	type rtRes struct {
		resp *http.Response
		err  error
	}
	ch := make(chan rtRes, 1)
	go func() {
		resp, err := tr.RoundTrip(req)
		ch <- rtRes{resp, err}
	}()

	written := make(chan error, 1)
	go func() {
		_, werr := pw.Write([]byte("HELLO-BODY-BEFORE-HEADERS"))
		written <- werr
	}()

	select {
	case err := <-written:
		if err != nil {
			t.Fatalf("запись тела: %v", err)
		}
		t.Log("тело записано до заголовков ответа: transport стримит ✓")
	case <-time.After(3 * time.Second):
		t.Fatal("FAIL: запись тела блокируется — transport не стримит до заголовков")
	}

	res := <-ch
	if res.err != nil {
		t.Fatalf("roundtrip: %v", res.err)
	}
	b, _ := io.ReadAll(res.resp.Body)
	res.resp.Body.Close()
	if string(b) != "RESPONSE-DATA" {
		t.Fatalf("ответ: %q", b)
	}
	if bodyRead.Load() != 20 {
		t.Fatalf("сервер прочитал тела: %d, want 20", bodyRead.Load())
	}
	t.Log("proto:", res.resp.Proto)
}
