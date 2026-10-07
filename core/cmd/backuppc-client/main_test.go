package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testLink = "backuppc://0b3e6f1a-1111-4222-8333-944455556666@203.0.113.7:8443/?host=backup.example.org&fp=ABCDEF&endpoints=%2Fa.B%2FC,%2Fd.E%2FF#Office"

func importTo(t *testing.T, args ...string) string {
	t.Helper()
	dir := t.TempDir()
	var out bytes.Buffer
	full := append([]string{"import", "-dir", dir}, args...)
	if err := run(full, strings.NewReader(""), &out); err != nil {
		t.Fatalf("import: %v", err)
	}
	return dir
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return m
}

func TestImportWritesSecretFiles(t *testing.T) {
	dir := importTo(t, testLink)
	for _, name := range []string{"link", "socks.json", "tun.json", "tun.env"} {
		st, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if st.Mode().Perm() != 0o640 {
			t.Errorf("%s: mode %o, want 640", name, st.Mode().Perm())
		}
	}
	left, _ := filepath.Glob(filepath.Join(dir, ".*"))
	if len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

func TestSocksConfig(t *testing.T) {
	dir := importTo(t, "-socks", "127.0.0.1:1081", testLink)
	cfg := readJSON(t, filepath.Join(dir, "socks.json"))

	in := cfg["inbounds"].([]any)[0].(map[string]any)
	if in["protocol"] != "socks" || in["listen"] != "127.0.0.1" || in["port"] != float64(1081) {
		t.Errorf("socks inbound: %v", in)
	}
	proxy := cfg["outbounds"].([]any)[0].(map[string]any)
	if proxy["protocol"] != "backuppc" || proxy["tag"] != "proxy" {
		t.Fatalf("first outbound must be backuppc proxy: %v", proxy)
	}
	s := proxy["settings"].(map[string]any)
	if s["serverAddr"] != "203.0.113.7:8443" || s["host"] != "backup.example.org" ||
		s["certFingerprint"] != "abcdef" {
		t.Errorf("settings: %v", s)
	}
	if eps := s["endpointPaths"].([]any); len(eps) != 2 || eps[0] != "/a.B/C" {
		t.Errorf("endpointPaths: %v", eps)
	}
}

func TestTunConfig(t *testing.T) {
	dir := importTo(t, "-tun", "bpctest", "-dns", "9.9.9.9", testLink)
	cfg := readJSON(t, filepath.Join(dir, "tun.json"))

	in := cfg["inbounds"].([]any)[0].(map[string]any)
	st := in["settings"].(map[string]any)
	if in["protocol"] != "tun" || st["name"] != "bpctest" || st["MTU"] != float64(1500) {
		t.Errorf("tun inbound: %v", in)
	}
	dns := cfg["dns"].(map[string]any)
	if srv := dns["servers"].([]any); len(srv) != 1 || srv[0] != "tcp://9.9.9.9" {
		t.Errorf("dns servers: %v", srv)
	}
	// DNS-модуль ходит через прокси; UDP:53 из TUN — в dns-outbound;
	// прочий UDP блокируется (протокол переносит только TCP).
	rules := cfg["routing"].(map[string]any)["rules"].([]any)
	want := []string{"proxy", "dns-out", "direct", "block"}
	if len(rules) != len(want) {
		t.Fatalf("rules: %v", rules)
	}
	for i, r := range rules {
		if got := r.(map[string]any)["outboundTag"]; got != want[i] {
			t.Errorf("rule %d → %v, want %s", i, got, want[i])
		}
	}

	env, _ := os.ReadFile(filepath.Join(dir, "tun.env"))
	for _, line := range []string{`TUN_NAME="bpctest"`, `TUN_DNS="9.9.9.9"`, `SERVER_HOST="203.0.113.7"`} {
		if !strings.Contains(string(env), line) {
			t.Errorf("tun.env missing %s:\n%s", line, env)
		}
	}
}

func TestTunEnvIPv6Server(t *testing.T) {
	dir := importTo(t, "backuppc://u-u-i-d-x@[2001:db8::1]:8443/#v6")
	env, _ := os.ReadFile(filepath.Join(dir, "tun.env"))
	if !strings.Contains(string(env), `SERVER_HOST="2001:db8::1"`) {
		t.Errorf("tun.env:\n%s", env)
	}
}

func TestImportFromStdin(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	if err := run([]string{"import", "-dir", dir, "-"}, strings.NewReader(testLink+"\n"), &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "tun.json")); err != nil {
		t.Fatal(err)
	}
}

func TestImportRejectsBadInput(t *testing.T) {
	cases := [][]string{
		{"vless://x@h:1"},
		{"-socks", "localhost:1080", testLink},
		{"-socks", "127.0.0.1", testLink},
		{"-tun", "this-name-is-too-long", testLink},
		{"-mtu", "100", testLink},
		{"-dns", "dns.google", testLink},
		{"-loglevel", "loud", testLink},
		{},
	}
	for _, c := range cases {
		dir := t.TempDir()
		var out bytes.Buffer
		if err := run(append([]string{"import", "-dir", dir}, c...), strings.NewReader(""), &out); err == nil {
			t.Errorf("import %v: expected error", c)
		}
		if entries, _ := os.ReadDir(dir); len(entries) != 0 {
			t.Errorf("import %v: files written on error", c)
		}
	}
}

func TestShowMasksUUID(t *testing.T) {
	dir := importTo(t, testLink)
	var out bytes.Buffer
	if err := run([]string{"show", "-dir", dir}, nil, &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	if strings.Contains(s, "944455556666") || !strings.Contains(s, "0b3e6f1a-****") {
		t.Errorf("uuid not masked:\n%s", s)
	}
	if !strings.Contains(s, "Office") || !strings.Contains(s, "203.0.113.7:8443") {
		t.Errorf("show output:\n%s", s)
	}
}
