# syntax=docker/dockerfile:1
# Контейнерная сборка ядра/библиотек клиента xray-backuppc-clent.
#
# Требование проекта: ВСЕ сборки выполняются в контейнерах — тулчейны
# (Go/Dart) на хосте не нужны, окружение воспроизводимо и в CI.
#
#   make docker-build-core      core/bin/backuppc-xray (linux/amd64)
#   make docker-release-router  core/bin/xray-linux-arm{32-v7a,64-v8a}
#   make docker-test-ref        go test эталона (backuppc/ + core/)
#   make docker-test-dart       dart test протокола (52 теста)
#
# Артефакты выгружаются через `buildx build --output` (export-*,
# FROM scratch). Требуется Docker 23+ / buildx (BuildKit).
#
# Живой e2e (Go-сервер ↔ Dart-клиент) — отдельный файл
# build/Dockerfile.e2e (make docker-e2e-dart): ему нужен соседний
# репозиторий ../xray-backuppc как дополнительный контекст сборки.
#
# Образ безголового клиента (рантайм) — deploy/Dockerfile (make docker-build).

# ── Ядро: backuppc-xray с нативным outbound (linux/amd64) ──────────────
FROM golang:1.26-alpine AS core
WORKDIR /src
COPY backuppc/go.mod backuppc/backuppc.go ./backuppc/
COPY backuppc/internal/ ./backuppc/internal/
COPY core/go.mod core/go.sum ./core/
COPY core/backuppcpb/ ./core/backuppcpb/
COPY core/link/ ./core/link/
COPY core/outbound/ ./core/outbound/
COPY core/preprocess/ ./core/preprocess/
COPY core/cmd/ ./core/cmd/
RUN cd core && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/backuppc-xray ./cmd/backuppc-xray

# ── Ядро для роутеров ASUS/Merlin (drop-in замена xray) ────────────────
FROM core AS router
RUN cd core \
 && CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" \
      -o /out/xray-linux-arm32-v7a ./cmd/backuppc-xray \
 && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" \
      -o /out/xray-linux-arm64-v8a ./cmd/backuppc-xray

# ── Тесты Go-эталона: транспортная библиотека + ядро ───────────────────
# (debian-образ: gcc для совместимости с -race при локальных прогонах)
FROM golang:1.26-bookworm AS test-ref
WORKDIR /src
COPY backuppc/go.mod backuppc/backuppc.go ./backuppc/
COPY backuppc/internal/ ./backuppc/internal/
RUN cd backuppc && go test ./... -count=1 -timeout 600s
COPY core/go.mod core/go.sum ./core/
COPY core/backuppcpb/ ./core/backuppcpb/
COPY core/link/ ./core/link/
COPY core/outbound/ ./core/outbound/
COPY core/preprocess/ ./core/preprocess/
COPY core/cmd/ ./core/cmd/
RUN cd core && go test ./... -count=1 -timeout 600s

# ── Тесты Dart-протокола: backuppc_dart (вендорный http2 — path-деп) ───
FROM dart:3.13 AS test-dart
WORKDIR /src
# структура репо сохраняется: path-зависимость ../third_party/http2
COPY third_party/http2/ ./third_party/http2/
COPY backuppc_dart/ ./backuppc_dart/
RUN cd backuppc_dart \
 && dart pub get \
 && dart analyze \
 && dart test

# ── Экспорт артефактов (buildx --output) ───────────────────────────────
FROM scratch AS export-core
COPY --from=core /out/backuppc-xray /backuppc-xray

FROM scratch AS export-router
COPY --from=router /out/xray-linux-arm32-v7a /xray-linux-arm32-v7a
COPY --from=router /out/xray-linux-arm64-v8a /xray-linux-arm64-v8a
