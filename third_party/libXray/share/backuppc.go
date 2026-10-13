package share

// Файл добавляется патчем backuppc-core (core/libxray/patch.py) в пакет
// share кастомной сборки libXray: парсинг share-ссылок backuppc:// и
// валидация backuppc-outbound при импорте. Протокол реализован в
// backuppc-core и зарегистрирован в ядре Xray нативно.

import (
	"encoding/json"
	"fmt"

	backuppclink "backuppc-core/link"
	"backuppc-core/outbound"

	"github.com/xtls/xray-core/infra/conf"
)

// backuppcOutbound разворачивает backuppc://-ссылку в outbound JSON:
// protocol "backuppc" + settings транспортной библиотеки.
func (proxy xrayShareLink) backuppcOutbound() (*conf.OutboundDetourConfig, error) {
	out, err := backuppclink.ParseLink(proxy.rawText)
	if err != nil {
		return nil, fmt.Errorf("backuppc link: %w", err)
	}
	settingsMap, ok := out.OutboundJSON()["settings"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("backuppc link: пустые settings")
	}
	settingsRaw, err := convertJsonToRawMessage(settingsMap)
	if err != nil {
		return nil, err
	}
	detour := &conf.OutboundDetourConfig{}
	detour.Protocol = "backuppc"
	setOutboundName(detour, out.Tag)
	detour.Settings = &settingsRaw
	return detour, nil
}

// validateBackupPCOutbound проверяет settings backuppc-outbound (вместо
// conf.Build, который не знает протокола); вызывается из
// filterBuildableOutbounds патченной сборки.
func validateBackupPCOutbound(settings *json.RawMessage) error {
	if settings == nil {
		return fmt.Errorf("backuppc: settings отсутствует")
	}
	return outbound.ValidateSettingsJSON(*settings)
}
