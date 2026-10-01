package outbound

import (
	"encoding/json"
	"testing"
	"time"

	"backuppc"
	backuppcpb "backuppc-core/backuppcpb"
)

func TestParseSettingsJSONFull(t *testing.T) {
	raw := `{
	  "serverAddr": "vpn.example.com:8443",
	  "uuid": "11111111-2222-3333-4444-555555555555",
	  "host": "storage.corp.example",
	  "certFingerprint": "ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234",
	  "endpointPaths": ["/backuppc.BackupService/BackupStream"],
	  "userAgent": "BackupPC/3.3.2",
	  "insecure": true,
	  "minPaddingSize": 64,
	  "maxPaddingSize": 900,
	  "maxSessionDuration": "25m",
	  "maxSessionBytes": 1048576,
	  "pingBaseInterval": "18s",
	  "pingJitterMax": "12s",
	  "balancingInterval": "4s"
	}`
	cfg, err := ParseSettingsJSON([]byte(raw))
	if err != nil {
		t.Fatalf("ParseSettingsJSON: %v", err)
	}
	if cfg.GetAddress() != "vpn.example.com" || cfg.GetPort() != 8443 {
		t.Fatalf("address:port = %q:%d", cfg.GetAddress(), cfg.GetPort())
	}
	if cfg.GetUuid() != "11111111-2222-3333-4444-555555555555" {
		t.Fatalf("uuid = %q", cfg.GetUuid())
	}
	if cfg.GetHost() != "storage.corp.example" {
		t.Fatalf("host = %q", cfg.GetHost())
	}
	if !cfg.GetInsecure() {
		t.Fatal("insecure потерян")
	}
	if cfg.GetMinPadding() != 64 || cfg.GetMaxPadding() != 900 {
		t.Fatalf("padding = %d-%d", cfg.GetMinPadding(), cfg.GetMaxPadding())
	}
	if cfg.GetSessionDurationMs() != 25*time.Minute.Milliseconds() {
		t.Fatalf("sessionDuration = %d мс", cfg.GetSessionDurationMs())
	}
	if cfg.GetSessionBytes() != 1048576 {
		t.Fatalf("sessionBytes = %d", cfg.GetSessionBytes())
	}
	if cfg.GetPingBaseMs() != 18*time.Second.Milliseconds() {
		t.Fatalf("pingBase = %d мс", cfg.GetPingBaseMs())
	}
	if cfg.GetPingJitterMs() != 12*time.Second.Milliseconds() {
		t.Fatalf("pingJitter = %d мс", cfg.GetPingJitterMs())
	}
	if cfg.GetBalancingIntervalMs() != 4*time.Second.Milliseconds() {
		t.Fatalf("balancing = %d мс", cfg.GetBalancingIntervalMs())
	}
	if len(cfg.GetEndpointPaths()) != 1 {
		t.Fatalf("endpointPaths = %v", cfg.GetEndpointPaths())
	}
	if cfg.GetUserAgent() != "BackupPC/3.3.2" {
		t.Fatalf("userAgent = %q", cfg.GetUserAgent())
	}
}

func TestParseSettingsAddressPortForm(t *testing.T) {
	raw := `{"address": "203.0.113.7", "port": 443, "uuid": "u"}`
	cfg, err := ParseSettingsJSON([]byte(raw))
	if err != nil {
		t.Fatalf("ParseSettingsJSON: %v", err)
	}
	if cfg.GetAddress() != "203.0.113.7" || cfg.GetPort() != 443 {
		t.Fatalf("address:port = %q:%d", cfg.GetAddress(), cfg.GetPort())
	}
}

func TestParseSettingsIPv6ServerAddr(t *testing.T) {
	raw := `{"serverAddr": "[2001:db8::1]:9443", "uuid": "u"}`
	cfg, err := ParseSettingsJSON([]byte(raw))
	if err != nil {
		t.Fatalf("ParseSettingsJSON: %v", err)
	}
	if cfg.GetAddress() != "2001:db8::1" || cfg.GetPort() != 9443 {
		t.Fatalf("address:port = %q:%d", cfg.GetAddress(), cfg.GetPort())
	}
}

func TestParseSettingsDefaults(t *testing.T) {
	raw := `{"serverAddr": "s.example", "uuid": "u"}`
	cfg, err := ParseSettingsJSON([]byte(raw))
	if err != nil {
		t.Fatalf("ParseSettingsJSON: %v", err)
	}
	if cfg.GetPort() != DefaultPort {
		t.Fatalf("port = %d, хочу %d", cfg.GetPort(), DefaultPort)
	}
}

func TestParseSettingsErrors(t *testing.T) {
	cases := []string{
		`{}`,
		`{"uuid": "u"}`,
		`{"serverAddr": "s.example"}`,
		`{"serverAddr": "s.example", "uuid": ""}`,
		`{"serverAddr": "s.example", "uuid": "u", "port": 70000}`,
		`not json`,
	}
	for _, c := range cases {
		if _, err := ParseSettingsJSON([]byte(c)); err == nil {
			t.Errorf("ParseSettingsJSON(%q) должен вернуть ошибку", c)
		}
	}
}

func TestValidateSettingsJSON(t *testing.T) {
	if err := ValidateSettingsJSON([]byte(`{"serverAddr": "s.example", "uuid": "u"}`)); err != nil {
		t.Fatalf("валидный конфиг отклонен: %v", err)
	}
	if err := ValidateSettingsJSON([]byte(`{"uuid": "u"}`)); err == nil {
		t.Fatal("невалидный конфиг принят")
	}
}

func TestClientConfigRoundtrip(t *testing.T) {
	// protobuf → ClientConfig библиотеки → параметры ApplyDefaults + переопределения.
	pb := &backuppcpb.Config{
		Address:             "vpn.example.com",
		Port:                8443,
		Uuid:                "11111111-2222-3333-4444-555555555555",
		Host:                "storage.corp.example",
		CertFingerprint:     "ABCD1234",
		Insecure:            true,
		MinPadding:          64,
		MaxPadding:          900,
		SessionDurationMs:   25 * time.Minute.Milliseconds(),
		SessionBytes:        1048576,
		PingBaseMs:          18 * time.Second.Milliseconds(),
		PingJitterMs:        12 * time.Second.Milliseconds(),
		BalancingIntervalMs: 4 * time.Second.Milliseconds(),
	}
	c := ClientConfigFromProto(pb)
	if c.ServerAddr != "vpn.example.com:8443" {
		t.Fatalf("serverAddr = %q", c.ServerAddr)
	}
	if c.UUID != pb.GetUuid() || c.Host != pb.GetHost() {
		t.Fatalf("uuid/host: %q/%q", c.UUID, c.Host)
	}
	// Пиннинг приоритетнее insecure (библиотека запрещает оба сразу).
	if c.Insecure {
		t.Fatal("insecure должен быть сброшен при наличии certFingerprint")
	}
	if c.CertFingerprint != "abcd1234" {
		t.Fatalf("fp=%q (должен быть lowercase)", c.CertFingerprint)
	}
	if c.TransportConfig.MinPaddingSize != 64 || c.TransportConfig.MaxPaddingSize != 900 {
		t.Fatalf("padding: %d-%d", c.TransportConfig.MinPaddingSize, c.TransportConfig.MaxPaddingSize)
	}
	if c.TransportConfig.MaxSessionDuration.D() != 25*time.Minute {
		t.Fatalf("maxSessionDuration = %v", c.TransportConfig.MaxSessionDuration.D())
	}
	if c.TransportConfig.MaxSessionBytes != 1048576 {
		t.Fatalf("maxSessionBytes = %d", c.TransportConfig.MaxSessionBytes)
	}
	if c.TransportConfig.PingBaseInterval.D() != 18*time.Second {
		t.Fatalf("pingBase = %v", c.TransportConfig.PingBaseInterval.D())
	}
	// Validate библиотеки должна проходить (конфиг полный).
	if err := validateClient(c); err != nil {
		t.Fatalf("конфиг библиотеки невалиден: %v", err)
	}
}

func validateClient(c *backuppc.ClientConfig) error {
	_, err := backuppc.NewClient(c, nil)
	return err
}

func TestSettingsJSONFromProto(t *testing.T) {
	pb := &backuppcpb.Config{
		Address:           "vpn.example.com",
		Port:              8443,
		Uuid:              "u",
		Host:              "donor.example",
		SessionDurationMs: 30 * time.Minute.Milliseconds(),
	}
	raw, err := SettingsJSONFromProto(pb)
	if err != nil {
		t.Fatalf("SettingsJSONFromProto: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m["serverAddr"] != "vpn.example.com:8443" {
		t.Fatalf("serverAddr = %v", m["serverAddr"])
	}
	if m["maxSessionDuration"] != "30m0s" && m["maxSessionDuration"] != "30m" {
		t.Fatalf("maxSessionDuration = %v", m["maxSessionDuration"])
	}
}
