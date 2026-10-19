package main

// Маршруты и DNS TUN-режима на macOS: route/ifconfig/networksetup (как
// wg-quick для darwin). utun и его IPv4-адрес (169.254.10.1) создаёт ядро
// Xray (proxy/tun/tun_darwin.go).

import (
	"errors"
	"fmt"
	"log"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

func sh(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err,
			strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func requireAdmin() error {
	if os.Geteuid() != 0 {
		return errors.New("TUN-режим требует root: sudo backuppc-client …")
	}
	return nil
}

func findUplink(v6 bool, skipIface string) (uplink, error) {
	family := "inet"
	if v6 {
		family = "inet6"
	}
	out, err := sh("netstat", "-rn", "-f", family)
	if err != nil {
		return uplink{}, err
	}
	u, ok := parseNetstatDefault(out, skipIface)
	if !ok {
		return uplink{}, fmt.Errorf("нет default-маршрута %s", family)
	}
	return u, nil
}

// findRoute — текущий маршрут ОС до ip (`route -n get`): сервер может быть
// и в локальной сети, не только за шлюзом по умолчанию.
func findRoute(ip netip.Addr, skipIface string) (uplink, error) {
	out, err := sh("route", "-n", "get", inetFlag(ip), ip.String())
	if err != nil {
		return uplink{}, err
	}
	u, ok := parseRouteGet(out)
	if !ok || u.Iface == skipIface {
		return uplink{}, fmt.Errorf("нет маршрута до %s мимо %s", ip, skipIface)
	}
	return u, nil
}

func inetFlag(ip netip.Addr) string {
	if ip.Is6() {
		return "-inet6"
	}
	return "-inet"
}

func addServerRoute(ip netip.Addr, u uplink) error {
	delServerRoute(ip, u)
	args := []string{"-q", "-n", "add", inetFlag(ip), "-host", ip.String()}
	if u.Gateway != "" {
		args = append(args, u.Gateway)
	} else {
		args = append(args, "-interface", u.Iface)
	}
	_, err := sh("route", args...)
	return err
}

func delServerRoute(ip netip.Addr, _ uplink) {
	_, _ = sh("route", "-q", "-n", "delete", inetFlag(ip), "-host", ip.String())
}

func tunUp(p *tunPlan, st *tunState, logger *log.Logger) error {
	for _, r := range splitRoutes4 {
		if _, err := sh("route", "-q", "-n", "add", "-inet", r, "-interface", p.Name); err != nil {
			return err
		}
	}
	// IPv6 — по возможности: без адреса на utun маршруты не ставятся, и
	// IPv6-трафик (если он есть у провайдера) пойдёт мимо туннеля
	addr6 := fmt.Sprintf("%s/%d", tunAddr6, tunPrefix6)
	if _, err := sh("ifconfig", p.Name, "inet6", addr6, "alias"); err != nil {
		logger.Printf("IPv6 на %s недоступен (%v) — только IPv4", p.Name, err)
	} else {
		for _, r := range splitRoutes6 {
			if _, err := sh("route", "-q", "-n", "add", "-inet6", r, "-interface", p.Name); err != nil {
				logger.Printf("IPv6-маршрут %s: %v", r, err)
			}
		}
	}
	return setDNS(st, p.DNS)
}

func tunDown(st *tunState, logger *log.Logger) {
	restoreDNS(st, logger)
	for _, r := range splitRoutes4 {
		_, _ = sh("route", "-q", "-n", "delete", "-inet", r, "-interface", st.Tun)
	}
	for _, r := range splitRoutes6 {
		_, _ = sh("route", "-q", "-n", "delete", "-inet6", r, "-interface", st.Tun)
	}
}

// networkServices — сетевые службы (Wi-Fi, Ethernet…), кроме отключённых
// («*» в начале строки); первая строка вывода — пояснение.
func networkServices() ([]string, error) {
	out, err := sh("networksetup", "-listallnetworkservices")
	if err != nil {
		return nil, err
	}
	var svcs []string
	for i, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if i == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		svcs = append(svcs, line)
	}
	return svcs, nil
}

// setDNS направляет DNS всех служб на серверы туннеля; исходные значения
// сначала сохраняются в состоянии («Empty» — DNS от DHCP).
func setDNS(st *tunState, servers []string) error {
	svcs, err := networkServices()
	if err != nil {
		return err
	}
	if st.DNS == nil {
		st.DNS = map[string][]string{}
	}
	for _, svc := range svcs {
		out, err := sh("networksetup", "-getdnsservers", svc)
		if err != nil {
			continue
		}
		if _, saved := st.DNS[svc]; !saved {
			st.DNS[svc] = parseDNSList(out)
		}
	}
	if err := st.save(); err != nil {
		return err
	}
	for svc := range st.DNS {
		if _, err := sh("networksetup", append([]string{"-setdnsservers", svc}, servers...)...); err != nil {
			return err
		}
	}
	flushDNS()
	return nil
}

func restoreDNS(st *tunState, logger *log.Logger) {
	for svc, list := range st.DNS {
		if _, err := sh("networksetup", append([]string{"-setdnsservers", svc}, list...)...); err != nil {
			logger.Printf("DNS службы %q не восстановлен: %v", svc, err)
		}
	}
	if len(st.DNS) > 0 {
		flushDNS()
	}
}

func flushDNS() {
	_, _ = sh("dscacheutil", "-flushcache")
	_, _ = sh("killall", "-HUP", "mDNSResponder")
}

// lockTun — один TUN-запуск на каталог конфигов: второй снял бы маршруты и
// DNS первого. flock снимается ядром ОС и при падении процесса.
func lockTun(dir string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(dir, "tun.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("TUN-режим уже запущен (служба или другая консоль)")
	}
	return func() { f.Close() }, nil
}
