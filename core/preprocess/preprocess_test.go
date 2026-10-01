package preprocess

import (
	"encoding/json"
	"strings"
	"testing"

	_ "github.com/xtls/xray-core/main/distro/all"
)

// Конфиг приложения: socks-inbound + два outbound-а (backuppc первым —
// маршрут по умолчанию, как делает OneXray с выбранным сервером).
const appConfig = `{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "socksIn",
    "protocol": "socks",
    "listen": "127.0.0.1",
    "port": 10808,
    "settings": {"auth": "noauth", "udp": false}
  }],
  "outbounds": [
    {
      "tag": "my-backuppc",
      "protocol": "backuppc",
      "settings": {
        "serverAddr": "203.0.113.10:443",
        "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "host": "storage.corp.example",
        "certFingerprint": "ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234",
        "maxSessionDuration": "25m",
        "pingBaseInterval": "18s"
      }
    },
    {"tag": "direct", "protocol": "freedom"}
  ]
}`

func TestNormalizeJSONNoBackupPC(t *testing.T) {
	plain := []byte(`{"log":{"loglevel":"info"},"outbounds":[{"protocol":"freedom","tag":"direct"}]}`)
	patched, reps, err := NormalizeJSON(plain)
	if err != nil {
		t.Fatalf("NormalizeJSON: %v", err)
	}
	if len(reps) != 0 {
		t.Fatalf(" replacements = %v, хочу 0", reps)
	}
	if string(patched) != string(plain) {
		t.Fatalf("конфиг без backuppc должен проходить без изменений:\n%s", patched)
	}
}

func TestNormalizeJSONExtractsBackupPC(t *testing.T) {
	patched, reps, err := NormalizeJSON([]byte(appConfig))
	if err != nil {
		t.Fatalf("NormalizeJSON: %v", err)
	}
	if len(reps) != 1 {
		t.Fatalf("replacements = %d, хочу 1", len(reps))
	}
	r := reps[0]
	if r.Tag != "my-backuppc" {
		t.Fatalf("tag = %q", r.Tag)
	}
	if r.Config.GetUuid() != "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" {
		t.Fatalf("uuid = %q", r.Config.GetUuid())
	}
	if r.Config.GetAddress() != "203.0.113.10" || r.Config.GetPort() != 443 {
		t.Fatalf("address:port = %q:%d", r.Config.GetAddress(), r.Config.GetPort())
	}
	if r.Config.GetHost() != "storage.corp.example" {
		t.Fatalf("host = %q", r.Config.GetHost())
	}
	if r.Config.GetSessionDurationMs() != 25*60*1000 {
		t.Fatalf("sessionDurationMs = %d", r.Config.GetSessionDurationMs())
	}
	if r.Config.GetPingBaseMs() != 18000 {
		t.Fatalf("pingBaseMs = %d", r.Config.GetPingBaseMs())
	}

	var doc map[string]any
	if err := json.Unmarshal(patched, &doc); err != nil {
		t.Fatalf("патченный JSON не парсится: %v", err)
	}
	outs := doc["outbounds"].([]any)
	first := outs[0].(map[string]any)
	if first["protocol"] != PlaceholderProtocol {
		t.Fatalf("заполнитель protocol = %v", first["protocol"])
	}
	if first["tag"] != "my-backuppc" {
		t.Fatalf("заполнитель tag = %v (тег должен сохраниться для роутинга)", first["tag"])
	}
	if _, exists := first["settings"]; exists {
		t.Fatalf("у заполнителя не должно быть settings")
	}
	if outs[1].(map[string]any)["tag"] != "direct" {
		t.Fatalf("второй outbound поврежден")
	}
}

func TestNormalizeJSONAutoTag(t *testing.T) {
	cfg := `{"outbounds":[{"protocol":"backuppc","settings":{"serverAddr":"example.com","uuid":"u1"}}]}`
	patched, reps, err := NormalizeJSON([]byte(cfg))
	if err != nil {
		t.Fatalf("NormalizeJSON: %v", err)
	}
	if len(reps) != 1 || reps[0].Tag == "" {
		t.Fatalf("авто-тег не сгенерирован: %+v", reps)
	}
	if !strings.Contains(string(patched), `"tag":"backuppc-auto-0"`) {
		t.Fatalf("заполнитель не получил авто-тег: %s", patched)
	}
}

func TestNormalizeJSONBadSettings(t *testing.T) {
	cfg := `{"outbounds":[{"protocol":"backuppc","settings":{"serverAddr":""}}]}`
	if _, _, err := NormalizeJSON([]byte(cfg)); err == nil {
		t.Fatal("хочу ошибку для конфига без адреса")
	}
}

func TestBuildConfigSwapsPlaceholder(t *testing.T) {
	// distro/all зарегистрировал фичи ядра; BuildConfig проходит полный
	// конвейер: Normalize → LoadConfig → Apply.
	config, err := BuildConfig([]byte(appConfig))
	if err != nil {
		t.Fatalf("BuildConfig: %v", err)
	}
	found := false
	for _, out := range config.Outbound {
		if out.Tag == "my-backuppc" {
			found = true
			if out.ProxySettings == nil || out.ProxySettings.Type != "backuppc.Config" {
				t.Fatalf("ProxySettings = %+v, хочу backuppc.Config", out.ProxySettings)
			}
			if out.ProxySettings.Value == nil || len(out.ProxySettings.Value) == 0 {
				t.Fatalf("ProxySettings.Value пуст")
			}
		}
	}
	if !found {
		t.Fatalf("outbound my-backuppc не найден после Apply")
	}
	//Freedom- outbound обязан уцелеть.
	direct := false
	for _, out := range config.Outbound {
		if out.Tag == "direct" {
			direct = true
		}
	}
	if !direct {
		t.Fatalf("outbound direct потерян")
	}
}

func TestBuildConfigPlainUnchanged(t *testing.T) {
	plain := `{"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}`
	config, err := BuildConfig([]byte(plain))
	if err != nil {
		t.Fatalf("BuildConfig: %v", err)
	}
	if len(config.Outbound) != 2 {
		t.Fatalf("outbounds = %d, хочу 2", len(config.Outbound))
	}
}
