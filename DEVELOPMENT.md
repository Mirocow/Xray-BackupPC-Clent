# Разработка и отладка (DEVELOPMENT)

Инструментарий для работы над протоколом `xray-vless-backuppc` в этом
репозитории. Краткая карта кода:

| Компонент | Где | Что |
|---|---|---|
| Библиотека транспорта (слои 1–2) | `backuppc/internal/backupemulator/` | фрейминг, gRPC-несущий канал, VLESS, ротация чанков, эмуляция BackupPC |
| Нативное ядро Xray (слой 3) | `core/` (модуль `backuppc-core`) | backuppc-outbound в реестре Xray, препроцессор JSON, share-ссылки |
| Безголовое ядро | `core/cmd/backuppc-xray/` | CLI: `run`/`test`, pprof-хук |
| Патч libXray | `core/libxray/patch.py` | интеграция протокола в OneXray (desktop-бинарь) |
| Контейнеры | `deploy/` | Dockerfile клиента + compose-стеки |
| Сервер | соседний репозиторий `xray-backuppc` | серверная часть + панель + bench |

## Быстрый старт

```bash
make help            # список целей
make test            # все Go-тесты (библиотека + ядро)
make build-core      # core/bin/backuppc-xray
make e2e             # живой прогон: сервер + ядро + curl (SHA-256)
```

Требуется Go ≥ 1.26 (тулчейн скачивается автоматически), для Flutter-сборки — `build_scripts/`.

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
