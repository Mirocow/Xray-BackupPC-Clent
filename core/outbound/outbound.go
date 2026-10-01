// Package outbound — протокол backuppc как нативный outbound Xray.
//
// Handler регистрируется в реестре ядра через common.RegisterConfig
// (protobuf-тип backuppc.Config) и реализует proxy.Outbound: диспетчер
// Xray направляет ему соединения по тегу исходящего, handler открывает
// логическую сессию транспортной библиотеки (VLESS поверх чанков
// gRPC-канала с маскировкой BackupPC) и прокачивает оба плеча.
package outbound

import (
	"context"
	"log/slog"
	"time"

	"backuppc"
	backuppcpb "backuppc-core/backuppcpb"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal"
	"github.com/xtls/xray-core/common/task"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
)

func init() {
	// Регистрация креатора: core.OutboundHandlerConfig.ProxySettings
	// (serial.TypedMessage на backuppc.Config) материализуется в Handler.
	common.Must(common.RegisterConfig((*backuppcpb.Config)(nil),
		func(ctx context.Context, config interface{}) (interface{}, error) {
			return New(ctx, config.(*backuppcpb.Config))
		}))
}

// defaultIdleTimeout — запасной таймаут простоя, если приложение policy
// не зарегистрировано (минимальные конфиги тестов).
const defaultIdleTimeout = 5 * time.Minute

// Handler — outbound-протокол backuppc для ядра Xray.
type Handler struct {
	client    *backuppc.Client
	logger    *slog.Logger
	idleCache time.Duration
	idleOnce  bool
}

// New создает handler и транспортного клиента библиотеки.
func New(ctx context.Context, config *backuppcpb.Config) (*Handler, error) {
	if config == nil {
		return nil, errors.New("backuppc: nil config")
	}
	ccfg := ClientConfigFromProto(config)
	logger := slog.Default().With("component", "backuppc-outbound")
	client, err := backuppc.NewClient(ccfg, logger)
	if err != nil {
		return nil, errors.New(ctx, "backuppc: некорректный конфиг outbound").Base(err)
	}
	h := &Handler{client: client, logger: logger}
	if v := core.FromContext(ctx); v != nil {
		if f := v.GetFeature(policy.ManagerType()); f != nil {
			if pm, ok := f.(policy.Manager); ok {
				h.idleCache = pm.ForLevel(0).Timeouts.ConnectionIdle
				h.idleOnce = true
			}
		}
	}
	logger.Info("backuppc outbound registered",
		"server", ccfg.ServerAddr, "host", ccfg.Host)
	return h, nil
}

// idleTimeout возвращает таймаут простоя соединения.
func (h *Handler) idleTimeout() time.Duration {
	if h.idleOnce {
		return h.idleCache
	}
	return defaultIdleTimeout
}

// Process implements proxy.Outbound.
func (h *Handler) Process(ctx context.Context, link *transport.Link, dialer internet.Dialer) error {
	outbounds := session.OutboundsFromContext(ctx)
	ob := outbounds[len(outbounds)-1]
	if !ob.Target.IsValid() {
		return errors.New("backuppc: target not specified.")
	}
	ob.Name = "backuppc"
	// 3 = cannot: LogicalConn — кодек поверх кадров, splice-copy невозможен.
	ob.CanSpliceCopy = 3
	target := ob.Target
	if target.Network == net.Network_UDP {
		return errors.New(ctx, "backuppc: UDP не поддерживается outbound-протоколом")
	}

	conn, err := h.client.DialLogical(target.Address.String(), uint16(target.Port))
	if err != nil {
		return errors.New(ctx, "backuppc: не удалось открыть сессию к ", target.NetAddr()).Base(err)
	}
	defer func() {
		if err := conn.Close(); err != nil {
			errors.LogInfoInner(ctx, err, "backuppc: закрытие сессии")
		}
	}()

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	idle := h.idleTimeout()
	timer := signal.CancelAfterInactivity(ctx, func() {
		cancel()
		conn.Close()
	}, idle)
	defer timer.SetTimeout(time.Hour) // финальное окно на разбор рукопожатий

	requestFunc := func() error {
		defer timer.SetTimeout(idle)
		err := buf.Copy(link.Reader, buf.NewWriter(conn), buf.UpdateActivity(timer))
		// Upload-плечо иссякло (входящее соединение закрыто или ожидает
		// только ответа): полузакрытие логической сессии — сервер видит
		// маркер EOF, добивает download-очередь и завершает сессию.
		if herr := conn.HalfClose(); herr != nil {
			errors.LogDebugInner(ctx, herr, "backuppc: half-close")
		}
		return err
	}
	responseFunc := func() error {
		defer timer.SetTimeout(idle)
		return buf.Copy(buf.NewReader(conn), link.Writer, buf.UpdateActivity(timer))
	}
	responseDonePost := task.OnSuccess(responseFunc, task.Close(link.Writer))
	if err := task.Run(ctx, requestFunc, responseDonePost); err != nil {
		return errors.New(ctx, "backuppc: соединение завершено").Base(err)
	}
	return nil
}

// Close — остановка handler (интерфейс common.Closable для полноты).
func (h *Handler) Close() error { return nil }
