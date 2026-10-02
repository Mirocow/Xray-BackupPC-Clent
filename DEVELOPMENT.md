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
# Dart-реализация (продукт)
(cd backuppc_dart && dart test)     # 52 теста транспорта
flutter analyze                     # весь код приложения
flutter test                        # 1092 теста, вкл. интеграцию
scripts/e2e_dart.sh                 # живой прогон: Go-сервер ↔ Dart-клиент

# Go-эталон (контрактные тесты/bench)
make help            # список целей
make test            # все Go-тесты (библиотека + ядро)
make build-core      # core/bin/backuppc-xray
make e2e             # живой прогон: сервер + ядро + curl (SHA-256)
```

Требуется Go ≥ 1.26 и Dart/Flutter SDK по `readme/FIRST_RUN.md`
(для сборки приложения — `build_scripts/`).

## Тестовая пирамида

1. **Юнит-тесты библиотеки** — `make test-go`: фрейминг (`conn_test`),
   балансировщик, gRPC-обвязка, эмуляция заданий BackupPC.
2. **E2E библиотеки** — там же: сервер+клиент in-process, ротации,
   анти-пробинг, псевдо-бэкапы, SHA-256 целостность, `-race` (`make test-race`).
3. **E2E нативного ядра** — `make test-core`: живой инстанс Xray
   (socks-in + backuppc-outbound) против сервера из библиотеки
   (`core/preprocess/e2e_xray_test.go`), включая регресс «обычные
   конфиги не затронуты».
4. **Сквозной стек** — `make e2e-stack`: сервер `xray-backuppc` +
   безголовое ядро + HTTP-таргет, 64+ МиБ, SHA-256, метрики сессий.
5. **Нагрузка** — `make loadtest`: гигабайты с заданным лимитом чанка,
   количество ротаций и скорость в отчете.
6. **Патч libXray** — верифицируется сборкой и собственными тестами
   libXray (см. `core/libxray/README.md`), затем `make e2e`.

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

### Библиотека (transport)

- ключевые горутины: релей (`serveSocks`), джиттер-пинги
  (`spawnJitterKeepAlive`), балансировщик (`spawnTrafficBalancer`),
  планировщик псевдо-бэкапов (`spawnBackupPCJobs`), ротация
  (`performRotation` — писательский и читательский пути);
- логи: `slog` с компонентами `client`/`server`/`outbound`;
- гонки: `make test-race` (обязательно после правок hub.go/session.go);
- при диагностике обрывов смотреть пары: клиент `session rotated` ↔
  сервер `session finished reason=...` (`ok`, `upstream-closed`,
  `client-closed`, `idle-timeout`).

### Dart-реализация (backuppc_dart)

- туннель — изолят: журналы приходят в общий лог с префиксом
  `backuppc tunnel:`;
- `backuppc_dart/tool/`: `debug_download.dart` / `debug_upload.dart`
  (прогон объёма против сервера с верификацией), `layer_bench.dart`
  (профиль скорости по слоям: TLS / H2 / кадры / VLESS),
  `hash_bench.dart`, `det_stream.dart` (детерминированный поток для
  отладки сдвигов), `direct_check.dart`;
- отладка флоу-контроля — `third_party/http2/PATCHES.md` (эффект
  патчей и как его замерять);
- при падении e2e: поднять сервер вручную (`make e2e-stack` в серверном
  репо) и гонять `debug_download` с живыми логами обеих сторон.

### Сервер и панель

Сервер — соседний репозиторий (`make e2e-stack` поднимает его с
панелью на :18444). Токен админа печатается в журнал сервера. Оттуда
же берется ссылка `backuppc://…` для клиента (кнопка «Конфиг клиента»).

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
make lint          # vet + gofmt
make test          # все тесты
make test-race     # гонки
make e2e           # нативный живой прогон
make e2e-stack     # полный стек
make loadtest SIZE=1G CHUNK=64M   # ротации + целостность
```

Docker: `make docker-build && make docker-stack` (полный стек:
сервер + клиент + таргет, см. `deploy/README.md`).
