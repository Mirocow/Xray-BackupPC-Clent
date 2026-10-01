package outbound

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"backuppc"
	backuppcpb "backuppc-core/backuppcpb"
)

// Порт сервера по умолчанию (TLS).
const DefaultPort = 443

// settingsJSON — схема settings backuppc-outbound. Имена полей совпадают
// с JSON-конфигом транспортной библиотеки (backuppc.ClientConfig), чтобы
// конфиги панели xray-backuppc и примеры подходили без изменений.
type settingsJSON struct {
	ServerAddr      string   `json:"serverAddr"` // «host:port» целиком
	Address         string   `json:"address"`    // альтернатива: хост отдельно
	Port            uint16   `json:"port"`       // порт (при address), дефолт 443
	UUID            string   `json:"uuid"`
	Host            string   `json:"host"`
	EndpointPaths   []string `json:"endpointPaths"`
	UserAgent       string   `json:"userAgent"`
	Insecure        bool     `json:"insecure"`
	CertFingerprint string   `json:"certFingerprint"`
	MinPaddingSize  int      `json:"minPaddingSize"`
	MaxPaddingSize  int      `json:"maxPaddingSize"`
	MaxSessionDur   string   `json:"maxSessionDuration"` // «30m»
	MaxSessionBytes int64    `json:"maxSessionBytes"`
	PingBase        string   `json:"pingBaseInterval"` // «20s»
	PingJitter      string   `json:"pingJitterMax"`    // «15s»
	Balancing       string   `json:"balancingInterval"`
}

// ParseSettingsJSON разбирает JSON settings backuppc-outbound и собирает
// protobuf-конфиг для ядра Xray. Непустые поля переопределяют дефолты
// транспортной библиотеки; пустые остаются на усмотрение ApplyDefaults.
func ParseSettingsJSON(raw []byte) (*backuppcpb.Config, error) {
	var s settingsJSON
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("backuppc settings: %w", err)
	}
	cfg := &backuppcpb.Config{
		Uuid:            s.UUID,
		Host:            s.Host,
		EndpointPaths:   s.EndpointPaths,
		UserAgent:       s.UserAgent,
		Insecure:        s.Insecure,
		CertFingerprint: s.CertFingerprint,
	}
	// Адрес: приоритет у serverAddr («host:port»), затем пара address+port.
	switch {
	case s.ServerAddr != "":
		cfg.Address, cfg.Port = splitServerAddr(s.ServerAddr)
	case s.Address != "":
		cfg.Address = s.Address
		cfg.Port = uint32(s.Port)
	default:
		return nil, fmt.Errorf("backuppc settings: требуется serverAddr либо address")
	}
	if cfg.Port == 0 {
		cfg.Port = DefaultPort
	}
	if cfg.Uuid == "" {
		return nil, fmt.Errorf("backuppc settings: требуется uuid")
	}
	if s.MinPaddingSize != 0 {
		cfg.MinPadding = uint32(s.MinPaddingSize)
	}
	if s.MaxPaddingSize != 0 {
		cfg.MaxPadding = uint32(s.MaxPaddingSize)
	}
	cfg.SessionDurationMs = durationStringToMs(s.MaxSessionDur)
	if s.MaxSessionBytes != 0 {
		cfg.SessionBytes = s.MaxSessionBytes
	}
	cfg.PingBaseMs = durationStringToMs(s.PingBase)
	cfg.PingJitterMs = durationStringToMs(s.PingJitter)
	cfg.BalancingIntervalMs = durationStringToMs(s.Balancing)
	return cfg, nil
}

// ValidateSettingsJSON проверяет settings без сборки protobuf: используется
// libXray при фильтрации «собираемых» outbound-ов импорта share-ссылок.
func ValidateSettingsJSON(raw []byte) error {
	_, err := ParseSettingsJSON(raw)
	return err
}

// ClientConfigFromProto — protobuf ядра → конфиг транспортной библиотеки.
func ClientConfigFromProto(p *backuppcpb.Config) *backuppc.ClientConfig {
	c := &backuppc.ClientConfig{
		ServerAddr:      joinServerAddr(p.GetAddress(), p.GetPort()),
		UUID:            p.GetUuid(),
		Insecure:        p.GetInsecure(),
		CertFingerprint: strings.ToLower(p.GetCertFingerprint()),
		SocksListen:     "127.0.0.1:0", // не используется ядром: дайлер-режим
	}
	// Пиннинг приоритетнее insecure: библиотека отвергает одновременное
	// указание, поэтому при наличии отпечатка сертификата insecure
	// игнорируется (верификация идет по SHA-256).
	if c.CertFingerprint != "" && c.Insecure {
		c.Insecure = false
	}
	t := &c.TransportConfig
	t.Host = p.GetHost()
	if n := len(p.GetEndpointPaths()); n > 0 {
		t.EndpointPaths = p.GetEndpointPaths()
	}
	t.UserAgent = p.GetUserAgent()
	if v := p.GetMinPadding(); v != 0 {
		t.MinPaddingSize = int(v)
	}
	if v := p.GetMaxPadding(); v != 0 {
		t.MaxPaddingSize = int(v)
	}
	if v := p.GetSessionDurationMs(); v != 0 {
		t.MaxSessionDuration = backuppc.Dur(time.Duration(v) * time.Millisecond)
	}
	if v := p.GetSessionBytes(); v != 0 {
		t.MaxSessionBytes = v
	}
	if v := p.GetPingBaseMs(); v != 0 {
		t.PingBaseInterval = backuppc.Dur(time.Duration(v) * time.Millisecond)
	}
	if v := p.GetPingJitterMs(); v != 0 {
		t.PingJitterMax = backuppc.Dur(time.Duration(v) * time.Millisecond)
	}
	if v := p.GetBalancingIntervalMs(); v != 0 {
		t.BalancingInterval = backuppc.Dur(time.Duration(v) * time.Millisecond)
	}
	t.ApplyDefaults()
	return c
}

// SettingsJSONFromProto — protobuf → settings-JSON (обратное преобразование,
// для генерации share-ссылок и отображения конфига).
func SettingsJSONFromProto(p *backuppcpb.Config) ([]byte, error) {
	s := settingsJSON{
		ServerAddr:      joinServerAddr(p.GetAddress(), p.GetPort()),
		UUID:            p.GetUuid(),
		Host:            p.GetHost(),
		EndpointPaths:   p.GetEndpointPaths(),
		UserAgent:       p.GetUserAgent(),
		Insecure:        p.GetInsecure(),
		CertFingerprint: p.GetCertFingerprint(),
	}
	if v := p.GetMinPadding(); v != 0 {
		s.MinPaddingSize = int(v)
	}
	if v := p.GetMaxPadding(); v != 0 {
		s.MaxPaddingSize = int(v)
	}
	if v := p.GetSessionDurationMs(); v != 0 {
		s.MaxSessionDur = (time.Duration(v) * time.Millisecond).String()
	}
	if v := p.GetSessionBytes(); v != 0 {
		s.MaxSessionBytes = v
	}
	if v := p.GetPingBaseMs(); v != 0 {
		s.PingBase = (time.Duration(v) * time.Millisecond).String()
	}
	if v := p.GetPingJitterMs(); v != 0 {
		s.PingJitter = (time.Duration(v) * time.Millisecond).String()
	}
	if v := p.GetBalancingIntervalMs(); v != 0 {
		s.Balancing = (time.Duration(v) * time.Millisecond).String()
	}
	return json.Marshal(s)
}

// splitServerAddr делит «host:port», порт по умолчанию — 443.
func splitServerAddr(addr string) (string, uint32) {
	if host, portStr, err := splitHostPort(addr); err == nil {
		var port int
		if _, err := fmt.Sscanf(portStr, "%d", &port); err == nil && port > 0 && port < 65536 {
			return host, uint32(port)
		}
		return host, DefaultPort
	}
	return addr, DefaultPort
}

// splitHostPort — net.SplitHostPort без импорта net (стабильная сигнатура).
func splitHostPort(addr string) (string, string, error) {
	i := strings.LastIndex(addr, ":")
	if i < 0 {
		return "", "", fmt.Errorf("no port")
	}
	return strings.Trim(addr[:i], "[]"), addr[i+1:], nil
}

func joinServerAddr(host string, port uint32) string {
	if port == 0 {
		return host
	}
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		// IPv6 без скобок
		return "[" + host + "]:" + fmt.Sprint(port)
	}
	return host + ":" + fmt.Sprint(port)
}

// durationStringToMs — «30m»/«45s» → миллисекунды (0 для пустой строки).
func durationStringToMs(s string) int64 {
	if s == "" {
		return 0
	}
	d, err := time.ParseDuration(s)
	if err != nil || d <= 0 {
		return 0
	}
	return d.Milliseconds()
}
