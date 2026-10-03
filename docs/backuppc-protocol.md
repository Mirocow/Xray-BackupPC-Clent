# Протокол `//backuppc` в OneXray (Dart-реализация)

Протокол `backuppc` — антисенсорный транспорт, маскирующийся под поток
периодических бэкапов BackupPC (VLESS поверх gRPC/HTTP2+TLS с рандомным
паддингом, эмуляцией расписания бэкапов и защитой от активного
зондирования ТСПУ/DPI). В клиенте реализован **целиком на Dart/Flutter** —
на языке приложения, без Go-прослойки и нативных артефактов: OneXray
собирается на всех поддерживаемых платформах (iOS, macOS, Android,
Windows, Linux), а `//backuppc` отображается в интерфейсе как
альтернативный протокол в ряду vless/vmess/trojan/shadowsocks.

Wire-спецификация протокола — `docs/PROTOCOL.md` в серверном репозитории
`xray-backuppc` (источник истины, v1.1: IPv6-нормализация, idle-пинги,
диал-фейл≠зонд, кадры 64 КиБ), обязательный для обеих реализаций.
Серверная часть и веб-панель — там же.

## Архитектура в приложении

```
TUN/системный inbound → Xray-ядро (libXray, FFI)
    → socks-outbound "app-entry-N" (127.0.0.1:<port>)
        → SOCKS5-фронтенд Dart-туннеля (выделенный изолят)
            → backuppc_dart: VLESS-запрос → кадры → чанки
                → gRPC-сообщения → HTTP/2 POST (ALPN h2, TLS)
                    → Backup-Emulator сервер
```

Протокол не встраивается в Xray-ядро: узел `backuppc` компилируется в
обычный `socks`-outbound, указывающий на локальный Dart-туннель.
Туннели всех backuppc-узлов соединения живут в **одном выделенном
изоляте** — сокеты не передаются между изолятами, поэтому тяжёлый
трафик (8K-видео, сотни ГиБ) не грузит UI-цикл.

## Карта кода

| Компонент | Где | Что |
|---|---|---|
| Транспортная библиотека | `backuppc_dart/` | слои 1–2 протокола: кадры, gRPC-несущий, VLESS, ротация чанков, эмуляция BackupPC, SOCKS5, share-ссылки |
| вендорный HTTP/2 | `third_party/http2` | форк `package:http2` с патчами флоу-контроля (см. `PATCHES.md`) |
| Интеграция соединения | `lib/service/connect/backuppc/` | outbound-модель, туннель-сервис, пинг, валидация |
| Компилятор конфига | `lib/service/connect/compiler.dart` | backuppc-узел → socks-outbound + direct-правила (анти-петля TUN) |
| Импорт/экспорт | `lib/service/shared/share/xray_share_reader.dart`, `lib/pages/shared/share/controller.dart` | `backuppc://`-ссылки: парсинг/генерация |
| Go-эталон | `backuppc/` | та же библиотека на Go: база контрактных тестов, bench, безголовые инструменты |

## Пользовательский контур

1. **Импорт**: панель сервера → «Конфиг клиента» → ссылка
   `backuppc://uuid@host:port?host=&fp=&endpoints=…#Имя` → OneXray
   «Импорт» (или QR). Строки `backuppc://` парсятся Dart-кодом до
   нативного конвертера; битая ссылка — ошибка ввода.
2. **Список серверов**: узел отображается как `BACKUPPC`; пинг —
   TCP-латентность до VPN-сервера узла.
3. **Редактирование**: JSON outbound-а (`protocol: "backuppc"`,
   `settings.serverAddr/uuid/host/endpointPaths/…`); валидация —
   Dart-валидатор (нативный `testXray` протокола не знает).
4. **Подключение**: узел используется как любой другой — entry,
   exit, цепочки, custom-роутинг; туннели стартуют/останавливаются
   с соединением, переживают перезапуск приложения при живом VPN.
5. **Экспорт**: «Поделиться» → `backuppc://`-ссылка или QR;
   `onexray://`-обёртка работает как для остальных протоколов.

## Скорость (8K-видео, сотни ГиБ)

- пулы буферов `Uint8List` (2K/32K/128K) — без аллокаций на кадр;
- стриминг кадрами по 64 КиБ (`maxWriteChunk` 65535, дефолт с MR !19 —
  −75% сисколов против 16 КиБ), ротация чанков 2 ГиБ/30 мин без
  разрыва VLESS-потока (handoff 3 с);
- вендорный http2: connection window 32 МиБ + батчинг WINDOW_UPDATE
  (патчи протокольно-легальны, RFC 7540) — ~54 МиБ/с и выше через
  один POST-стрим против ~7 у апстрима;
- изолят туннеля: перенос и копирование не пересекаются с UI.

Замеры: `backuppc_dart/tool/layer_bench.dart`, `tool/hash_bench.dart`;
живой прогон — `scripts/e2e_dart.sh` (реальный Go-сервер, SHA-256,
ротации).

## Тестовая пирамида

| Уровень | Команда | Что покрывает |
|---|---|---|
| Пакет `backuppc_dart` | `dart test` (из `backuppc_dart/`) | 52 теста: wire-контракты кадров/VLESS/ссылок/конфига, e2e против fake-сервера (H2+TLS, HMAC, ротации, SHA-256) |
| Приложение | `flutter test` | 1092 теста, включая интеграцию компилятора/подготовки/рантайма, сплит `backuppc://`, смешанную валидацию |
| Живой e2e | `scripts/e2e_dart.sh` | реальный сервер (`../xray-backuppc`) ↔ реальный Dart-клиент: 64 МиБ download + 16 МиБ upload, SHA-256, 8 ротаций |
| Go-эталон | `make test-go` в `backuppc/` | те же контракты на Go — кросс-проверка реализаций |

Изменение wire-формата без зелёного `e2e_dart.sh` не принимается.

## Настройки outbound

```json
{
  "protocol": "backuppc",
  "settings": {
    "serverAddr": "host:port",
    "uuid": "…",
    "host": "домен-донор SNI",
    "certFingerprint": "sha256-hex (пиннинг)",
    "insecure": false,
    "userAgent": "…",
    "endpointPaths": ["/backuppc.BackupService/BackupStream", "…"],
    "minPaddingSize": 32, "maxPaddingSize": 1400,
    "maxSessionBytes": 2147483648, "maxSessionDuration": "30m",
    "maxWriteChunk": 65535
  },
  "streamSettings": {
    "security": "tls",
    "tlsSettings": {
      "serverName": "домен-донор",
      "allowInsecure": false,
      "pinnedPeerCertificateSha256": ["sha256-hex"],
      "certFingerprint": "sha256-hex"
    }
  }
}
```

Схема идентична Go-библиотеке; `backuppc://`-ссылка разворачивается
в этот же формат (и наоборот — для экспорта). `endpoints` обязателен:
без него клиент ротирует чанки по дефолтному пулу путей, который
сервер отвергает как проб-активность.

### TLS

Несущий канал — HTTP/2+TLS, встроен в протокол: `network` (транспорт)
не настраивается, редактируется только TLS (`security: "tls"`).
Поля `settings` (`host`, `insecure`, `certFingerprint`) и
`streamSettings.tlsSettings` (`serverName`, `allowInsecure`,
`pinnedPeerCertificateSha256`) — одно и то же: ядро синхронизирует их
двусторонне при загрузке конфига (preprocess `mergeTLSSettings`),
явные поля в `settings` выигрывают. Отпечаток сертификата
(`fp=` в ссылке) — предпочтительный режим доверия; `insecure`
только для тестов. uTLS-отпечаток клиента не поддерживается —
TLS-профиль задаёт транспортная библиотека.

### IPv6-таргеты

Адреса вида `[2a00:…]` (формат `ipv6Address.String()` xray-core)
нормализуются до кодирования в VLESS: скобки снимаются на клиенте,
сервер дополнительно нормализует «домен-тип», парсящийся как IPv6.
Иначе сервер оборачивал адрес повторно и диал падал
(`dial tcp: address [[…]]:443: missing port`).

## Платформы

Реализация — чистый Dart (`dart:io`, `dart:isolate`): нативные
артефакты libXray не меняются, все платформы OneXray собираются из
одного кода. Ограничение платформы то же, что у приложения в целом
(веб-сборки не существует для VPN-клиента). Проверка: `flutter analyze`
+ `flutter test` компилируют весь код приложения; платформенные
сборки — `build_scripts/` (CI репозитория).
