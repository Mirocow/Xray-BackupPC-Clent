#!/usr/bin/env bash
# Живой E2E: реальный Go-сервер xray-backuppc ↔ чистый Dart-клиент
# (backuppc_dart). Проверяет wire-совместимость (ALPN h2, метаданные X-Backup-*,
# HMAC, VLESS, кадры ТЗ), целостность SHA-256, ротации чанков и скорость.
#
#   scripts/e2e_dart.sh [DOWN_MiB] [UP_MiB]
#
# Требования: go в PATH, dart в PATH, репозиторий сервера ../xray-backuppc.
set -euo pipefail

DOWN_MB="${1:-64}"
UP_MB="${2:-16}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$(dirname "$ROOT")/xray-backuppc}"
WORK="$(mktemp -d /tmp/backuppc-e2e.XXXXXX)"
PORT_SRV=18443
PORT_PNL=18444
PORT_TGT=18901
PORT_SOCKS=19086
UUID="52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90"

cleanup() {
  [ -n "${SRV_PID:-}" ] && kill "${SRV_PID}" 2>/dev/null || true
  [ -n "${TGT_PID:-}" ] && kill "${TGT_PID}" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> подготовка сертификата"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 5 -nodes -subj "/CN=backuppc.corp" 2>/dev/null

echo "==> сборка Go-сервера ($SERVER_REPO)"
(cd "$SERVER_REPO" && go build -o "$WORK/backuppc-server" ./cmd/backuppc-server)

cat > "$WORK/server.json" <<EOF
{
  "listen": "127.0.0.1:$PORT_SRV",
  "panelListen": "127.0.0.1:$PORT_PNL",
  "certFile": "$WORK/cert.pem",
  "keyFile": "$WORK/key.pem",
  "host": "backuppc.corp",
  "uuid": "$UUID",
  "managementMode": "ws",
  "maxSessionBytes": 8388608
}
EOF

cat > "$WORK/client.json" <<EOF
{
  "serverAddr": "127.0.0.1:$PORT_SRV",
  "uuid": "$UUID",
  "socksListen": "127.0.0.1:$PORT_SOCKS",
  "insecure": true,
  "transport": {
    "host": "backuppc.corp",
    "maxSessionBytes": 8388608,
    "maxSessionDuration": "30m",
    "backuppc": {"enabled": true, "idleOnly": true,
      "incrementalEvery": "25m", "incrementalMinBytes": 2097152,
      "incrementalMaxBytes": 8388608}
  }
}
EOF

echo "==> запуск таргета и сервера"
(cd "$ROOT/backuppc_dart" && dart run tool/e2e_target.dart "$PORT_TGT" > "$WORK/target.log" 2>&1) &
TGT_PID=$!
"$WORK/backuppc-server" -config "$WORK/server.json" > "$WORK/server.log" 2>&1 &
SRV_PID=$!
sleep 2

curl -s "http://127.0.0.1:$PORT_TGT/healthz" >/dev/null && echo "target: ok"
if ! grep -q "listen" "$WORK/server.log" 2>/dev/null && [ -s "$WORK/server.log" ]; then
  cat "$WORK/server.log"
fi

echo "==> прогон Dart-клиента: download ${DOWN_MB}MiB, upload ${UP_MB}MiB, лимит чанка 8MiB"
cd "$ROOT/backuppc_dart"
dart run tool/e2e_client.dart \
  --config "$WORK/client.json" \
  --target "127.0.0.1:$PORT_TGT" \
  --down "$DOWN_MB" --up "$UP_MB" | tee "$WORK/report.json"

echo "==> лог сервера (сессии/ротации):"
grep -E "session|chunk|rotat|backup" "$WORK/server.log" | tail -20 || true

if grep -q '"ok": true' "$WORK/report.json"; then
  echo "E2E DART: OK"
else
  echo "E2E DART: FAILED (см. $WORK)"
  exit 1
fi
