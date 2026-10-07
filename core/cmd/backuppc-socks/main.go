// backuppc-socks — минимальный клиент backuppc: локальный SOCKS5 → туннель.
//
// Без ядра Xray (≈6 МБ против ≈30 МБ): для роутеров, где маршрутизацию по
// доменам и подсетям делает внешний компонент (podkop/sing-box —
// socks5://127.0.0.1:<порт>). Один процесс — один сервер; несколько
// серверов — несколько процессов на разных портах.
//
//	backuppc-socks -link-file /var/run/backuppc-socks/d08.link -listen 127.0.0.1:1080
//	backuppc-socks -check -link-file …   # разобрать ссылку и выйти
//
// Ссылка — backuppc://… из панели сервера (файл с одной строкой: в аргументах
// командной строки UUID был бы виден в ps).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"backuppc"
	"backuppc-core/link"
)

// version подставляется при сборке: -ldflags "-X main.version=…".
var version = "dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "backuppc-socks:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("backuppc-socks", flag.ContinueOnError)
	linkFile := fs.String("link-file", "", "файл со ссылкой backuppc://")
	listen := fs.String("listen", "127.0.0.1:1080", "адрес SOCKS5-входа")
	logLevel := fs.String("loglevel", "warn", "debug|info|warn|error")
	check := fs.Bool("check", false, "только проверить ссылку")
	showVersion := fs.Bool("version", false, "версия")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *showVersion {
		fmt.Println("backuppc-socks", version)
		return nil
	}
	if *linkFile == "" {
		return errors.New("нужен -link-file")
	}
	raw, err := os.ReadFile(*linkFile)
	if err != nil {
		return err
	}
	o, err := link.ParseLink(strings.TrimSpace(string(raw)))
	if err != nil {
		return err
	}
	cfg, err := clientConfig(o, *listen)
	if err != nil {
		return err
	}
	if *check {
		fmt.Printf("ok: сервер %s, SOCKS5 %s\n", cfg.ServerAddr, cfg.SocksListen)
		return nil
	}

	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		return fmt.Errorf("loglevel: %w", err)
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	client, err := backuppc.NewClient(cfg, logger)
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", cfg.SocksListen)
	if err != nil {
		return err
	}
	logger.Warn("backuppc-socks запущен", "version", version, "listen", ln.Addr().String(),
		"server", cfg.ServerAddr, "node", o.Tag)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	err = client.Serve(ln)
	if ctx.Err() != nil {
		logger.Warn("backuppc-socks остановлен")
		return nil
	}
	return err
}

// clientConfig — ссылка → конфиг библиотеки (как ClientConfigFromProto ядра,
// без зависимости от Xray).
func clientConfig(o *link.Outbound, listen string) (*backuppc.ClientConfig, error) {
	host, port, err := net.SplitHostPort(listen)
	if err != nil || port == "" || net.ParseIP(host) == nil {
		return nil, fmt.Errorf("listen: ожидается IP:порт, получено %q", listen)
	}
	c := &backuppc.ClientConfig{
		ServerAddr:      o.ServerAddr,
		UUID:            o.UUID,
		SocksListen:     listen,
		Insecure:        o.Insecure,
		CertFingerprint: strings.ToLower(o.CertFingerprint),
	}
	// пиннинг приоритетнее insecure (библиотека отвергает оба сразу)
	if c.CertFingerprint != "" {
		c.Insecure = false
	}
	t := &c.TransportConfig
	t.Host = o.Host
	t.UserAgent = o.UserAgent
	if len(o.EndpointPaths) > 0 {
		t.EndpointPaths = o.EndpointPaths
	}
	if o.MinPadding != 0 && o.MaxPadding != 0 {
		t.MinPaddingSize, t.MaxPaddingSize = o.MinPadding, o.MaxPadding
	}
	t.ApplyDefaults()
	return c, nil
}
