package outbound

import (
	"testing"
)

// TestSettingsPlumbingTransportTuning — регресс конвейера настроек
// тюнинга транспорта: settings JSON → protobuf → ClientConfig. Поле
// maxSessionBytes критично для ротации чанков на больших объемах
// (стриминг): потеря поля превращает лимит в дефолт 2 ГиБ и ротации
// на коротких прогонах не видны.
func TestSettingsPlumbingTransportTuning(t *testing.T) {
	raw := []byte(`{
		"serverAddr": "127.0.0.1:18445",
		"uuid": "e2e11e2e-11e2-11e2-11e2-11e2e2e2e2e1",
		"insecure": true,
		"maxSessionBytes": 268435456,
		"maxSessionDuration": "17m",
		"pingBaseInterval": "7s",
		"minPaddingSize": 64,
		"maxPaddingSize": 900
	}`)
	pb, err := ParseSettingsJSON(raw)
	if err != nil {
		t.Fatalf("settings: %v", err)
	}
	if got := pb.GetSessionBytes(); got != 268435456 {
		t.Errorf("proto session_bytes: %d", got)
	}
	ccfg := ClientConfigFromProto(pb)

	if ccfg.MaxSessionBytes != 268435456 {
		t.Errorf("MaxSessionBytes: %d (конвейер теряет поле)", ccfg.MaxSessionBytes)
	}
	if want := "17m0s"; ccfg.MaxSessionDuration.String() != want {
		t.Errorf("MaxSessionDuration: %s (хотели %s)", ccfg.MaxSessionDuration, want)
	}
	if got := ccfg.PingBaseInterval.String(); got != "7s" {
		t.Errorf("PingBaseInterval: %s", got)
	}
	if ccfg.MinPaddingSize != 64 || ccfg.MaxPaddingSize != 900 {
		t.Errorf("padding: [%d..%d]", ccfg.MinPaddingSize, ccfg.MaxPaddingSize)
	}
}
