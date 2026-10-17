package main

import (
	"net/netip"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseAndPinTunConfig(t *testing.T) {
	for _, tc := range []struct {
		name, link, wantHost string
	}{
		{"own host kept", testLink, "backup.example.org"},
		{"domain becomes host", "backuppc://0b3e6f1a-1111-4222-8333-944455556666@srv.example.net:8443/?fp=ab#X", "srv.example.net"},
		{"ip server without host", "backuppc://0b3e6f1a-1111-4222-8333-944455556666@203.0.113.7:8443/?fp=ab#X", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := importTo(t, "-dns", "9.9.9.9,1.0.0.1", tc.link)
			cfg := readJSON(t, filepath.Join(dir, "tun.json"))
			plan, err := parseTunConfig(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if plan.Name != defaultTun || plan.ServerPort != "8443" ||
				!reflect.DeepEqual(plan.DNS, []string{"9.9.9.9", "1.0.0.1"}) {
				t.Fatalf("plan: %+v", plan)
			}
			pinServer(cfg, plan, netip.MustParseAddr("198.51.100.9"))
			s := proxySettings(cfg)
			if s["serverAddr"] != "198.51.100.9:8443" {
				t.Errorf("serverAddr = %v", s["serverAddr"])
			}
			host, _ := s["host"].(string)
			if host != tc.wantHost {
				t.Errorf("host = %q, want %q", host, tc.wantHost)
			}
		})
	}
}

func TestPinServerIPv6(t *testing.T) {
	dir := importTo(t, testLink)
	cfg := readJSON(t, filepath.Join(dir, "tun.json"))
	plan, _ := parseTunConfig(cfg)
	pinServer(cfg, plan, netip.MustParseAddr("2001:db8::7"))
	if got := proxySettings(cfg)["serverAddr"]; got != "[2001:db8::7]:8443" {
		t.Errorf("serverAddr = %v", got)
	}
}

func TestParseTunConfigErrors(t *testing.T) {
	if _, err := parseTunConfig(map[string]any{}); err == nil {
		t.Error("empty config accepted")
	}
}

func TestPickServerIP(t *testing.T) {
	v4, v6 := netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("2001:db8::1")
	both := []netip.Addr{v6, v4}
	if ip, _ := pickServerIP(both, true, true); ip != v4 {
		t.Errorf("prefer v4: %v", ip)
	}
	if ip, _ := pickServerIP(both, false, true); ip != v6 {
		t.Errorf("v6-only uplink: %v", ip)
	}
	if _, err := pickServerIP([]netip.Addr{v6}, true, false); err == nil {
		t.Error("v6 address without v6 uplink accepted")
	}
}

const netstatInet = `Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
0/1                utun99             USc                utun99
default            192.168.1.1        UGScg                 en0
default            link#22            UCSIg              utun3
127                127.0.0.1          UCS                   lo0
`

const netstatInet6 = `Routing tables

Internet6:
Destination                             Gateway                                 Flags               Netif Expire
default                                 fe80::%utun0                            UGcIg               utun0
default                                 fe80::1%en0                             UGcg                  en0
`

func TestParseNetstatDefault(t *testing.T) {
	u, ok := parseNetstatDefault(netstatInet, "utun99")
	if !ok || u != (uplink{Gateway: "192.168.1.1", Iface: "en0"}) {
		t.Errorf("inet: %+v %v", u, ok)
	}
	u, ok = parseNetstatDefault(netstatInet6, "utun0")
	if !ok || u != (uplink{Gateway: "fe80::1%en0", Iface: "en0"}) {
		t.Errorf("inet6: %+v %v", u, ok)
	}
	pppOnly := "Destination Gateway Flags Netif Expire\ndefault link#9 UCS ppp0\n"
	u, ok = parseNetstatDefault(pppOnly, "utun99")
	if !ok || u != (uplink{Iface: "ppp0"}) {
		t.Errorf("on-link: %+v %v", u, ok)
	}
	if _, ok := parseNetstatDefault("Destination Gateway Flags Netif\n", "x"); ok {
		t.Error("no default accepted")
	}
}

func TestParsePSUplink(t *testing.T) {
	u, ok := parsePSUplink("192.168.0.1 12 Беспроводная сеть\r\n")
	if !ok || u != (uplink{Gateway: "192.168.0.1", Index: 12, Iface: "Беспроводная сеть"}) {
		t.Errorf("%+v %v", u, ok)
	}
	u, ok = parsePSUplink("0.0.0.0 7 Cellular")
	if !ok || u.Gateway != "" || u.Index != 7 {
		t.Errorf("on-link: %+v %v", u, ok)
	}
	for _, bad := range []string{"", "\r\n", "192.168.0.1 x Eth", "192.168.0.1 3"} {
		if _, ok := parsePSUplink(bad); ok {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestParseDNSList(t *testing.T) {
	if got := parseDNSList("192.168.1.1\n2001:db8::53\n"); !reflect.DeepEqual(got, []string{"192.168.1.1", "2001:db8::53"}) {
		t.Errorf("%v", got)
	}
	if got := parseDNSList("There aren't any DNS Servers set on Wi-Fi.\n"); !reflect.DeepEqual(got, []string{"Empty"}) {
		t.Errorf("%v", got)
	}
}

func TestParseRouteGet(t *testing.T) {
	viaGW := `   route to: 194.87.126.148
destination: default
       mask: default
    gateway: 192.168.1.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
`
	if u, ok := parseRouteGet(viaGW); !ok || u != (uplink{Gateway: "192.168.1.1", Iface: "en0"}) {
		t.Errorf("via gateway: %+v %v", u, ok)
	}
	onLink := "   route to: 192.168.1.20\ndestination: 192.168.1.0\n  interface: en0\n      flags: <UP,DONE,CLONING>\n"
	if u, ok := parseRouteGet(onLink); !ok || u != (uplink{Iface: "en0"}) {
		t.Errorf("on-link: %+v %v", u, ok)
	}
	if _, ok := parseRouteGet("route: writing to routing socket: not in table\n"); ok {
		t.Error("error output accepted")
	}
}
