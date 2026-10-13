package link

import (
	"encoding/json"
	"testing"
)

func TestParseBuildRoundtrip(t *testing.T) {
	link := "backuppc://11111111-2222-3333-4444-555555555555@vpn.example.com:8443/?host=storage.corp.example&fp=ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234&endpoints=%2Fbackuppc.BackupService%2FBackupStream&pad=32-1400#My%20Server"

	out, err := ParseLink(link)
	if err != nil {
		t.Fatalf("ParseLink: %v", err)
	}
	if out.UUID != "11111111-2222-3333-4444-555555555555" {
		t.Fatalf("uuid = %q", out.UUID)
	}
	if out.ServerAddr != "vpn.example.com:8443" {
		t.Fatalf("serverAddr = %q", out.ServerAddr)
	}
	if out.Host != "storage.corp.example" {
		t.Fatalf("host = %q", out.Host)
	}
	if out.CertFingerprint != "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234" {
		t.Fatalf("fp = %q (нормализация в lowercase)", out.CertFingerprint)
	}
	if len(out.EndpointPaths) != 1 || out.EndpointPaths[0] != "/backuppc.BackupService/BackupStream" {
		t.Fatalf("endpoints = %v", out.EndpointPaths)
	}
	if out.MinPadding != 32 || out.MaxPadding != 1400 {
		t.Fatalf("pad = %d-%d", out.MinPadding, out.MaxPadding)
	}
	if out.Tag != "My Server" {
		t.Fatalf("tag = %q", out.Tag)
	}

	built := out.BuildLink()
	parsed2, err := ParseLink(built)
	if err != nil {
		t.Fatalf("ParseLink(built): %v (%q)", err, built)
	}
	if parsed2.UUID != out.UUID || parsed2.ServerAddr != out.ServerAddr ||
		parsed2.Host != out.Host || parsed2.CertFingerprint != out.CertFingerprint ||
		parsed2.Insecure != out.Insecure || parsed2.UserAgent != out.UserAgent ||
		parsed2.Tag != out.Tag || parsed2.MinPadding != out.MinPadding ||
		parsed2.MaxPadding != out.MaxPadding {
		t.Fatalf("roundtrip mismatch:\n%+v\n%+v", *out, *parsed2)
	}
	if len(parsed2.EndpointPaths) != len(out.EndpointPaths) {
		t.Fatalf("roundtrip endpoints: %v vs %v", parsed2.EndpointPaths, out.EndpointPaths)
	}
	for i := range out.EndpointPaths {
		if parsed2.EndpointPaths[i] != out.EndpointPaths[i] {
			t.Fatalf("roundtrip endpoints: %v vs %v", parsed2.EndpointPaths, out.EndpointPaths)
		}
	}
}

func TestParseLinkDefaults(t *testing.T) {
	out, err := ParseLink("backuppc://u1@1.2.3.4/#tag1")
	if err != nil {
		t.Fatalf("ParseLink: %v", err)
	}
	if out.ServerAddr != "1.2.3.4:443" {
		t.Fatalf("serverAddr = %q, хочу порт 443 по умолчанию", out.ServerAddr)
	}
	if out.Tag != "tag1" {
		t.Fatalf("tag = %q", out.Tag)
	}
	if out.Insecure {
		t.Fatal("insecure не должен включаться по умолчанию")
	}
}

func TestParseLinkIPv6(t *testing.T) {
	out, err := ParseLink("backuppc://u1@[2001:db8::1]:9443/")
	if err != nil {
		t.Fatalf("ParseLink: %v", err)
	}
	if out.ServerAddr != "[2001:db8::1]:9443" {
		t.Fatalf("serverAddr = %q", out.ServerAddr)
	}
}

func TestParseLinkErrors(t *testing.T) {
	cases := []string{
		"vless://u@h/",                   // не та схема
		"backuppc://vpn.example.com/",    // нет uuid
		"backuppc://u@h:99999/",          // порт вне диапазона
		"backuppc://u@h/?insecure=maybe", // некорректный insecure
		"backuppc://u@h/?pad=1400-32",    // min>max
	}
	for _, c := range cases {
		if _, err := ParseLink(c); err == nil {
			t.Errorf("ParseLink(%q) должен вернуть ошибку", c)
		}
	}
}

func TestOutboundJSONShape(t *testing.T) {
	out := &Outbound{
		Tag:             "office",
		ServerAddr:      "vpn.example.com:443",
		UUID:            "u1",
		Host:            "storage.corp.example",
		CertFingerprint: "abcd1234",
	}
	m := out.OutboundJSON()
	if m["protocol"] != "backuppc" {
		t.Fatalf("protocol = %v", m["protocol"])
	}
	if m["tag"] != "office" {
		t.Fatalf("tag = %v", m["tag"])
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	settings := doc["settings"].(map[string]any)
	if settings["serverAddr"] != "vpn.example.com:443" {
		t.Fatalf("settings.serverAddr = %v", settings["serverAddr"])
	}
	if settings["uuid"] != "u1" {
		t.Fatalf("settings.uuid = %v", settings["uuid"])
	}
	if settings["host"] != "storage.corp.example" {
		t.Fatalf("settings.host = %v", settings["host"])
	}
	if _, ok := settings["insecure"]; ok {
		t.Fatal("insecure не должен попадать в JSON при false")
	}
}

func TestSettingsCompatibleWithLibrary(t *testing.T) {
	// JSON outbound-а обязан содержать serverAddr/uuid — поля конфига
	// транспортной библиотеки (backuppc.ClientConfig).
	out := &Outbound{ServerAddr: "s.example:443", UUID: "u1"}
	raw, _ := json.Marshal(out.OutboundJSON())
	var doc struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal([]byte(`{"outbounds":[`+string(raw)+`]}`), &doc); err != nil {
		t.Fatal(err)
	}
	settings := doc.Outbounds[0]["settings"].(map[string]any)
	for _, key := range []string{"serverAddr", "uuid"} {
		if _, ok := settings[key]; !ok {
			t.Fatalf("settings не содержит %q: %v", key, settings)
		}
	}
}
