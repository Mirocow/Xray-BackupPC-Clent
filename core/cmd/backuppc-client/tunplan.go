package main

// Платформонезависимая часть TUN-режима macOS/Windows (run tun): разбор
// tun.json, закрепление адреса сервера и разбор таблиц маршрутов ОС.
// Лежит без build-тегов, чтобы тесты шли на Linux.

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// Адреса TUN-интерфейса (как в deploy/linux/tun-routes): 198.18.0.0/15 —
// RFC 2544, DHCP и Docker его не выдают.
const (
	tunAddr4   = "198.18.0.1"
	tunMask4   = "255.255.255.252"
	tunAddr6   = "fdfe:dcba:9876::1"
	tunPrefix6 = 126
)

// Полумаршруты «всё в туннель»: точнее default, но не заменяют его — исходный
// default остаётся и показывает настоящий шлюз (так делают OpenVPN и wg-quick).
var (
	splitRoutes4 = []string{"0.0.0.0/1", "128.0.0.0/1"}
	splitRoutes6 = []string{"::/1", "8000::/1"}
)

// tunPlan — то, что run tun берёт из tun.json.
type tunPlan struct {
	Name       string   // имя TUN-интерфейса
	DNS        []string // IP DNS-серверов (система направляется на них)
	ServerHost string   // адрес сервера из ссылки (домен или IP)
	ServerPort string
}

// parseTunConfig разбирает tun.json, сгенерированный import.
func parseTunConfig(cfg map[string]any) (*tunPlan, error) {
	p := &tunPlan{}
	for _, in := range asSlice(cfg["inbounds"]) {
		m, _ := in.(map[string]any)
		if m["protocol"] == "tun" {
			s, _ := m["settings"].(map[string]any)
			p.Name, _ = s["name"].(string)
		}
	}
	if p.Name == "" {
		return nil, errors.New("tun.json: нет tun-inbound с именем интерфейса")
	}
	if dns, ok := cfg["dns"].(map[string]any); ok {
		for _, s := range asSlice(dns["servers"]) {
			if v, ok := s.(string); ok {
				p.DNS = append(p.DNS, strings.TrimPrefix(v, "tcp://"))
			}
		}
	}
	if len(p.DNS) == 0 {
		return nil, errors.New("tun.json: нет DNS-серверов")
	}
	s := proxySettings(cfg)
	if s == nil {
		return nil, errors.New("tun.json: нет backuppc-outbound с тегом " + tagProxy)
	}
	addr, _ := s["serverAddr"].(string)
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, fmt.Errorf("tun.json: serverAddr %q: %w", addr, err)
	}
	p.ServerHost, p.ServerPort = host, port
	return p, nil
}

// pinServer подставляет в backuppc-outbound IP сервера, разрешённый до
// перенастройки DNS: иначе при переподключении ядро резолвило бы адрес
// через DNS, который сам идёт в туннель (петля). Домен из ссылки остаётся
// в host (SNI и Host-заголовок), если в ссылке не было своего host.
func pinServer(cfg map[string]any, p *tunPlan, ip netip.Addr) {
	s := proxySettings(cfg)
	s["serverAddr"] = net.JoinHostPort(ip.String(), p.ServerPort)
	if h, _ := s["host"].(string); h == "" {
		if _, err := netip.ParseAddr(p.ServerHost); err != nil {
			s["host"] = p.ServerHost
		}
	}
}

func proxySettings(cfg map[string]any) map[string]any {
	for _, o := range asSlice(cfg["outbounds"]) {
		m, _ := o.(map[string]any)
		if m["tag"] == tagProxy {
			s, _ := m["settings"].(map[string]any)
			return s
		}
	}
	return nil
}

func asSlice(v any) []any {
	s, _ := v.([]any)
	return s
}

// pickServerIP — IPv4, если есть IPv4-аплинк, иначе IPv6.
func pickServerIP(ips []netip.Addr, have4, have6 bool) (netip.Addr, error) {
	for _, want4 := range []bool{true, false} {
		if (want4 && !have4) || (!want4 && !have6) {
			continue
		}
		for _, ip := range ips {
			ip = ip.Unmap()
			if ip.Is4() == want4 {
				return ip, nil
			}
		}
	}
	return netip.Addr{}, fmt.Errorf("нет адреса сервера для доступных сетей (адреса: %v)", ips)
}

// uplink — интерфейс маршрута по умолчанию, через который ядро ходит к
// серверу. Gateway пуст для маршрутов on-link (PPP, некоторые модемы).
type uplink struct {
	Gateway string `json:"gateway"`
	Iface   string `json:"iface"`
	Index   int    `json:"index,omitempty"` // Windows: InterfaceIndex
}

func (u uplink) String() string {
	if u.Gateway == "" {
		return u.Iface
	}
	return u.Gateway + " (" + u.Iface + ")"
}

// parseNetstatDefault — первый default-маршрут из `netstat -rn -f inet|inet6`
// (macOS), кроме маршрутов через skipIface. Колонка Netif ищется по
// заголовку: её позиция разная в версиях macOS.
func parseNetstatDefault(out, skipIface string) (uplink, bool) {
	netif := -1
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 0 {
			continue
		}
		if f[0] == "Destination" {
			netif = -1
			for i, name := range f {
				if name == "Netif" {
					netif = i
				}
			}
			continue
		}
		if f[0] != "default" || netif < 0 || len(f) <= netif {
			continue
		}
		u := uplink{Gateway: f[1], Iface: f[netif]}
		if u.Iface == skipIface {
			continue
		}
		if strings.HasPrefix(u.Gateway, "link#") {
			u.Gateway = ""
		}
		// fe80::1%en0 — зона уже в адресе; route add понимает такую запись
		return u, true
	}
	return uplink{}, false
}

// parseRouteGet — вывод `route -n get <ip>` (macOS): «gateway:» есть только
// у маршрутов через шлюз, у on-link — только «interface:».
func parseRouteGet(out string) (uplink, bool) {
	var u uplink
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "gateway":
			u.Gateway = strings.TrimSpace(v)
		case "interface":
			u.Iface = strings.TrimSpace(v)
		}
	}
	return u, u.Iface != ""
}

// parsePSUplink — вывод однострочника PowerShell «NextHop Index Alias»
// (см. findUplink в netcfg_windows.go). Alias может содержать пробелы.
func parsePSUplink(out string) (uplink, bool) {
	line := strings.TrimSpace(out)
	f := strings.SplitN(line, " ", 3)
	if len(f) < 3 {
		return uplink{}, false
	}
	idx, err := strconv.Atoi(f[1])
	if err != nil || idx <= 0 {
		return uplink{}, false
	}
	u := uplink{Gateway: f[0], Index: idx, Iface: strings.TrimSpace(f[2])}
	if u.Gateway == "0.0.0.0" || u.Gateway == "::" {
		u.Gateway = ""
	}
	return u, true
}

// parseDNSList — IP из вывода networksetup -getdnsservers; сообщение
// «There aren't any DNS Servers set…» (любая локализация) → Empty.
func parseDNSList(out string) []string {
	var ips []string
	for _, line := range strings.Split(out, "\n") {
		if ip, err := netip.ParseAddr(strings.TrimSpace(line)); err == nil {
			ips = append(ips, ip.String())
		}
	}
	if len(ips) == 0 {
		return []string{"Empty"}
	}
	return ips
}
