//go:build darwin || windows

package main

// run и service для macOS/Windows: в отличие от Linux (systemd + отдельный
// backuppc-xray), ядро встроено в backuppc-client, а маршруты и DNS
// TUN-режима ставит сам run (netcfg_*.go) — без shell-скриптов.

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"backuppc-core/preprocess"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

const desktopUsage = `backuppc-client run [-dir DIR] socks|tun          # ядро в консоли (Ctrl+C — стоп)
backuppc-client service install|uninstall|restart|status socks|tun [-dir DIR]
`

// uplinkPoll — период проверки смены сети (Wi-Fi ↔ кабель ↔ модем):
// маршрут до сервера переносится на новый шлюз.
const uplinkPoll = 5 * time.Second

func cmdRun(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	dir := fs.String("dir", defaultDir, "")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("run: %w\n%s", err, desktopUsage)
	}
	mode := fs.Arg(0)
	if fs.NArg() != 1 || (mode != "socks" && mode != "tun") {
		return fmt.Errorf("run: ожидается режим socks или tun\n%s", desktopUsage)
	}
	if handled, err := serviceMain(mode, *dir); handled {
		return err
	}

	stop := make(chan struct{})
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		<-signals
		close(stop)
	}()
	return runMode(*dir, mode, stop, stdout)
}

// runMode запускает ядро в режиме mode до закрытия stop.
func runMode(dir, mode string, stop <-chan struct{}, out io.Writer) error {
	logger := log.New(out, "backuppc-client: ", log.LstdFlags)
	path := filepath.Join(dir, mode+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("%w; выполните backuppc-client import", err)
	}
	if mode == "tun" {
		return runTun(dir, raw, stop, logger)
	}
	inst, err := startCore(raw)
	if err != nil {
		return err
	}
	logger.Printf("SOCKS-режим запущен (%s)", path)
	<-stop
	logger.Print("остановка…")
	return inst.Close()
}

func startCore(config []byte) (*core.Instance, error) {
	patched, replacements, err := preprocess.NormalizeJSON(config)
	if err != nil {
		return nil, err
	}
	coreConfig, err := core.LoadConfig("json", strings.NewReader(string(patched)))
	if err != nil {
		return nil, err
	}
	if err := preprocess.Apply(coreConfig, replacements); err != nil {
		return nil, err
	}
	inst, err := core.New(coreConfig)
	if err != nil {
		return nil, err
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return nil, err
	}
	return inst, nil
}

// tunState — что run tun поменял в системе; лежит в каталоге конфигов,
// чтобы после падения или перезагрузки следующий запуск всё вернул.
type tunState struct {
	Tun      string              `json:"tun"`
	ServerIP string              `json:"serverIP,omitempty"`
	Uplink   *uplink             `json:"uplink,omitempty"`
	DNS      map[string][]string `json:"dns,omitempty"` // macOS: исходные DNS служб
	path     string
}

func loadState(dir string) *tunState {
	st := &tunState{path: filepath.Join(dir, "tun-state.json")}
	if b, err := os.ReadFile(st.path); err == nil {
		_ = json.Unmarshal(b, st)
	}
	return st
}

func (st *tunState) save() error {
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(st.path, append(b, '\n'), 0o600)
}

// revert снимает всё, что записано в состоянии.
func (st *tunState) revert(logger *log.Logger) {
	if st.ServerIP != "" && st.Uplink != nil {
		if ip, err := netip.ParseAddr(st.ServerIP); err == nil {
			delServerRoute(ip, *st.Uplink)
		}
	}
	if st.Tun != "" {
		tunDown(st, logger)
	}
	st.ServerIP, st.Uplink, st.DNS = "", nil, nil
	_ = os.Remove(st.path)
}

func runTun(dir string, raw []byte, stop <-chan struct{}, logger *log.Logger) error {
	if err := requireAdmin(); err != nil {
		return err
	}
	unlock, err := lockTun(dir)
	if err != nil {
		return err
	}
	defer unlock()
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return fmt.Errorf("tun.json: %w", err)
	}
	plan, err := parseTunConfig(cfg)
	if err != nil {
		return err
	}

	// следы прошлого запуска (падение, перезагрузка) — до чтения таблиц
	if prev := loadState(dir); prev.Tun != "" {
		logger.Print("снимаю настройки прошлого запуска")
		prev.revert(logger)
	}

	up4, err4 := findUplink(false, plan.Name)
	up6, err6 := findUplink(true, plan.Name)
	if err4 != nil && err6 != nil {
		return fmt.Errorf("нет маршрута по умолчанию (сеть не подключена?): %v", err4)
	}
	ips, err := resolveServer(plan.ServerHost)
	if err != nil {
		return err
	}
	ip, err := pickServerIP(ips, err4 == nil, err6 == nil)
	if err != nil {
		return err
	}
	// маршрут до сервера — тот, что выбрала ОС (шлюз по умолчанию или LAN);
	// при смене сети (другой default) он пересчитывается
	def := up4
	if ip.Is6() {
		def = up6
	}
	u, err := findRoute(ip, plan.Name)
	if err != nil {
		return err
	}
	pinServer(cfg, plan, ip)
	pinned, err := json.Marshal(cfg)
	if err != nil {
		return err
	}

	inst, err := startTunCore(pinned, stop, logger)
	if err != nil {
		return err
	}
	st := loadState(dir)
	st.Tun = plan.Name
	teardown := func() {
		st.revert(logger)
		_ = inst.Close()
	}
	if err := addServerRoute(ip, u); err != nil {
		teardown()
		return fmt.Errorf("маршрут до сервера: %w", err)
	}
	st.ServerIP, st.Uplink = ip.String(), &u
	if err := st.save(); err != nil {
		teardown()
		return err
	}
	if err := tunUp(plan, st, logger); err != nil {
		teardown()
		return err
	}
	logger.Printf("TUN %s: весь трафик через туннель; сервер %s через %s, DNS → %s",
		plan.Name, ip, u, strings.Join(plan.DNS, ", "))

	ticker := time.NewTicker(uplinkPoll)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			logger.Print("остановка…")
			teardown()
			return nil
		case <-ticker.C:
			nd, err := findUplink(ip.Is6(), plan.Name)
			if err != nil || nd == def {
				continue // сети нет — ждём; маршрут прежний
			}
			// свой host-маршрут снимается, чтобы ОС выбрала путь заново
			delServerRoute(ip, u)
			nu, err := findRoute(ip, plan.Name)
			if err == nil {
				err = addServerRoute(ip, nu)
			}
			if err != nil {
				logger.Printf("смена сети: маршрут до сервера: %v (повтор через %s)", err, uplinkPoll)
				_ = addServerRoute(ip, u)
				continue
			}
			logger.Printf("смена сети: сервер %s теперь через %s", ip, nu)
			def, u = nd, nu
			st.Uplink = &u
			_ = st.save()
		}
	}
}

// startTunCore — ядро с TUN-интерфейсом. Сразу после остановки прошлого
// запуска ОС может ещё удалять старый интерфейс (Windows: «файл уже
// существует»), поэтому старт повторяется до ~30 с.
func startTunCore(config []byte, stop <-chan struct{}, logger *log.Logger) (*core.Instance, error) {
	const attempts = 10
	for i := 1; ; i++ {
		inst, err := startCore(config)
		if err == nil || i == attempts {
			return inst, err
		}
		logger.Printf("TUN-интерфейс не создан (%v), повтор %d/%d через 3 с", err, i, attempts-1)
		select {
		case <-stop:
			return nil, err
		case <-time.After(3 * time.Second):
		}
	}
}

// resolveServer — адрес сервера через системный DNS; вызывается до того,
// как DNS системы направлен в туннель.
func resolveServer(host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{ip}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, fmt.Errorf("адрес сервера %s: %w", host, err)
	}
	return ips, nil
}

// serviceArgs — «service ACTION MODE [-dir DIR]» (флаг допускается и до
// действия).
func serviceArgs(args []string) (action, mode, dir string, err error) {
	fs := flag.NewFlagSet("service", flag.ContinueOnError)
	d := fs.String("dir", defaultDir, "")
	fs.SetOutput(io.Discard)
	var pos []string
	for len(args) > 0 {
		if err := fs.Parse(args); err != nil {
			return "", "", "", fmt.Errorf("service: %w\n%s", err, desktopUsage)
		}
		args = fs.Args()
		if len(args) > 0 {
			pos = append(pos, args[0])
			args = args[1:]
		}
	}
	if len(pos) != 2 {
		return "", "", "", fmt.Errorf("service: ожидается действие и режим\n%s", desktopUsage)
	}
	action, mode = pos[0], pos[1]
	switch action {
	case "install", "uninstall", "restart", "status":
	default:
		return "", "", "", fmt.Errorf("service: неизвестное действие %q\n%s", action, desktopUsage)
	}
	if mode != "socks" && mode != "tun" {
		return "", "", "", fmt.Errorf("service: режим socks или tun, получено %q", mode)
	}
	return action, mode, *d, nil
}

// serviceExecutable — путь бинарника для службы (без симлинков: служба
// должна пережить переустановку по тому же пути).
func serviceExecutable() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return exe, nil
}

func requireConfig(dir, mode string) error {
	if _, err := os.Stat(filepath.Join(dir, mode+".json")); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("нет %s в %s — сначала backuppc-client import", mode+".json", dir)
		}
		return err
	}
	return nil
}
