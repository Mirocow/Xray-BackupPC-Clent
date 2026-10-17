package main

// Маршруты и DNS TUN-режима на Windows: netsh (маршруты — store=active,
// исчезают при перезагрузке) и PowerShell Get-NetRoute для поиска шлюза.
// Адаптер Wintun создаёт ядро Xray (proxy/tun/tun_windows.go, wintun.dll
// рядом с exe) и удаляет при выходе — вместе с его адресами и маршрутами.

import (
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

func sh(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err,
			strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func netsh(args ...string) error {
	_, err := sh("netsh", args...)
	return err
}

func requireAdmin() error {
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("TUN-режим требует прав администратора: запустите консоль «от имени администратора»")
	}
	return nil
}

// psUplink — default-маршрут с наименьшей суммарной метрикой, кроме
// собственного адаптера; вывод «NextHop InterfaceIndex InterfaceAlias».
const psUplink = `$r = Get-NetRoute -AddressFamily %s -DestinationPrefix '%s' -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
  Where-Object { $_.InterfaceAlias -ne '%s' } |
  Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
if ($r) { "$($r.NextHop) $($r.InterfaceIndex) $($r.InterfaceAlias)" }`

func findUplink(v6 bool, skipIface string) (uplink, error) {
	family, prefix := "IPv4", "0.0.0.0/0"
	if v6 {
		family, prefix = "IPv6", "::/0"
	}
	script := fmt.Sprintf(psUplink, family, prefix, skipIface)
	out, err := sh("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	if err != nil {
		return uplink{}, err
	}
	u, ok := parsePSUplink(out)
	if !ok {
		return uplink{}, fmt.Errorf("нет default-маршрута %s", family)
	}
	return u, nil
}

// psRoute — маршрут, который Windows выбрала бы до ip (Find-NetRoute
// возвращает адрес-источник и маршрут; у маршрута есть NextHop).
const psRoute = `$r = Find-NetRoute -RemoteIPAddress '%s' -ErrorAction SilentlyContinue |
  Where-Object { $_.NextHop -ne $null } | Select-Object -First 1
if ($r) { "$($r.NextHop) $($r.InterfaceIndex) $($r.InterfaceAlias)" }`

func findRoute(ip netip.Addr, skipIface string) (uplink, error) {
	out, err := sh("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", fmt.Sprintf(psRoute, ip))
	if err != nil {
		return uplink{}, err
	}
	u, ok := parsePSUplink(out)
	if !ok || u.Iface == skipIface {
		return uplink{}, fmt.Errorf("нет маршрута до %s мимо %s", ip, skipIface)
	}
	return u, nil
}

func ipContext(ip netip.Addr) (string, string) {
	if ip.Is6() {
		return "ipv6", ip.String() + "/128"
	}
	return "ipv4", ip.String() + "/32"
}

func routeArgs(action string, ip netip.Addr, u uplink) []string {
	ctx, prefix := ipContext(ip)
	args := []string{"interface", ctx, action, "route", "prefix=" + prefix,
		"interface=" + strconv.Itoa(u.Index)}
	if u.Gateway != "" {
		args = append(args, "nexthop="+u.Gateway)
	}
	if action == "add" {
		args = append(args, "metric=1")
	}
	return append(args, "store=active")
}

func addServerRoute(ip netip.Addr, u uplink) error {
	delServerRoute(ip, u)
	return netsh(routeArgs("add", ip, u)...)
}

func delServerRoute(ip netip.Addr, u uplink) {
	_ = netsh(routeArgs("delete", ip, u)...)
}

// tunIndex ждёт появления адаптера Wintun (создаётся ядром при старте).
func tunIndex(name string) (string, error) {
	deadline := time.Now().Add(15 * time.Second)
	for {
		ifc, err := net.InterfaceByName(name)
		if err == nil {
			return strconv.Itoa(ifc.Index), nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("адаптер %s не появился за 15 с: %w", name, err)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// retry — netsh может отказать, пока адаптер только что создан.
func retry(f func() error) error {
	var err error
	for i := 0; i < 10; i++ {
		if err = f(); err == nil {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return err
}

func tunUp(p *tunPlan, _ *tunState, logger *log.Logger) error {
	idx, err := tunIndex(p.Name)
	if err != nil {
		return err
	}
	steps := [][]string{
		{"interface", "ipv4", "set", "address", "name=" + idx, "source=static",
			"address=" + tunAddr4, "mask=" + tunMask4, "gateway=none"},
		{"interface", "ipv4", "set", "interface", "interface=" + idx, "metric=1"},
	}
	for _, r := range splitRoutes4 {
		steps = append(steps, []string{"interface", "ipv4", "add", "route", "prefix=" + r,
			"interface=" + idx, "metric=1", "store=active"})
	}
	for i, d := range p.DNS {
		if i == 0 {
			steps = append(steps, []string{"interface", "ipv4", "set", "dnsservers", "name=" + idx,
				"source=static", "address=" + d, "register=none", "validate=no"})
		} else {
			steps = append(steps, []string{"interface", "ipv4", "add", "dnsservers", "name=" + idx,
				"address=" + d, "index=" + strconv.Itoa(i+1), "validate=no"})
		}
	}
	for _, s := range steps {
		if err := retry(func() error { return netsh(s...) }); err != nil {
			return err
		}
	}
	// IPv6 — по возможности, как на Linux/macOS
	addr6 := fmt.Sprintf("address=%s/%d", tunAddr6, tunPrefix6)
	if err := netsh("interface", "ipv6", "add", "address", "interface="+idx, addr6, "store=active"); err != nil {
		logger.Printf("IPv6 на %s недоступен (%v) — только IPv4", p.Name, err)
	} else {
		_ = netsh("interface", "ipv6", "set", "interface", "interface="+idx, "metric=1")
		for _, r := range splitRoutes6 {
			if err := netsh("interface", "ipv6", "add", "route", "prefix="+r, "interface="+idx,
				"metric=1", "store=active"); err != nil {
				logger.Printf("IPv6-маршрут %s: %v", r, err)
			}
		}
	}
	_, _ = sh("ipconfig", "/flushdns")
	return nil
}

// tunDown — маршруты адаптера исчезают вместе с ним; удаляем явно на случай,
// если адаптер пережил процесс (ядро открывает существующий по имени).
func tunDown(st *tunState, _ *log.Logger) {
	ifc, err := net.InterfaceByName(st.Tun)
	if err != nil {
		return
	}
	idx := strconv.Itoa(ifc.Index)
	for _, r := range splitRoutes4 {
		_ = netsh("interface", "ipv4", "delete", "route", "prefix="+r, "interface="+idx, "store=active")
	}
	for _, r := range splitRoutes6 {
		_ = netsh("interface", "ipv6", "delete", "route", "prefix="+r, "interface="+idx, "store=active")
	}
	_, _ = sh("ipconfig", "/flushdns")
}

// lockTun — один TUN-запуск на каталог конфигов: второй снял бы маршруты
// первого. Блокировка файла снимается ОС и при падении процесса.
func lockTun(dir string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(dir, "tun.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	ol := new(windows.Overlapped)
	err = windows.LockFileEx(windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol)
	if err != nil {
		f.Close()
		return nil, errors.New("TUN-режим уже запущен (служба или другая консоль)")
	}
	return func() { f.Close() }, nil
}
