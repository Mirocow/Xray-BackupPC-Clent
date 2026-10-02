package backupemulator

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// HTTP-заголовки протокола маскировки.
const (
	hdrSessionID    = "X-Backup-Session-ID"
	hdrChunkIndex   = "X-Backup-Chunk-Index"
	hdrChunkAuth    = "X-Backup-Auth"
	hdrBackupStatus = "X-Backup-Status"

	grpcContentType = "application/grpc"
	grpcTrailerDecl = "Grpc-Status, Grpc-Message, X-Backup-Status" // объявленные трейлеры
)

// Тела ответов для зондирующих запросов (ТЗ, раздел 6): сервер никогда
// не рвет TCP флагом RST — всегда HTTP-ответ в стиле Synology/Nextcloud.
const (
	bodyInvalidSession = `{"error":{"code":"InvalidBackupSession","message":"Session token missing or expired"}}`
	bodyMethod         = `{"error":{"code":"MethodNotAllowed","message":"Backup upload requires POST"}}`
	bodyNotFound       = `{"error":{"code":"NotFound","message":"No backup endpoint at this location"}}`
	bodyStorageFail    = `{"status":"error","reason":"Storage node backup-pool-01 allocation failed"}`
)

// ServerMetrics — агрегированные метрики сервера.
type ServerMetrics struct {
	Sessions       int64
	Chunks         int64
	Probes         int64
	ProbeNoSession int64
	ProbeBadAuth   int64
	ProbeBadPath   int64
	ProbeBadMethod int64
	ProbeBadVless  int64
	BytesUp        int64
	BytesDown      int64
}

// Server — inbound-транспорт (Listener): HTTP/2 + TLS, анти-пробинг,
// склейка чанков в логические VLESS-сессии и проксирование TCP.
type Server struct {
	cfg      *ServerConfig
	uuid     [16]byte
	logger   *slog.Logger
	srv      *http.Server
	mux      *http.ServeMux
	sessions sync.Map // sessionID → *logicalSession
	cert     tls.Certificate

	metrics ServerMetrics
}

// NewServer — конструктор: сертификат TLS (файлы или self-signed),
// строгий mux только по путям из endpointPaths.
func NewServer(cfg *ServerConfig, logger *slog.Logger) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	uuid, err := ParseUUID(cfg.UUID)
	if err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}

	cert, err := loadOrGenCert(cfg)
	if err != nil {
		return nil, err
	}

	s := &Server{
		cfg:    cfg,
		uuid:   uuid,
		logger: logger.With("component", "server"),
		cert:   cert,
	}

	// Мимикрия роутинга: валидны базовые пути и их "файлы чанков"
	// (/api/v1/upload/backup-chunk-007.bin), всё прочее — JSON 404.
	s.mux = http.NewServeMux()
	s.mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if s.matchEndpoint(r.URL.Path) {
			s.handleInbound(w, r)
			return
		}
		s.probe(w, r, "path", http.StatusNotFound, bodyNotFound)
	})

	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"h2"},
	}
	s.srv = &http.Server{
		Handler:           s.recoverMiddleware(s.mux),
		TLSConfig:         tlsCfg,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	return s, nil
}

// matchEndpoint — путь является валидной точкой загрузки: точное
// совпадение с endpointPaths либо "файл чанка" внутри базового пути.
func (s *Server) matchEndpoint(p string) bool {
	for _, base := range s.cfg.EndpointPaths {
		b := strings.TrimRight(base, "/")
		if p == b || strings.HasPrefix(p, b+"/") {
			return true
		}
	}
	return false
}

// recoverMiddleware — сервер не рвет соединения на панике: имитация
// деградации узла хранения (ТЗ, раздел 6).
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.logger.Error("handler panic", "panic", fmt.Sprint(rec), "path", r.URL.Path)
				if !headersWritten(w) {
					s.jsonResponse(w, http.StatusInternalServerError, bodyStorageFail)
				}
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func headersWritten(w http.ResponseWriter) bool {
	_, ok := w.(interface{ Written() bool })
	_ = ok
	// http2 response writer не экспортирует статус; безопасный fallback:
	return false
}

// ListenAndServe поднимает TLS-листенер (адрес из конфигурации).
func (s *Server) ListenAndServe() error {
	ln, err := net.Listen("tcp", s.cfg.Listen)
	if err != nil {
		return err
	}
	s.logger.Info("backup-emulator server listening",
		"addr", ln.Addr().String(), "paths", s.cfg.EndpointPaths,
		"fingerprint", CertFingerprint(s.cert))
	return s.srv.ServeTLS(ln, "", "")
}

// Serve обслуживает готовый listener (для тестов).
func (s *Server) Serve(ln net.Listener) error {
	return s.srv.ServeTLS(ln, "", "")
}

// Fingerprint — SHA-256 (hex) сертификата сервера (для пиннинга клиентом).
func (s *Server) Fingerprint() string { return CertFingerprint(s.cert) }

// Shutdown — graceful-остановка.
func (s *Server) Shutdown(ctx context.Context) error { return s.srv.Shutdown(ctx) }

// Metrics — снимок метрик.
func (s *Server) Metrics() ServerMetrics {
	return ServerMetrics{
		Sessions:       atomic.LoadInt64(&s.metrics.Sessions),
		Chunks:         atomic.LoadInt64(&s.metrics.Chunks),
		Probes:         atomic.LoadInt64(&s.metrics.Probes),
		ProbeNoSession: atomic.LoadInt64(&s.metrics.ProbeNoSession),
		ProbeBadAuth:   atomic.LoadInt64(&s.metrics.ProbeBadAuth),
		ProbeBadPath:   atomic.LoadInt64(&s.metrics.ProbeBadPath),
		ProbeBadMethod: atomic.LoadInt64(&s.metrics.ProbeBadMethod),
		ProbeBadVless:  atomic.LoadInt64(&s.metrics.ProbeBadVless),
		BytesUp:        atomic.LoadInt64(&s.metrics.BytesUp),
		BytesDown:      atomic.LoadInt64(&s.metrics.BytesDown),
	}
}

func (s *Server) addBytesUp(n int64)   { atomic.AddInt64(&s.metrics.BytesUp, n) }
func (s *Server) addBytesDown(n int64) { atomic.AddInt64(&s.metrics.BytesDown, n) }

// gcSession — удаление завершенной сессии из реестра (с проверкой
// идентичности: сессионные объекты-двойники не удаляют живую сессию).
func (s *Server) gcSession(sess *logicalSession) {
	sess.mu.Lock()
	done := sess.done
	sess.mu.Unlock()
	if !done {
		return
	}
	if actual, ok := s.sessions.Load(sess.id); ok && actual.(*logicalSession) == sess {
		s.sessions.Delete(sess.id)
		s.addBytesDown(atomic.LoadInt64(&sess.bytesDown))
		s.logger.Debug("session unregistered", "session", shortSessionID(sess.id))
	}
}

// --- HTTP-слой ---

// handleInbound — точка входа gRPC-вызова «узла хранения» (ТЗ, раздел 6).
func (s *Server) handleInbound(w http.ResponseWriter, r *http.Request) {
	// 1) Метод: gRPC-вызов — всегда POST.
	if r.Method != http.MethodPost {
		s.probe(w, r, "method", http.StatusMethodNotAllowed, bodyMethod)
		return
	}

	// 2) Несущий канал — gRPC: content-type и HTTP/2 обязательны.
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, grpcContentType) {
		// «Upgrade failed» по ТЗ 6: имитация сбоя узла хранения, 413.
		s.probe(w, r, "content-type", http.StatusRequestEntityTooLarge, bodyStorageFail)
		return
	}
	if r.ProtoMajor != 2 {
		s.probe(w, r, "no-h2", http.StatusRequestEntityTooLarge, bodyStorageFail)
		return
	}

	// 3) Токен бэкап-сессии обязателен (формат задания BackupPC).
	sid := r.Header.Get(hdrSessionID)
	if sid == "" {
		s.probe(w, r, "no-session", http.StatusBadRequest, bodyInvalidSession)
		return
	}
	if !validBackupPCSessionID(sid) {
		s.probe(w, r, "bad-session", http.StatusBadRequest, bodyInvalidSession)
		return
	}
	idxStr := r.Header.Get(hdrChunkIndex)
	idx64, err := strconv.ParseUint(idxStr, 10, 32)
	if err != nil {
		s.probe(w, r, "no-session", http.StatusBadRequest, bodyInvalidSession)
		return
	}
	idx := uint32(idx64)

	// 4) HMAC чанка: отличает легитимный клиент от риплея/подделки зонда.
	auth := r.Header.Get(hdrChunkAuth)
	if !s.verifyAuth(sid, idx, auth) {
		atomic.AddInt64(&s.metrics.ProbeBadAuth, 1)
		s.logger.Warn("active probe blocked", "kind", "bad-auth", "remote", r.RemoteAddr)
		s.probe(w, r, "bad-auth", http.StatusBadRequest, bodyInvalidSession)
		return
	}

	// 5) Логическая сессия: строгая последовательность индексов.
	sess := s.sessionFor(sid, idx)
	if sess == nil {
		s.probe(w, r, "bad-chunk", http.StatusBadRequest, bodyInvalidSession)
		return
	}

	s.handleChunkStream(w, r, sess, idx)
}

// verifyAuth — HMAC-SHA256(uuid, sessionID|chunkIndex): ключ известен
// только клиенту и серверу, зондер без ключа получает неотличимый 400.
func (s *Server) verifyAuth(sid string, idx uint32, auth string) bool {
	if auth == "" {
		return false
	}
	mac := hmac.New(sha256.New, s.uuid[:])
	fmt.Fprintf(mac, "%s|%d", sid, idx)
	want := hex.EncodeToString(mac.Sum(nil))
	// защита от timing-оракулa
	var diff byte
	for i := 0; i < len(want) && i < len(auth); i++ {
		diff |= want[i] ^ auth[i]
	}
	return len(auth) == len(want) && diff == 0
}

// BackupAuthHeader — значение X-Backup-Auth для чанка (используется клиентом).
func BackupAuthHeader(key [16]byte, sid string, idx uint32) string {
	mac := hmac.New(sha256.New, key[:])
	fmt.Fprintf(mac, "%s|%d", sid, idx)
	return hex.EncodeToString(mac.Sum(nil))
}

// sessionFor — поиск/создание логической сессии со строгой последовательностью.
func (s *Server) sessionFor(sid string, idx uint32) *logicalSession {
	if v, ok := s.sessions.Load(sid); ok {
		sess := v.(*logicalSession)
		if !sess.accept(idx) {
			return nil
		}
		atomic.AddInt64(&s.metrics.Chunks, 1)
		return sess
	}
	if idx != 0 {
		return nil
	}
	// создаем объект только при промахе (двойники не попадают в реестр)
	fresh := newLogicalSession(s, sid)
	if _, loaded := s.sessions.LoadOrStore(sid, fresh); loaded {
		// конкурентный чанк 0 с тем же ID — replay: двойник гасим
		fresh.finish("replayed")
		return nil
	}
	if !fresh.accept(0) {
		return nil
	}
	atomic.AddInt64(&s.metrics.Sessions, 1)
	atomic.AddInt64(&s.metrics.Chunks, 1)
	s.logger.Info("session registered", "session", shortSessionID(sid))
	return fresh
}

// probe — унифицированный анти-проб ответ: tarpit (высасываем тело,
// задержка) + JSON в стиле API хранилища. TCP никогда не рвется RST'ом.
func (s *Server) probe(w http.ResponseWriter, r *http.Request, kind string, code int, body string) {
	atomic.AddInt64(&s.metrics.Probes, 1)
	switch kind {
	case "no-session", "bad-chunk", "expired", "bad-session":
		atomic.AddInt64(&s.metrics.ProbeNoSession, 1)
	case "bad-auth":
		// учтено выше
	case "path":
		atomic.AddInt64(&s.metrics.ProbeBadPath, 1)
	case "method":
		atomic.AddInt64(&s.metrics.ProbeBadMethod, 1)
	case "vless":
		atomic.AddInt64(&s.metrics.ProbeBadVless, 1)
	case "content-type", "no-h2":
		// «upgrade failed» — учтено в общем счетчике
	}
	s.logger.Warn("active probe blocked", "kind", kind, "path", r.URL.Path, "remote", r.RemoteAddr)

	// tarpit: пусть зондер потратит время и трафик (не дольше 2 c,
	// чтобы полуоткрытое тело запроса не подвешивало обработчик)
	if r.Body != nil {
		drained := make(chan struct{})
		go func() {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 512*1024))
			close(drained)
		}()
		select {
		case <-drained:
		case <-time.After(2 * time.Second):
		}
	}
	time.Sleep(150 * time.Millisecond)
	s.jsonResponse(w, code, body)
}

func (s *Server) jsonResponse(w http.ResponseWriter, code int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Backup-Storage", "backup-pool-01")
	w.WriteHeader(code)
	_, _ = io.WriteString(w, body)
}

// handleChunkStream — перевод gRPC-вызова в бинарный двунаправленный
// режим (аналог UpgradeToGrpcPipe из ТЗ) и запуск проксирования VLESS.
// Кадры ТЗ едут внутри gRPC-сообщений (несущий канал — см. conn.go).
func (s *Server) handleChunkStream(w http.ResponseWriter, r *http.Request, sess *logicalSession, idx uint32) {
	if !sess.touch() {
		s.probe(w, r, "expired", http.StatusBadRequest, bodyInvalidSession)
		return
	}

	// upload-насос: gRPC-сообщения тела запроса → пайп сессии.
	// linkUploadChain ДО запуска: звено цепи встает до любых блокировок
	// (vlessHandshake чанка 0), порядок звеньев = порядок чанков.
	emuU := NewEmulatedConn(reqStream{r: &grpcMsgReader{r: r.Body}}, sess.cfg)
	uploadDone := make(chan struct{})
	prevUpload := sess.linkUploadChain(uploadDone)
	go sess.pumpUpload(emuU, uploadDone, idx, prevUpload)

	if idx == 0 {
		// VLESS-хендшейк до записи статуса: валидный хендшейк = 200,
		// мусор = имитация сбоя узла хранения (анти-пробинг)
		if !s.vlessHandshake(sess) {
			// расшевелить upload-насос (пайп без читателя) и погасить сессию
			_ = sess.uploadW.CloseWithError(ErrBadVless)
			_ = sess.uploadR.CloseWithError(ErrBadVless)
			sess.finish("vless-failed")
			s.probe(w, r, "vless", http.StatusRequestEntityTooLarge, bodyStorageFail)
			return
		}
	}

	// статусы и заголовки gRPC-вызова
	w.Header().Set("Content-Type", grpcContentType)
	w.Header().Set("X-Backup-Storage", "backup-pool-01")
	w.Header().Set("Trailer", grpcTrailerDecl)
	w.WriteHeader(http.StatusOK)
	// Flush обязателен: без первой записи тела HEADERS-фрейм не уходит,
	// и клиент ждет ответа ротационного чанка с пустой очередью бесконечно.
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	emuD := NewEmulatedConn(respStream{w: newGrpcMsgWriter(w)}, sess.cfg)

	myDone, prevDone, successor, ok := sess.registerPump()
	if !ok {
		// сессия завершилась, пока мы ставили заголовки — закрываем чисто
		w.Header().Set(hdrBackupStatus, "expired")
		w.Header().Set("Grpc-Status", "1") // CANCELED
		return
	}
	if idx > 0 {
		<-prevDone // эстафета: ждем, пока предыдущий чанк добьет очередь
	}

	trailer := sess.pump(emuD, uploadDone, successor)
	// "" — эстафета ротации: сессия НЕ завершается, вызов при этом
	// правдоподобно завершается как законченная загрузка чанка.
	httpTrailer := trailer
	if httpTrailer == "" {
		httpTrailer = "chunk-complete" // вызов чанка завершен успешно
	}
	w.Header().Set(hdrBackupStatus, httpTrailer)
	w.Header().Set("Grpc-Status", "0") // OK
	w.Header().Set("Grpc-Message", grpcMessage(httpTrailer))
	sess.pumpExit(myDone, trailer) // с "" finish() не вызывается
}

// grpcMessage — человекочитаемый grpc-message по статусу вызова.
func grpcMessage(reason string) string {
	if reason == "" || reason == "ok" {
		return ""
	}
	return "backup session: " + reason
}

// vlessHandshake — парсинг VLESS-заголовка из upload-пайпа с таймаутом
// и набор target. true — сессия установлена.
func (s *Server) vlessHandshake(sess *logicalSession) bool {
	handshakeCtx, cancel := context.WithTimeout(sess.ctx, 15*time.Second)
	defer cancel()

	// таймаут парсинга: закрываем пайп со стороны читателя
	timer := time.AfterFunc(15*time.Second, func() {
		_ = sess.uploadR.CloseWithError(ErrBadVless)
	})
	defer timer.Stop()
	_ = handshakeCtx

	br := bufio.NewReaderSize(sess.uploadR, 4096)
	tgt, err := ParseVlessRequest(br)
	if err != nil {
		s.logger.Warn("vless handshake failed", "err", err.Error())
		return false
	}
	if tgt.UUID != s.uuid {
		s.logger.Warn("vless uuid mismatch")
		return false
	}
	if tgt.Command != vlessCmdTCP {
		s.logger.Warn("vless unsupported command", "command", tgt.Command)
		return false
	}

	d := net.Dialer{Timeout: 10 * time.Second}
	target, err := d.DialContext(handshakeCtx, "tcp", tgt.Target())
	if err != nil {
		s.logger.Warn("target dial failed", "target", tgt.Target(), "err", err.Error())
		return false
	}
	s.logger.Info("vless session established", "target", tgt.Target())

	sess.startRelays(target, br)
	return true
}

// MarshalJSON-хелпер для метрик в demo.
func (m ServerMetrics) JSON() string {
	b, _ := json.Marshal(m)
	return string(b)
}
