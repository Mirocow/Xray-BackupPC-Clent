package backupemulator

import (
        "bufio"
        "context"
        "crypto/tls"
        "encoding/binary"
        "errors"
        "fmt"
        "io"
        "log/slog"
        "net"
        "net/http"
        "strconv"
        "strings"
        "sync/atomic"
        "time"
)

// ClientMetrics — агрегированные метрики клиента.
type ClientMetrics struct {
        Sessions     int64
        Chunks       int64
        Rotations    int64
        TxPayload    int64
        RxPayload    int64
        TxFake       int64 // фейковый аплоад (мусор балансировщика)
        FakeJobs     int64 // псевдо-задания BackupPC (штук)
        FakeJobBytes int64 // суммарный «объем бэкапов» (байт мусора)
}

// Client — outbound-транспорт: локальный SOCKS5-inbound, набор чанков
// к Backup-Emulator серверу, VLESS-инкапсуляция и фоновая маскировка.
type Client struct {
        cfg     *ClientConfig
        uuid    [16]byte
        logger  *slog.Logger
        tlsConf *tls.Config

        metrics ClientMetrics
}

// isV1Only — проверяет, ограничен ли клиент только V1 протоколом.
// Возвращает true когда AllowedProtocols=["v1"] (только V1 разрешён).
// Когда AllowedProtocols пуст или содержит "v2" — клиент использует V2.
func (c *Client) isV1Only() bool {
        if len(c.cfg.AllowedProtocols) == 0 {
                return false // пустой = оба разрешены → V2 используется когда UseV2Auth=true
        }
        for _, p := range c.cfg.AllowedProtocols {
                if p == "v1" {
                        return true
                }
        }
        return false
}

// NewClient — конструктор outbound-транспорта.
func NewClient(cfg *ClientConfig, logger *slog.Logger) (*Client, error) {
        if err := cfg.Validate(); err != nil {
                return nil, err
        }
        // V2 token path (audit 2026-10-14): when UserToken is set,
        // derive VLESS UUID from token = token[:16] (RFC 4122 variant bits
        // set). Client doesn't store UUID separately — only token.
        // Server uses same derivation to look up user by VLESS UUID.
        //
        // Legacy path: when UserToken is empty, use cfg.UUID directly (V1
        // and pre-2026-10-14 V2 clients that still store UUID).
        var uuid [16]byte
        if cfg.UserToken != "" {
                derived, err := DeriveVLESSUUIDFromToken(cfg.UserToken)
                if err != nil {
                        return nil, fmt.Errorf("v2: derive UUID from token: %w", err)
                }
                uuid = derived
        } else {
                u, err := ParseUUID(cfg.UUID)
                if err != nil {
                        return nil, err
                }
                uuid = u
        }
        if logger == nil {
                logger = slog.Default()
        }
        tlsConf, err := clientTLSConfig(cfg)
        if err != nil {
                return nil, err
        }
        return &Client{
                cfg:     cfg,
                uuid:    uuid,
                logger:  logger.With("component", "client"),
                tlsConf: tlsConf,
        }, nil
}

// ListenAndServe поднимает SOCKS5-листенер.
func (c *Client) ListenAndServe() error {
        ln, err := net.Listen("tcp", c.cfg.SocksListen)
        if err != nil {
                return err
        }
        c.logger.Info("socks5 inbound listening", "addr", ln.Addr().String(),
                "server", c.cfg.ServerAddr, "host", c.cfg.Host)
        return c.Serve(ln)
}

// Serve обслуживает готовый listener (для тестов).
func (c *Client) Serve(ln net.Listener) error {
        for {
                conn, err := ln.Accept()
                if err != nil {
                        return err
                }
                go c.serveSocks(conn)
        }
}

// Metrics — снимок метрик.
func (c *Client) Metrics() ClientMetrics {
        return ClientMetrics{
                Sessions:     atomic.LoadInt64(&c.metrics.Sessions),
                Chunks:       atomic.LoadInt64(&c.metrics.Chunks),
                Rotations:    atomic.LoadInt64(&c.metrics.Rotations),
                TxPayload:    atomic.LoadInt64(&c.metrics.TxPayload),
                RxPayload:    atomic.LoadInt64(&c.metrics.RxPayload),
                TxFake:       atomic.LoadInt64(&c.metrics.TxFake),
                FakeJobs:     atomic.LoadInt64(&c.metrics.FakeJobs),
                FakeJobBytes: atomic.LoadInt64(&c.metrics.FakeJobBytes),
        }
}

// DialLogical — открытие новой логической сессии с VLESS-запросом к target.
func (c *Client) DialLogical(targetAddr string, targetPort uint16) (*LogicalConn, error) {
        vreq := BuildVlessRequest(c.uuid, targetAddr, targetPort)
        lc := NewLogicalConn(c, &c.cfg.TransportConfig, c.logger, c.aggClose)
        if err := lc.Dial(vreq); err != nil {
                return nil, err
        }
        return lc, nil
}

func (c *Client) aggClose(st LogicalStats) {
        atomic.AddInt64(&c.metrics.Sessions, 1)
        atomic.AddInt64(&c.metrics.Chunks, st.Chunks)
        atomic.AddInt64(&c.metrics.Rotations, st.Rotations)
        atomic.AddInt64(&c.metrics.TxPayload, st.TxPayload)
        atomic.AddInt64(&c.metrics.RxPayload, st.RxPayload)
        atomic.AddInt64(&c.metrics.TxFake, st.TxFake)
        atomic.AddInt64(&c.metrics.FakeJobs, st.FakeJobs)
        atomic.AddInt64(&c.metrics.FakeJobBytes, st.FakeJobBytes)
}

// DialChunk — реализация ChunkDialer: несущий вызов gRPC — новое
// независимое TLS/HTTP/2-рукопожатие (свой Transport на чанк) на случайный
// метод backuppc.* (endpointPaths) с метаданными чанка.
func (c *Client) DialChunk(ctx context.Context, sessionID string, index uint32, firstPayload []byte) (*ChunkHandle, error) {
        path := c.cfg.randomEndpoint()
        // Sidecar mode (audit 2026-10-13): when SidecarAddr is set, use h2c
        // (HTTP/2 over cleartext TCP) to talk to the local utls-tunnel sidecar.
        // The sidecar wraps bytes in uTLS+TLS+ECH+Noise and relays to the real
        // server. Server sees HTTP/2 inside TLS (single TLS layer, no double-TLS).
        //
        // When SidecarAddr is empty: standard HTTPS path (TLS+HTTP/2 directly
        // to server) — original V1 behavior unchanged.
        var url string
        var tr ChunkCloser
        if c.cfg.SidecarAddr != "" {
                url = "http://" + c.cfg.SidecarAddr + path
                // h2c transport: HTTP/2 over plain TCP, prior-knowledge mode
                // (no ALPN — sidecar local listener is plain TCP).
                tr = newH2CTransport(c.cfg.DialContext)
        } else {
                url = "https://" + c.cfg.ServerAddr + path
                tr = &http.Transport{
                        TLSClientConfig:       c.tlsConf.Clone(),
                        ForceAttemptHTTP2:     true,
                        DisableCompression:    true,
                        MaxConnsPerHost:       1,
                        ResponseHeaderTimeout: 20 * time.Second,
                        IdleConnTimeout:       90 * time.Second,
                        DialContext:            c.cfg.DialContext,
                }
        }

        pr, pw := io.Pipe()
        req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, pr)
        if err != nil {
                return nil, err
        }
        if c.cfg.Host != "" {
                req.Host = c.cfg.Host // домен-донор в Host-заголовке
        }
        ua := c.cfg.UserAgent
        if ua == "" {
                ua = pickBackupPCUserAgent() // пул агентов BackupPC
        }
        // Несущие команды gRPC: метод вызова, content-type, метаданные.
        req.Header.Set("User-Agent", ua)
        req.Header.Set("Content-Type", "application/grpc")
        req.Header.Set("TE", "trailers")
        req.Header.Set("grpc-accept-encoding", "identity")
        req.Header.Set(hdrSessionID, sessionID)
        req.Header.Set(hdrChunkIndex, strconv.FormatUint(uint64(index), 10))
        // V2 auth (audit 2026-10-13, updated 2026-10-14):
        //   Preferred path (audit 2026-10-14): when UserToken is set,
        //   use token bytes as HMAC key (no SHA256). Server looks up user
        //   by token. VLESS UUID derived = token[:16] server-side.
        //
        //   Legacy path (pre-2026-10-14): when UserToken is empty,
        //   fall back to SHA256(uuid) as HMAC key. Deprecated — kept for
        //   back-compat with already-deployed V2 clients.
        //
        //   V1 path: when UseV2Auth=false OR allowedProtocols=["v1"],
        //   send V1 HMAC (no timestamp, no replay protection).
        if c.cfg.UseV2Auth && !c.isV1Only() {
                tsMin := currentTsMin()
                req.Header.Set(HdrTimestamp, formatTsMinHeader(tsMin))
                if c.cfg.UserToken != "" {
                        // Preferred V2 path: token-based HMAC.
                        authV2, err := BackupAuthHeaderV2FromToken(c.cfg.UserToken, sessionID, index, tsMin)
                        if err != nil {
                                return nil, fmt.Errorf("v2 auth: %w", err)
                        }
                        req.Header.Set(hdrChunkAuth, authV2)
                } else {
                        // Legacy V2 path: UUID-based HMAC (deprecated).
                        req.Header.Set(hdrChunkAuth, BackupAuthHeaderV2(c.cfg.UUID, sessionID, index, tsMin))
                }
        } else {
                req.Header.Set(hdrChunkAuth, BackupAuthHeader(c.uuid, sessionID, index))
        }

        stream := &ChunkStream{pw: pw, mw: newGrpcMsgWriter(pw)}
        emu := NewEmulatedConn(stream, &c.cfg.TransportConfig)

        // RoundTrip запускается параллельно записи VLESS-заголовка: тело запроса
        // (io.Pipe, синхронное) должен читать Transport, пока мы пишем заголовок.
        // Сервер отвечает 200 только после валидного хендшейка (анти-пробинг).
        type rtResult struct {
                resp *http.Response
                err  error
        }
        rtCh := make(chan rtResult, 1)
        go func() {
                resp, err := tr.RoundTrip(req)
                rtCh <- rtResult{resp, err}
        }()

        if len(firstPayload) > 0 {
                if _, werr := emu.Write(firstPayload); werr != nil {
                        pw.CloseWithError(werr)
                        tr.CloseIdleConnections()
                        res := <-rtCh // дождаться горутину RoundTrip
                        if res.resp != nil {
                                res.resp.Body.Close()
                        }
                        return nil, werr
                }
        }

        res := <-rtCh
        if res.err != nil {
                pw.CloseWithError(res.err)
                tr.CloseIdleConnections()
                return nil, fmt.Errorf("chunk dial: %w", res.err)
        }
        resp := res.resp
        if resp.StatusCode != http.StatusOK {
                body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
                resp.Body.Close()
                tr.CloseIdleConnections()
                return nil, fmt.Errorf("chunk dial: статус %d (мимикрия-ответ: %s)",
                        resp.StatusCode, string(body))
        }
        if ct := resp.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(ct, "application/grpc") {
                resp.Body.Close()
                tr.CloseIdleConnections()
                return nil, fmt.Errorf("chunk dial: ответ не gRPC (content-type %q)", ct)
        }
        stream.body = resp.Body
        stream.mr = &grpcMsgReader{r: resp.Body}

        return &ChunkHandle{
                Stream:    stream,
                Transport: tr,
                Emu:       emu,
                index:     index,
        }, nil
}

// spawnJitterKeepAlive — генератор пингов со скользящим джиттером (ТЗ 4.1):
// интервал Base ± Random, payload пустого чанка = padding-only кадр.
func (lc *LogicalConn) spawnJitterKeepAlive() {
        lc.wg.Add(1)
        go func() {
                defer lc.wg.Done()
                for {
                        next := jitterInterval(lc.cfg)
                        select {
                        case <-lc.ctx.Done():
                                return
                        case <-time.After(next):
                        }
                        // пустой DATA-фрейм с паддингом — маскируется под пустой чанк бэкапа
                        if _, err := lc.WritePadding(pingPaddingSize()); err != nil {
                                return // сокет закрыт — тушим горутину (ТЗ 4.1)
                        }
                }
        }()
}

// --- SOCKS5 inbound (front-end) ---

func (c *Client) serveSocks(conn net.Conn) {
        defer conn.Close()
        _ = conn.SetDeadline(time.Now().Add(15 * time.Second))

        // общий буфер: хендшейк + релей (чтобы данные за хендшейком не терялись)
        br := bufio.NewReader(conn)
        addr, port, err := socksHandshake(br, conn)
        if err != nil {
                c.logger.Debug("socks handshake failed", "err", err.Error())
                return
        }

        lc, err := c.DialLogical(addr, port)
        if err != nil {
                c.logger.Warn("logical dial failed", "target", net.JoinHostPort(addr, strconv.Itoa(int(port))), "err", err.Error())
                socksReply(conn, 0x01) // general failure
                return
        }
        defer lc.Close()

        _ = conn.SetDeadline(time.Time{})
        if err := socksReply(conn, 0x00); err != nil {
                return
        }
        c.logger.Info("tunnel established", "target", net.JoinHostPort(addr, strconv.Itoa(int(port))),
                "session", lc.sessionID)

        // релей: upload → HalfClose (graceful), затем добивка download.
        // Пишем через br — буфер bufio мог захватить данные клиента за хендшейком.
        go func() {
                _, _ = io.Copy(lc, br)
                lc.HalfClose()
        }()
        _, _ = io.Copy(conn, lc)
}

// socksHandshake — минимальный SOCKS5 CONNECT (без auth, только TCP).
func socksHandshake(br *bufio.Reader, conn net.Conn) (string, uint16, error) {
        var hdr [2]byte
        if _, err := io.ReadFull(br, hdr[:]); err != nil {
                return "", 0, err
        }
        if hdr[0] != 0x05 {
                return "", 0, errors.New("socks: не SOCKS5")
        }
        methods := make([]byte, hdr[1])
        if _, err := io.ReadFull(br, methods); err != nil {
                return "", 0, err
        }
        hasNoAuth := false
        for _, m := range methods {
                if m == 0x00 {
                        hasNoAuth = true
                }
        }
        if !hasNoAuth {
                _, _ = conn.Write([]byte{0x05, 0xFF})
                return "", 0, errors.New("socks: нет поддерживаемого метода auth")
        }
        if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
                return "", 0, err
        }

        var req [4]byte // VER CMD RSV ATYP
        if _, err := io.ReadFull(br, req[:]); err != nil {
                return "", 0, err
        }
        if req[1] != 0x01 {
                _, _ = conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0}) // command not supported
                return "", 0, errors.New("socks: только CONNECT")
        }
        var host string
        switch req[3] {
        case 0x01: // IPv4
                b := make([]byte, 4)
                if _, err := io.ReadFull(br, b); err != nil {
                        return "", 0, err
                }
                host = net.IP(b).String()
        case 0x03: // домен
                var l [1]byte
                if _, err := io.ReadFull(br, l[:]); err != nil {
                        return "", 0, err
                }
                b := make([]byte, l[0])
                if _, err := io.ReadFull(br, b); err != nil {
                        return "", 0, err
                }
                host = string(b)
        case 0x04: // IPv6
                b := make([]byte, 16)
                if _, err := io.ReadFull(br, b); err != nil {
                        return "", 0, err
                }
                host = net.IP(b).String()
        default:
                return "", 0, errors.New("socks: неизвестный ATYP")
        }
        var pb [2]byte
        if _, err := io.ReadFull(br, pb[:]); err != nil {
                return "", 0, err
        }
        port := binary.BigEndian.Uint16(pb[:])
        return host, port, nil
}

// socksReply — ответ на CONNECT (BND.ADDR = 0.0.0.0:0).
func socksReply(conn net.Conn, code byte) error {
        _, err := conn.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
        return err
}

// SetDialContext — установить кастомный диалер для TCP-соединений к серверу.
// Вызывается из Xray outbound handler (core/outbound/outbound.go) после
// создания клиента: в Process() передаётся internet.Dialer с protect().
//
// На Android: internet.Dialer.Dial → VpnService.protect() →
// трафик туннеля не идёт обратно в TUN (нет петли).
//
// На Linux/desktop: diater=nil → стандартный net.Dialer (backward compat).
func (c *Client) SetDialContext(d func(ctx context.Context, network, addr string) (net.Conn, error)) {
        c.cfg.DialContext = d
}

// SetSidecarAddr — set the local utls-tunnel sidecar address (e.g.
// "127.0.0.1:54321"). When non-empty, DialChunk uses h2c (HTTP/2 over
// cleartext TCP) to talk to the sidecar instead of HTTPS to the server.
//
// The sidecar wraps bytes in uTLS+TLS+ECH+Noise and relays to the real
// server (cfg.ServerAddr). Server sees HTTP/2 inside TLS (single layer).
//
// Called by router's outbound.Handler after spawning utls-tunnel.
// Pass empty string to disable sidecar mode (revert to direct HTTPS).
func (c *Client) SetSidecarAddr(addr string) {
        c.cfg.SidecarAddr = addr
}
