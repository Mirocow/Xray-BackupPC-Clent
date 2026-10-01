# libXray patch — встраивание backuppc в сборку ядра

`patch.py` превращает чистый checkout [XTLS/libXray](https://github.com/XTLS/libXray)
в кастомную сборку с нативным протоколом backuppc. Полная документация —
[core/README.md](../README.md).

```bash
python3 patch.py --libxray-dir /path/to/libXray [--skip-tidy]
```

Что делает:

| Файл libXray | Правка |
|---|---|
| `xray/xray.go` | импорт `backuppc-core/preprocess`; `newXrayInstance` прогоняет JSON через Normalize → LoadConfig → Apply (покрывает RunXray, TestXray, desktop-бинарь) |
| `share/parse_share.go` | `backuppc://` в списке схем + ветка switch |
| `share/backuppc.go` | новый файл: парсинг ссылки → `conf.OutboundDetourConfig` + валидатор settings |
| `share/validate_outbound.go` | backuppc-outbound валидируется своим валидатором в `filterBuildableOutbounds` |
| `share/marshal_share.go` | проекция полей settings в `projectShareOutbound` + валидация в `validateProjectedShareOutbound` |
| `go.mod` | `require backuppc-core` + `replace backuppc-core => <core>` + `replace backuppc => <backuppc>` |

Якорные правки проверяются на ровно одно вхождение; при несовпадении
(обновили LIBXRAY_REF и исходники ушли) скрипт падает с указанием, какой
якор не нашелся. Идемпотентен: повторный запуск — no-op. `go mod tidy`
запускается в конце (флаг `--skip-tidy` отключает), чтобы go.sum был
полон для gomobile.

`files/share_backuppc.go.template` — исходник файла, копируемого в
`share/backuppc.go` (шаблон, не компилируемый в core/).

Проверенный ref: `3c694b23290f9849fe52284a345ebd4343bc90cd`.
