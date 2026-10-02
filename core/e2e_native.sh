#!/usr/bin/env bash
# e2e_native.sh — живой сквозной прогон нативного протокола backuppc:
#
#   curl → SOCKS5-inbound ядра Xray (backuppc-xray) → диспетчер →
#   backuppc outbound (VLESS + чанки gRPC-канала, маскировка BackupPC) →
#   backuppc-server → HTTP-таргет.
#
# Требования: go, python3, curl. Запуск из core/ репозитория клиента:
#   ./e2e_native.sh
set -euo pipefail

CORE_DIR="$(cd "$(dirname "$0")" && pwd)"      # каталог core/ этого репозитория
REPO_ROOT="$(cd "$CORE_DIR/.." && pwd)"           # корень репо клиента
SERVER_REPO="${SERVER_REPO:-$REPO_ROOT/../xray-backuppc}"   # репо сервера (сосед)
WORK="$(mktemp -d /tmp/backuppc-e2e.XXXXXX)"
PORT_SOCKS=10808
PORT_SRV=18443
PORT_TARGET=18080

cleanup() {
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true
  [[ -n "${CORE_PID:-}" ]] && kill "$CORE_PID" 2>/dev/null || true
  [[ -n "${TGT_PID:-}" ]] && kill "$TGT_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> сборка ядра backuppc-xray и сервера"
GO=go; command -v go >/dev/null || GO="$HOME/.local/go/bin/go"
(cd "$CORE_DIR" && "$GO" build -o "$WORK/backuppc-xray" ./cmd/backuppc-xray)
(cd "$SERVER_REPO" && "$GO" build -o "$WORK/backuppc-server" ./cmd/backuppc-server)

UUID="e2e11e2e-11e2-11e2-11e2-11e2e2e2e2e1"

echo "==> HTTP-таргет ($PORT_TARGET)"
mkdir -p "$WORK/www"
head -c 2097152 /dev/urandom > "$WORK/www/file.bin"
sha_target="$(sha256sum "$WORK/www/file.bin" | cut -d' ' -f1)"
(cd "$WORK/www" && python3 -m http.server "$PORT_TARGET" --bind 127.0.0.1 >/dev/null 2>&1) &
TGT_PID=$!

echo "==> backuppc-server ($PORT_SRV)"
cat > "$WORK/server.json" <<EOF
{
  "listen": "127.0.0.1:$PORT_SRV",
  "uuid": "$UUID",
  "transport": {
    "host": "backup.local",
    "endpointPaths": ["/backuppc.BackupService/BackupStream"],
    "maxSessionDuration": "45m"
  }
}
EOF
"$WORK/backuppc-server" -config "$WORK/server.json" -data "$WORK" > "$WORK/server.log" 2>&1 &
SRV_PID=$!
sleep 0.5

echo "==> ядро Xray с backuppc-outbound (SOCKS5 $PORT_SOCKS)"
cat > "$WORK/app.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "socksIn", "protocol": "socks",
    "listen": "127.0.0.1", "port": $PORT_SOCKS,
    "settings": {"auth": "noauth", "udp": false}
  }],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "backuppc",
      "settings": {"serverAddr": "127.0.0.1:$PORT_SRV", "uuid": "$UUID", "insecure": true}
    },
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF
# легаси-стиль (OneXray, скрипты) + стиль xray (контракт роутера xrayui)
"$WORK/backuppc-xray" test -config "$WORK/app.json" >/dev/null
"$WORK/backuppc-xray" -c "$WORK/app.json" -test >/dev/null
"$WORK/backuppc-xray" version | head -1
"$WORK/backuppc-xray" -c "$WORK/app.json" > "$WORK/core.log" 2>&1 &
CORE_PID=$!
sleep 1

echo "==> скачивание 2 МиБ через нативный туннель"
sha_got="$(curl -sS --socks5-hostname "127.0.0.1:$PORT_SOCKS" \
  "http://127.0.0.1:$PORT_TARGET/file.bin" | sha256sum | cut -d' ' -f1)"

if [[ "$sha_target" == "$sha_got" ]]; then
  echo "OK: SHA-256 совпал — нативный backuppc-outbound доставил файл без потерь"
  echo "--- журнал сервера (последние строки)"
  tail -n 3 "$WORK/server.log" || true
  exit 0
fi
echo "FAIL: SHA-256 не совпал"
exit 1
