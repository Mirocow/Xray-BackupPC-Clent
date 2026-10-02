# Разработка и отладка (DEVELOPMENT)

Инструментарий для работы над протоколом `xray-vless-backuppc` в этом
репозитории. Продуктовая реализация — **чистый Dart** (`backuppc_dart/` +
интеграция в `lib/`), все платформы OneXray. Краткая карта кода:

| Компонент | Где | Что |
|---|---|---|
| **Транспорт (Dart, продукт)** | `backuppc_dart/` | фрейминг, gRPC-несущий, VLESS, ротация чанков, эмуляция BackupPC, SOCKS5, share-ссылки |
| вендорный HTTP/2 | `third_party/http2` | форк с патчами флоу-контроля (`PATCHES.md`): окно 32 МиБ + батчинг WINDOW_UPDATE |
| Интеграция приложения | `lib/service/connect/backuppc/`, `lib/service/connect/compiler.dart` | туннель в изоляте, компиляция узла в socks-outbound, пинг, валидация |
| Go-эталон (тесты/bench) | `backuppc/` | та же библиотека на Go: контрактные тесты, нагрузочные инструменты |
| Нативное ядро Xray | `core/` (модуль `backuppc-core`) | альтернативный путь: backuppc-outbound в ядре (экспериментальный) |
| Безголовое ядро | `core/cmd/backuppc-xray/` | CLI: `run`/`test`, pprof-хук |
| Контейнеры | `deploy/` | Dockerfile клиента + compose-стеки |
| Сервер | соседний репозиторий `xray-backuppc` | серверная часть + панель + bench + `docs/PROTOCOL.md` (wire-спецификация) |

Архитектура и пользовательский контур Dart-реализации —
`docs/backuppc-protocol.md`.

## Быстрый старт

```bash
make help            # список всех целей

# Продукт: протокол //backuppc (Dart)
make test            # analyze + 52 теста транспорта (dart)
make analyze         # flutter analyze: весь код приложения
make test-app        # flutter test: ~1092 теста, вкл. интеграцию
make e2e-dart        # живой прогон: Go-сервер ↔ Dart-клиент (DOWN/UP, МиБ)

# Сборка приложения — все платформы OneXray (build_scripts/)
make build-android   # также: build-ios build-macos build-macos-se
                     #        build-windows (WINDOWS_MODE=exe|msix) build-linux
make verify-release  # проверка релизных артефактов

# Go-эталон (контрактные тесты/bench)
make test-ref        # все Go-тесты (библиотека + ядро)
make build-core      # core/bin/backuppc-xray
make e2e-ref         # живой прогон: сервер + ядро + curl (SHA-256)
```

Требуется Dart/Flutter SDK по `readme/FIRST_RUN.md`; для Go-эталона —
Go ≥ 1.22 (ядро `core/` — 1.26 по `go.mod`). GUI-сборка — `build_scripts/`
(секреты и требования — там же).

## Тестовая пирамида

1. **Юнит-тесты библиотеки** — `make test-dart`: фрейминг (`conn_test`),
   балансировщик, gRPC-обвязка, эмуляция заданий BackupPC, share-ссылки.
2. **E2E библиотеки** — там же: сервер+клиент in-process, ротации,
   анти-пробинг, псевдо-бэкапы, SHA-256 целостность.
3. **Приложение** — `make analyze` + `make test-app`: весь Flutter-сьют
   (~1092 теста), вкл. импорт/валидацию/экспорт `backuppc://` и
   компиляцию узла в socks-outbound.
4. **Живой E2E Dart ↔ Go-сервер** — `make e2e-dart`: реальный сервер
   соседнего репо, wire-совместимость (ALPN h2, `X-Backup-*`, HMAC,
   VLESS), SHA-256, ротации; объёмы — `DOWN=64 UP=16` (МиБ).
5. **Go-эталон** — `make test-ref` / `make test-ref-race` (контракт и
   гонки), включая живой инстанс Xray (socks-in + backuppc-outbound)
   против сервера библиотеки (`core/preprocess/e2e_xray_test.go`,
   регресс «обычные конфиги не затронуты»);
   `make e2e-stack` — полный стек сервер+ядро+таргет, 64+ МиБ, SHA-256.
   E2E-скрипты перед стартом проверяют порты: осиротевший процесс
   прошлого прогона → `FATAL: порт … уже слушается` (раньше давало
   ложный «SHA-256 не совпал»); таргет дополнительно пробуется напрямую.
6. **Нагрузка** — `make loadtest`: гигабайты с заданным лимитом чанка,
   количество ротаций и скорость в отчете; Dart-транспорт — `make
   layer-bench MODE=h2|tls` (профиль скорости по слоям).
7. **Патч libXray** — верифицируется сборкой и собственными тестами
   libXray (см. `core/libxray/README.md`), затем `make e2e-ref`.

## Отладка

### Ядро (backuppc-xray)

```bash
# pprof: горутины, аллокации, CPU (в контейнере тоже работает)
make debug-run CONF=app.json
# → http://127.0.0.1:6060/debug/pprof/
go tool pprof http://127.0.0.1:6060/debug/pprof/heap
go tool pprof http://127.0.0.1:6060/debug/pprof/profile?seconds=30

# уровень журнала — в конфиге
"log": {"loglevel": "debug"}
```

Отладочные точки: `BACKUPPC_PPROF=addr` (pprof-листенер). В
контейнере: `docker exec backuppc-client ...` + `BACKUPPC_PPROF`
пробрасывается через переменные compose.

### Библиотека (Go-эталон, transport)

- ключевые горутины: релей (`serveSocks`), джиттер-пинги
  (`spawnJitterKeepAlive`), балансировщик (`spawnTrafficBalancer`),
  планировщик псевдо-бэкапов (`spawnBackupPCJobs`), ротация
  (`performRotation` — писательский и читательский пути);
- логи: `slog` с компонентами `client`/`server`/`outbound`;
- гонки: `make test-ref-race` (обязательно после правок hub.go/session.go);
- при диагностике обрывов смотреть пары: клиент `session rotated` ↔
  сервер `session finished reason=...` (`ok`, `upstream-closed`,
  `client-closed`, `idle-timeout`).

### Dart-реализация (backuppc_dart)

- туннель — изолят: журналы приходят в общий лог с префиксом
  `backuppc tunnel:`;
- `make debug-tools` — список инструментов `backuppc_dart/tool/`;
- прогоны объёма против сервера (CONFIG — JSON конфига клиента,
  формат — как в `scripts/e2e_dart.sh`):
  ```bash
  make debug-download CONFIG=client.json DOWN=64   # SHA-256 верификация
  make debug-upload   CONFIG=client.json UP=16     # эхо-таргет
  make layer-bench    MODE=h2 MIB=256              # профиль слоёв TLS/H2
  ```
- прочее: `hash_bench.dart` (эталон скорости SHA-256), `det_stream.dart`
  (детерминированный поток для отладки сдвигов), `direct_check.dart`,
  `diff_analyze.dart` (поиск первой расходимости дампов);
- отладка флоу-контроля — `third_party/http2/PATCHES.md` (эффект
  патчей и как его замерять);
- при падении e2e: поднять сервер вручную (`make run` в серверном
  репо — напечатает адреса, токен и ссылку `backuppc://`) и гонять
  `make debug-download` с живыми логами обеих сторон.

### Сервер и панель

Сервер — соседний репозиторий: `make run` в нём поднимает dev-сервер с
панелью на :18444, pprof на :6060 и печатает токен админа + готовую
ссылку `backuppc://…` (или кнопка «Конфиг клиента» в панели).
Инструменты сервера (bench, delve, покрытие) — `docs/DEVELOPER.md` там.

## Тюнинг под большие объемы

| Параметр | Дефолт | Эффект |
|---|---|---|
| `maxSessionBytes` | 2 ГиБ | лимит чанка: ротация = новое TLS-рукопожатие (~2 мс) — на сотнях ГиБ ротации незаметны |
| `maxSessionDuration` | 30 м | срок чанка [0.5..1.5]× — маскировка длительности «задания бэкапа» |
| `maxWriteChunk` (settings) | 16384 | байт payload в кадре: 65535 = меньше кадров на гигабайт |
| `minTxThreshold`/`fakeUploadChunk` | 16 КБ/512 КБ | выравнивание плеч при асимметрии (rx≫tx на стриминге) |
| `BackupPC.idleOnly` | true | псевдо-задания только в простое — не мешают нагрузке |

Замеры (2 vCPU, см. `loadtest.sh`): ~256 МиБ/с через нативное ядро,
ротации при чистом скачивании работают (раньше upload-плечо гасило
ротацию после HalfClose — исправлено, тест `TestPureDownloadRotation`).

## Релизная проверка (чек-лист)

```bash
make analyze       # flutter analyze: весь код приложения
make test          # тесты протокола (анализ + 52 теста)
make test-app      # полный сьют приложения (~1092)
make e2e-dart      # живой Dart ↔ Go-сервер (SHA-256, ротации)
make lint-ref      # vet + gofmt эталона
make test-ref      # контрактные тесты Go-эталона
make e2e-stack     # полный стек (сервер + ядро + таргет)
make loadtest SIZE=1G CHUNK=64M   # ротации + целостность (эталон)
```

Docker: `make docker-build && make docker-stack` (полный стек:
сервер + клиент + таргет, см. `deploy/README.md`).
