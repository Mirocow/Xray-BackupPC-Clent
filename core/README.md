# core — протокол backuppc как нативный outbound Xray

Этот модуль встраивает транспортный протокол **backuppc** (модуль
[`../backuppc`](../backuppc)) в **ядро Xray-core** как полноценный
outbound-протокол — наравне с vless/vmess/trojan. Приложение OneXray
работает с backuppc-сервером как с **еще одним дополнительным протоколом**:
share-ссылка `backuppc://`, outbound JSON `{"protocol": "backuppc"}`,
роутинг по тегу, метрики и URL-тесты — все штатные механизмы Xray.

```
 приложение OneXray                     ядро Xray (libXray + backuppc-core)         сервер
┌────────────────────┐   invoke    ┌──────────────────────────────────────┐  gRPC/h2 ┌──────────┐
│ импорт backuppc:// │ ──────────> │ RunXray/TestXray:                     │ ────────>│ VLESS →  │
│ outbound JSON      │  JSON       │  NormalizeJSON → LoadConfig → Apply   │   TLS    │ TCP-цели │
│ роутинг/метрики    │             │  диспетчер → backuppc outbound        │          └──────────┘
└────────────────────┘             │  (VLESS + чанки + маскировка BackupPC)│
                                    └──────────────────────────────────────┘
```

## Почему так

Слой JSON-конфигурации Xray (`infra/conf`) держит реестр протоколов
закрытым, поэтому регистрация нового протокола извне невозможна без
форка ядра. Вместо форка Xray-core используется **двухшаговая
подмена на стыке конвейера** (слой libXray):

1. **До** `core.LoadConfig`: `preprocess.NormalizeJSON` заменяет каждый
   outbound `protocol:"backuppc"` на blackhole-заполнитель с тем же
   тегом (теги продолжают работать в роутинге, конфиг остается валиден).
2. **После** загрузки: `preprocess.Apply` подменяет заполнители в
   `core.Config.Outbound` на настоящий protobuf-конфиг
   `backuppc.Config` (`serial.TypedMessage`). Хендлер материализуется
   через `common.RegisterConfig` — штатный механизм Xray.

Протокол становится нативным: диспетчер направляет ему соединения по
тегу исходящего, работают inbounds (socks/tun), роутинг, балансы,
dialerProxy, mux, статистика. Конфиги **без** backuppc проходят путь
byte-for-byte без изменений — поведение стоковой сборки не меняется.

## Структура

| Пакет | Назначение |
|---|---|
| `backuppcpb/` | protobuf `backuppc.Config` (контракт между JSON и хендлером). `backuppc.proto` → `protoc --go_out=.` |
| `outbound/` | хендлер `proxy.Outbound` (Process: LogicalConn + buf.Copy + полузакрытие), регистрация в ядре, JSON-settings ↔ protobuf ↔ ClientConfig библиотеки |
| `preprocess/` | NormalizeJSON / Apply / BuildConfig — конвейер конфигурации |
| `link/` | share-ссылки `backuppc://uuid@host:port/?host=&fp=#tag` → outbound JSON и обратно |
| `libxray/` | патч-инфраструктура для checkout XTLS/libXray (см. ниже) |
| `cmd/backuppc-xray/` | настольное ядро с нативным backuppc (`run`/`test`) для локальных прогонов |

Зависимости: `github.com/xtls/xray-core` (как библиотека) и модуль
`backuppc` через локальный `replace` — та же транспортная библиотека,
что и в репозитории сервера.

## Сборка и тесты

```bash
cd core
go test ./...          # юнит + E2E: живой инстанс Xray с backuppc-outbound
go build ./cmd/backuppc-xray
./e2e_native.sh        # живой прогон: сервер + ядро + curl через туннель
```

E2E-тест (`preprocess/e2e_xray_test.go`) поднимает сервер xray-backuppc,
инстанс Xray с socks-inbound и backuppc-outbound и прокачивает 1 МиБ с
ротациями чанков прямо посреди передачи — полная проверка нативного
пути диспетчеризации.

## Share-ссылка

```
backuppc://<uuid>@<server>:<port>/?host=<домен-донор>&fp=<sha256>&insecure=1&ua=<agent>&endpoints=<пути>&pad=32-1400#<имя>
```

Разворачивается в outbound JSON (settings — схема транспортной
библиотеки):

```json
{
  "tag": "Office",
  "protocol": "backuppc",
  "settings": {
    "serverAddr": "vpn.example.com:8443",
    "uuid": "11111111-2222-3333-4444-555555555555",
    "host": "storage.corp.example",
    "certFingerprint": "abcd1234…",
    "maxSessionDuration": "30m",
    "pingBaseInterval": "20s",
    "pingJitterMax": "15s"
  }
}
```

Ручной импорт: приложение → Импорт → JSON-узел (вставить outbound
выше) либо ссылка `backuppc://` в поле ссылок.

## Сборка ядра для OneXray (патч libXray)

Приложение собирает ядро из checkout **XTLS/libXray** (артефакты:
`libXray.aar`, `libXray.so`, `libXray.dll`, `LibXray.xcframework`,
`bin/xray`). Протокол встраивается в этот checkout якорным патчем:

```bash
# соседние каталоги: onexray-репо и checkout libXray
git clone https://github.com/XTLS/libXray.git ../libXray
python3 core/libxray/patch.py --libxray-dir ../libXray
# дальше штатная сборка ядра
(cd ../libXray && python build/main.py <android|apple|windows|linux>)
```

Патч вносит (все правки проверяются по точным якорям, скрипт
идемпотентен):

- `xray/xray.go` — конвейер `newXrayInstance` (RunXray, TestXray и
  desktop-бинарь OneXrayCore проходят через него);
- `share/parse_share.go` + `share/backuppc.go` — парсинг `backuppc://`;
- `share/validate_outbound.go`, `share/marshal_share.go` — валидация и
  проекция backuppc-outbound при импорте ссылок/подписок;
- `go.mod` — `require backuppc-core` + `replace` на `core/` и
  `backuppc/` этого репозитория.

Проверенный ref libXray: `3c694b23290f9849fe52284a345ebd4343bc90cd`
(при обновлении REF скрипт откажется работать, если якоря изменились, —
обновите шаблоны в `core/libxray/patch.py`).

## Совместимость

- Сервер: репозиторий `xray-backuppc` (панель генерирует и ссылку
  `backuppc://`, и готовый outbound JSON — кнопка «Конфиг» у клиента).
- Протокол в ядре не поддерживает UDP (как http-outbound); TLS и
  маскировка обрабатываются внутри протокола, `streamSettings`
  игнорируются.
- `certFingerprint` (пиннинг SHA-256) приоритетнее `insecure`.

## Роутеры ASUS (asuswrt-merlin-xrayui)

Ядро — drop-in замена бинарника `xray` для [xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui):
совпадает CLI (`xray -c config.json [-c extra.json …] [-test]`,
`xray version`; несколько `-c` сливаются — объекты рекурсивно, массивы
конкатенацией, как в multi-json загрузчике Xray) и вывод версии
(`Xray 26.3.27 …` — зонд `xrayui_core_version` распознает). Прежние
подкоманды `run|test -config` сохранены для OneXray/скриптов.

Сборка для роутеров (статические бинарники, без libc):

```bash
make release-router    # core/bin/xray-linux-arm32-v7a + xray-linux-arm64-v8a
```

Развёртывание на роутере (SSH):

```bash
cp /opt/bin/xray /opt/bin/xray.orig        # бэкап оригинального ядра
scp core/bin/xray-linux-arm64-v8a root@router:/opt/bin/xray   # по arch
chmod 0755 /opt/bin/xray
sh /jffs/scripts/xrayui restart
```

Замечания:

- `xray version` дополнительно печатает строку «Custom core: backuppc
  outbound enabled» — по ней видно, что стоит патченное ядро;
- смена версии ядра из панели xrayui (`switch_xray_version`) скачает
  официальный Xray-core **без** протокола — после смены повторите
  развёртывание; определяйте рабочее ядро по `xray version`;
- `backuppc`-outbound берёт на себя TLS и HTTP/2 (маскировка
  BackupPC), `streamSettings` в JSON игнорируются (см. «Совместимость»);
- сборка конфига и импорт `backuppc://`-ссылок — средствами xrayui
  (протокол добавлен в реестр outbound-ов веб-интерфейса).
