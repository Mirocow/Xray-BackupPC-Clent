# Deploy: клиент в Docker

Безголовое развертывание клиента туннеля **Backup-Emulator** — в
контейнере работает `backuppc-xray` (ядро Xray с **нативным
backuppc-outbound**): локальный SOCKS5 → VLESS → gRPC/HTTP2-TLS →
сервер `xray-backuppc`. Протокол встроен в ядро как обычный outbound
(см. `core/`), поэтому контейнер — это полноценный Xray, и обычные
конфиги (freedom/vless/socks) работают без изменений.

GUI-приложение (Flutter) нативный outbound **не использует**: узел
`backuppc://` там компилируется в socks-outbound на локальный
Dart-туннель (`docs/backuppc-protocol.md`). Ядро с нативным outbound —
путь безголового клиента: Linux-хосты, роутеры, VPS, шлюзы, CI.

## Одиночный клиент

```bash
# сборка (контекст — корень репозитория)
docker build -f deploy/Dockerfile -t backuppc-client .

# запуск с генерацией конфига из переменных
docker run -d --name backuppc-client \
  -p 127.0.0.1:1080:1080 \
  -e BACKUPPC_SERVER=vpn.example.com:8443 \
  -e BACKUPPC_UUID=01234567-89ab-cdef-0123-456789abcdef \
  -e BACKUPPC_CERT_FP=sha256hex... \
  backuppc-client

# или с готовым конфигом
docker run -d --name backuppc-client \
  -p 127.0.0.1:1080:1080 \
  -v $PWD/xray.example.json:/etc/backuppc/xray.json:ro \
  backuppc-client

# проверка
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

Compose: `BACKUPPC_SERVER=... BACKUPPC_UUID=... docker compose -f
deploy/docker-compose.yml up -d`.

## Переменные entrypoint

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `BACKUPPC_SERVER` | адрес сервера `host:port` | — (обязательно) |
| `BACKUPPC_UUID` | UUID пользователя VLESS | — (обязательно) |
| `BACKUPPC_SOCKS` | локальный SOCKS5-листенер | `0.0.0.0:1080` |
| `BACKUPPC_HOST` | домен-донор SNI/Host | `backup.local` |
| `BACKUPPC_ENDPOINTS` | пути несущих вызовов (запятая) | пул сервера |
| `BACKUPPC_CERT_FP` | SHA-256 (hex) сертификата — пиннинг | — |
| `BACKUPPC_INSECURE` | `1` — пропустить TLS-верификацию | — |
| `BACKUPPC_LOGLEVEL` | debug … error | `warning` |
| `BACKUPPC_CONFIG` | путь конфига | `/etc/backuppc/xray.json` |

UUID и ссылку `backuppc://…` выдает панель сервера (кнопка «Конфиг
клиента»): `endpoints` в ссылке — источники для `BACKUPPC_ENDPOINTS`.

## Полный стек (сервер + клиент + таргет)

Локальная проверка связки end-to-end:

```bash
# образы из соседних клонов репозиториев
git clone http://178.140.10.58:8082/routers/vpn/xray-backuppc ../xray-backuppc
docker build -t backuppc-server ../xray-backuppc
docker build -f deploy/Dockerfile -t backuppc-client .

docker compose -f deploy/docker-compose.stack.yml up
curl -v --socks5-hostname 127.0.0.1:1080 http://127.0.0.1:18080/
```

- `backuppc-server` — транспорт 8443 + панель 8444 (токен в журнале:
  `docker logs backuppc-stack-server`);
- `backuppc-client` — SOCKS5 на 127.0.0.1:1080;
- `target` — файловый HTTP-таргет (кладите файлы в `deploy/target-www/`).

Положите большой файл в `target-www/` и качайте его через туннель —
журнал клиента покажет ротации чанков, сервера — сессии «бэкапов».

## Замечания по безопасности

- продакшн: `BACKUPPC_CERT_FP` (пиннинг) вместо `BACKUPPC_INSECURE`;
- порт SOCKS публикуйте только на `127.0.0.1` (или за своим фаерволом);
- образ без root (uid 10001), `cap_drop: ALL`, `no-new-privileges`.
