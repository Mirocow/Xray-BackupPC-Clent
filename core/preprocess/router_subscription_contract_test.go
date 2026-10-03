package preprocess

// Contract-тест на совместимость JSON-формата, который генерирует роутер asuswrt-merlin-xrayui
// (функция subscription_parse_backuppc в src/backend/subscriptions.sh:552-621) и клиентом
// (core/preprocess/preprocess.go → outbound.ParseSettingsJSON).
//
// Роутер парсит backuppc:// share links и складывает результат в outbound settings.
// Если формат не совпадает с тем, что ожидает ParseSettingsJSON, клиент падает на
// xray -test с ошибкой 'backuppc settings: требуется serverAddr либо address'
// (это та самая ошибка, которую ловил пользователь до фикса v0.70.10 в роутере).
//
// Тест фиксирует формат, который роутер генерирует, как wire-format contract:
// 1. ParseSettingsJSON должен принимать JSON, который генерирует роутер.
// 2. Результирующий protobuf Config должен содержать корректные address/port/uuid/host/fp.

import (
	"testing"

	"backuppc-core/core/outbound"
)

// TestRouterSubscriptionParseOutputAccepted — JSON, которую генерирует роутер
// (subscription_parse_backuppc в src/backend/subscriptions.sh:552-621) для ссылки:
//   backuppc://52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90@backuppc-gw.dthpto.ru:8443/?host=lampa-tv.ru&fp=5624ff26fbb91710e24f3a8028110016f59fdd7f501fd6171089bbe62e0d5a56&endpoints=%2Fbackuppc.BackupService%2FBackupStream,%2Fbackuppc.ChunkService%2FPutChunk#obd-backuppc
//
// Это settings JSON (не весь outbound), который preprocess.go извлекает из outbound.settings
// и передаёт в outbound.ParseSettingsJSON.
func TestRouterSubscriptionParseOutputAccepted(t *testing.T) {
	routerSettingsJSON := []byte(`{
		"address": "backuppc-gw.dthpto.ru",
		"port": 8443,
		"uuid": "52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90",
		"host": "lampa-tv.ru",
		"certFingerprint": "5624ff26fbb91710e24f3a8028110016f59fdd7f501fd6171089bbe62e0d5a56",
		"endpointPaths": ["/backuppc.BackupService/BackupStream", "/backuppc.ChunkService/PutChunk"]
	}`)

	cfg, err := outbound.ParseSettingsJSON(routerSettingsJSON)
	if err != nil {
		t.Fatalf("ParseSettingsJSON rejected the router's subscription-parse output: %v\n"+
			"The JSON shape above is what asuswrt-merlin-xrayui's subscription_parse_backuppc\n"+
			"(src/backend/subscriptions.sh:552-621) generates. If you change ParseSettingsJSON\n"+
			"to require different field names, you must also update the router parser.",
			err)
	}

	if cfg.GetAddress() != "backuppc-gw.dthpto.ru" {
		t.Errorf("address: got %q, want backuppc-gw.dthpto.ru", cfg.GetAddress())
	}
	if cfg.GetPort() != 8443 {
		t.Errorf("port: got %d, want 8443", cfg.GetPort())
	}
	if cfg.GetUuid() != "52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90" {
		t.Errorf("uuid: got %q, want 52724a0e-...", cfg.GetUuid())
	}
	if cfg.GetHost() != "lampa-tv.ru" {
		t.Errorf("host (SNI): got %q, want lampa-tv.ru", cfg.GetHost())
	}
	if cfg.GetCertFingerprint() != "5624ff26fbb91710e24f3a8028110016f59fdd7f501fd6171089bbe62e0d5a56" {
		t.Errorf("certFingerprint: got %q, want 5624ff26...", cfg.GetCertFingerprint())
	}
	if len(cfg.GetEndpointPaths()) != 2 {
		t.Fatalf("endpointPaths: got %d, want 2", len(cfg.GetEndpointPaths()))
	}
}

// TestRouterSubscriptionWithServerAddrAlsoAccepted — альтернативный формат с serverAddr
// (используется Dart-клиентом и Go core/link/link.go:103 OutboundJSON):
//   backuppc://uuid@host:port/?...
// должен тоже приниматься (serverAddr имеет приоритет над address+port).
func TestRouterSubscriptionWithServerAddrAlsoAccepted(t *testing.T) {
	serverAddrSettingsJSON := []byte(`{
		"serverAddr": "backuppc-gw.dthpto.ru:8443",
		"uuid": "52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90"
	}`)

	cfg, err := outbound.ParseSettingsJSON(serverAddrSettingsJSON)
	if err != nil {
		t.Fatalf("ParseSettingsJSON rejected serverAddr form: %v", err)
	}
	if cfg.GetAddress() != "backuppc-gw.dthpto.ru" {
		t.Errorf("address (split from serverAddr): got %q, want backuppc-gw.dthpto.ru", cfg.GetAddress())
	}
	if cfg.GetPort() != 8443 {
		t.Errorf("port (split from serverAddr): got %d, want 8443", cfg.GetPort())
	}
}

// TestEmptyRouterDefaultRejected — выходная форма конструктора outbound в роутере,
// когда subscription body не содержит backuppc:// ссылку (или subscription URL не указан):
//   { "address": "", "port": 443, "uuid": "" }
// должен отвергаться ParseSettingsJSON — это и есть ошибка, которую видел пользователь:
//   backuppc preprocess: outbound "obd-backuppc": backuppc settings: требуется serverAddr либо address
func TestEmptyRouterDefaultRejected(t *testing.T) {
	emptySettings := []byte(`{"address": "", "port": 443, "uuid": ""}`)

	_, err := outbound.ParseSettingsJSON(emptySettings)
	if err == nil {
		t.Fatal("want error 'требуется serverAddr либо address' for the empty default — operator forgot to provide Subscription URL or body has no backuppc:// link")
	}
}
