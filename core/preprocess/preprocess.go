// Package preprocess встраивает backuppc-outbound в конвейер конфигурации
// ядра Xray. Слой JSON-конфигурации Xray (infra/conf) имеет закрытый реестр
// протоколов, поэтому backuppc обрабатывается на стыке: JSON-документ
// нормализуется ДО core.LoadConfig (backuppc-outbound подменяется
// понятным загрузчику blackhole-заполнителем), а ПОСЛЕ загрузки заполнитель
// заменяется на настоящий protobuf-handler по тегу. Для конфигов без
// backuppc поведение ядра не меняется.
package preprocess

import (
	"encoding/json"
	"fmt"
	"strings"

	backuppcpb "backuppc-core/backuppcpb"
	"backuppc-core/outbound"

	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
)

const (
	// Protocol — имя протокола в JSON-конфигурации Xray.
	Protocol = "backuppc"
	// PlaceholderProtocol — понятный infra/conf заполнитель, который
	// занимает место backuppc-outbound на время загрузки JSON.
	PlaceholderProtocol = "blackhole"
)

// Replacement — отложенная замена: тег заполнителя → protobuf-конфиг.
type Replacement struct {
	Tag    string
	Config *backuppcpb.Config
}

// NormalizeJSON подготавливает JSON-конфиг Xray к core.LoadConfig:
// каждый outbound с protocol=="backuppc" заменяется на blackhole
// с тем же тегом (роутинг, балансировщики и dialerProxy продолжают
// ссылаться на тег), а его settings возвращаются как Replacement.
// Конфиг без backuppc сериализуется эквивалентно (порядок ключей может
// измениться, семантика — нет).
func NormalizeJSON(xrayJSON []byte) ([]byte, []Replacement, error) {
	var root map[string]any
	if err := json.Unmarshal(xrayJSON, &root); err != nil {
		return nil, nil, fmt.Errorf("backuppc preprocess: %w", err)
	}

	outboundsAny, ok := root["outbounds"]
	if !ok {
		return xrayJSON, nil, nil
	}
	outbounds, ok := outboundsAny.([]any)
	if !ok || len(outbounds) == 0 {
		return xrayJSON, nil, nil
	}

	var replacements []Replacement
	autoIndex := 0
	changed := false
	for i, entryAny := range outbounds {
		entry, ok := entryAny.(map[string]any)
		if !ok {
			continue
		}
		proto, _ := entry["protocol"].(string)
		if proto != Protocol {
			continue
		}
		tag, _ := entry["tag"].(string)
		if tag == "" {
			tag = fmt.Sprintf("%s-auto-%d", Protocol, autoIndex)
			autoIndex++
		}

		settings, err := json.Marshal(entry["settings"])
		if err != nil {
			return nil, nil, fmt.Errorf("backuppc preprocess: outbound %q: %w", tag, err)
		}
		cfg, err := outbound.ParseSettingsJSON(settings)
		if err != nil {
			return nil, nil, fmt.Errorf("backuppc preprocess: outbound %q: %w", tag, err)
		}
		replacements = append(replacements, Replacement{Tag: tag, Config: cfg})

		// Заполнитель: только protocol + tag. Тег сохраняется, чтобы
		// после LoadConfig найти и заменить запись по индексу тега.
		outbounds[i] = map[string]any{
			"protocol": PlaceholderProtocol,
			"tag":      tag,
		}
		changed = true
	}
	if !changed {
		// Ни одного backuppc-outbound: пропускаем исходный документ дальше
		// без перемаршализации (byte-for-byte).
		return xrayJSON, nil, nil
	}
	root["outbounds"] = outbounds
	patched, err := json.Marshal(root)
	if err != nil {
		return nil, nil, fmt.Errorf("backuppc preprocess: %w", err)
	}
	return patched, replacements, nil
}

// Apply подменяет blackhole-заполнители в загруженном core.Config
// на protobuf-конфиги backuppc (вызывается между core.LoadConfig и
// core.New). Меняются только записи с тегами из replacements.
func Apply(config *core.Config, replacements []Replacement) error {
	if len(replacements) == 0 {
		return nil
	}
	pending := make(map[string]*backuppcpb.Config, len(replacements))
	for _, r := range replacements {
		pending[r.Tag] = r.Config
	}
	for i, out := range config.Outbound {
		cfg, ok := pending[out.Tag]
		if !ok {
			continue
		}
		config.Outbound[i] = &core.OutboundHandlerConfig{
			Tag:           out.Tag,
			ProxySettings: serial.ToTypedMessage(cfg),
		}
		delete(pending, out.Tag)
	}
	if len(pending) > 0 {
		tags := make([]string, 0, len(pending))
		for tag := range pending {
			tags = append(tags, tag)
		}
		return fmt.Errorf("backuppc preprocess: потеряны outbound-ы %v", tags)
	}
	return nil
}

// BuildConfig — полный конвейер для встраивания: нормализация JSON,
// загрузка через ядро и подмена заполнителей. Валидация выполняется
// как обычно (TestXray → BuildConfig без Start).
func BuildConfig(xrayJSON []byte) (*core.Config, error) {
	patched, replacements, err := NormalizeJSON(xrayJSON)
	if err != nil {
		return nil, err
	}
	config, err := core.LoadConfig("json", strings.NewReader(string(patched)))
	if err != nil {
		return nil, err
	}
	if err := Apply(config, replacements); err != nil {
		return nil, err
	}
	return config, nil
}
