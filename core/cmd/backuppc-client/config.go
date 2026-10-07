package main

import (
	"fmt"
	"net"
	"strings"

	"backuppc-core/link"
)

// Profile — параметры генерации конфигов клиента (флаги import).
type Profile struct {
	SocksListen string   // host:port SOCKS5-входа
	TunName     string   // имя TUN-интерфейса
	TunMTU      int      // MTU TUN-интерфейса
	DNS         []string // IP DNS-серверов, опрашиваются по TCP через туннель
	LogLevel    string   // debug|info|warning|error|none
}

// Теги, на которые опираются правила маршрутизации.
const (
	tagProxy  = "proxy"
	tagDirect = "direct"
	tagBlock  = "block"
	tagDNSOut = "dns-out"
	tagDNSIn  = "dns-internal"
	tagSocks  = "socksIn"
	tagTun    = "tunIn"
)

// loopbackCIDRs — адреса самого клиента: напрямую, иначе сервер дозвонился
// бы до собственного localhost. Частные сети (10/8, 192.168/16…) идут в
// туннель: за сервером могут быть внутренние сети; LAN клиента в TUN-режиме
// и так остаётся мимо туннеля (tun-routes: suppress_prefixlength 0).
var loopbackCIDRs = []string{"127.0.0.0/8", "::1/128"}

// logSection — журнал ядра. Access-лог (каждое соединение с адресом
// назначения — история посещений в journald) пишется только при debug.
func logSection(p Profile) map[string]any {
	log := map[string]any{"loglevel": p.LogLevel}
	if p.LogLevel != "debug" {
		log["access"] = "none"
	}
	return log
}

func (p Profile) validate() error {
	host, port, err := net.SplitHostPort(p.SocksListen)
	if err != nil || port == "" {
		return fmt.Errorf("socks: ожидается host:port, получено %q", p.SocksListen)
	}
	if net.ParseIP(host) == nil {
		return fmt.Errorf("socks: адрес %q должен быть IP", host)
	}
	if p.TunName == "" || len(p.TunName) > 15 || strings.ContainsAny(p.TunName, " /") {
		return fmt.Errorf("tun: некорректное имя интерфейса %q", p.TunName)
	}
	if p.TunMTU < 576 || p.TunMTU > 9000 {
		return fmt.Errorf("tun: MTU %d вне диапазона 576..9000", p.TunMTU)
	}
	if len(p.DNS) == 0 {
		return fmt.Errorf("dns: нужен хотя бы один сервер")
	}
	for _, s := range p.DNS {
		if net.ParseIP(s) == nil {
			return fmt.Errorf("dns: %q не IP-адрес", s)
		}
	}
	return nil
}

// proxyOutbound — backuppc-outbound из ссылки с фиксированным тегом.
func proxyOutbound(o *link.Outbound) map[string]any {
	out := o.OutboundJSON()
	out["tag"] = tagProxy
	return out
}

func baseOutbounds(o *link.Outbound) []any {
	return []any{
		proxyOutbound(o), // первый — дефолтный маршрут
		map[string]any{"tag": tagDirect, "protocol": "freedom"},
		map[string]any{"tag": tagBlock, "protocol": "blackhole"},
	}
}

// SocksConfig — локальный SOCKS5 → backuppc. UDP выключен: протокол
// переносит только TCP.
func SocksConfig(o *link.Outbound, p Profile) map[string]any {
	host, port, _ := net.SplitHostPort(p.SocksListen)
	var portNum int
	fmt.Sscan(port, &portNum)
	return map[string]any{
		"log": logSection(p),
		"inbounds": []any{map[string]any{
			"tag": tagSocks, "protocol": "socks",
			"listen": host, "port": portNum,
			"settings": map[string]any{"auth": "noauth", "udp": false},
		}},
		"outbounds": baseOutbounds(o),
		"routing": map[string]any{
			"rules": []any{
				map[string]any{"ip": loopbackCIDRs, "outboundTag": tagDirect},
			},
		},
	}
}

// TunConfig — TUN-интерфейс → backuppc. Маршруты и DNS на интерфейсе
// ставит tun-routes (Xray поднимает только сам интерфейс).
//
// DNS: запросы на порт 53 перехватываются dns-outbound и решаются
// встроенным DNS Xray по TCP через туннель. Прочий UDP (QUIC и т.п.)
// блокируется — протокол переносит только TCP, клиенты откатываются на TCP.
func TunConfig(o *link.Outbound, p Profile) map[string]any {
	servers := make([]any, 0, len(p.DNS))
	for _, s := range p.DNS {
		servers = append(servers, "tcp://"+s)
	}
	outbounds := append(baseOutbounds(o),
		map[string]any{"tag": tagDNSOut, "protocol": "dns",
			"settings": map[string]any{"nonIPQuery": "reject"}})
	return map[string]any{
		"log": logSection(p),
		"dns": map[string]any{"tag": tagDNSIn, "servers": servers},
		"inbounds": []any{map[string]any{
			"tag": tagTun, "protocol": "tun", "port": 0,
			"settings": map[string]any{"name": p.TunName, "MTU": p.TunMTU},
		}},
		"outbounds": outbounds,
		"routing": map[string]any{
			"rules": []any{
				map[string]any{"inboundTag": []any{tagDNSIn}, "outboundTag": tagProxy},
				map[string]any{"inboundTag": []any{tagTun}, "network": "udp", "port": 53, "outboundTag": tagDNSOut},
				map[string]any{"ip": loopbackCIDRs, "outboundTag": tagDirect},
				map[string]any{"network": "udp", "outboundTag": tagBlock},
			},
		},
	}
}

// TunEnv — параметры для tun-routes (shell, source).
func TunEnv(o *link.Outbound, p Profile) string {
	host, _, err := net.SplitHostPort(o.ServerAddr)
	if err != nil {
		host = o.ServerAddr
	}
	return fmt.Sprintf("# сгенерировано backuppc-client import — не править вручную\n"+
		"TUN_NAME=%q\nTUN_DNS=%q\nSERVER_HOST=%q\n",
		p.TunName, strings.Join(p.DNS, " "), host)
}
