# Backup-Emulator client — контейнер безголового ядра Xray.
#
# В контейнере работает backuppc-xray (ядро Xray с нативным backuppc-
# outbound): локальный SOCKS5-вход → VLESS → gRPC/HTTP2-TLS → сервер
# xray-backuppc (маскировка потока периодических бекапов BackupPC).
# GUI-приложение OneXray (Flutter) использует это же ядро на десктопах,
# контейнер покрывает серверные/беспроводные сценарии (роутеры, VPS).
#
# Сборка (контекст — КОРЕНЬ репозитория):
#   docker build -f deploy/Dockerfile -t backuppc-client .
#
# Конфиг: монтируется в /etc/backuppc/xray.json ЛИБО генерируется
# entrypoint-скриптом из переменных окружения (см. deploy/entrypoint.sh).
#
# Запуск:
#   docker run -d --name backuppc-client \
#     -p 1080:1080 \
#     -e BACKUPPC_SERVER=vpn.example.com:8443 \
#     -e BACKUPPC_UUID=01234567-89ab-cdef-0123-456789abcdef \
#     backuppc-client
#
# Полный стек (сервер + клиент + таргет): deploy/docker-compose.stack.yml.

FROM golang:1.26-alpine AS build
WORKDIR /src

# модуль протокола (слои 1–2) и ядро с нативным outbound (слой 3)
COPY backuppc/go.mod ./backuppc/go.mod
COPY backuppc/backuppc.go ./backuppc/backuppc.go
COPY backuppc/internal/ ./backuppc/internal/
COPY core/go.mod core/go.sum ./core/
COPY core/backuppcpb/ ./core/backuppcpb/
COPY core/link/ ./core/link/
COPY core/outbound/ ./core/outbound/
COPY core/preprocess/ ./core/preprocess/
COPY core/cmd/ ./core/cmd/

RUN cd core && CGO_ENABLED=0 GOFLAGS=-mod=mod \
    go build -trimpath -ldflags="-s -w" \
    -o /out/backuppc-xray ./cmd/backuppc-xray

FROM alpine:3.19
RUN adduser -D -u 10001 backuppc && \
    apk add --no-cache ca-certificates
COPY --from=build /out/backuppc-xray /usr/local/bin/backuppc-xray
COPY deploy/entrypoint.sh /usr/local/bin/backuppc-entrypoint
USER backuppc
EXPOSE 1080
VOLUME /etc/backuppc
ENTRYPOINT ["backuppc-entrypoint"]
