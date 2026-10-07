#!/usr/bin/env bash
# e2e_stack.sh — полный локальный стек БЕЗ Docker: сервер xray-backuppc +
# безголовое ядро Xray (backuppc-outbound) + HTTP-таргет, проверка
# целостности (SHA-256) большого файла через туннель.
#
# Отличие от core/e2e_native.sh: использует большой объем (по умолчанию
# 64 МиБ), включает панель сервера и печатает метрики сессий/ротаций.
# Требует рядом клон репозитория xray-backuppc.
#
# Переменные: SIZE (МиБ, дефолт 64), SERVER_REPO (дефолт ../xray-backuppc)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$REPO_ROOT/../xray-backuppc}"
SIZE="${SIZE:-64}"
GO=go; command -v go >/dev/null 2>&1 || GO="$HOME/.local/go/bin/go"

UUID="e2e11e2e-11e2-11e2-11e2-11e2e2e2e2e1"
PORT_SOCKS=10808
PORT_SRV=18443
PORT_PANEL=18444
PORT_TARGET=18080
WORK="$(mktemp -d /tmp/backuppc-stack.XXXXXX)"

# Порт уже слушается (осиротевший процесс прошлого прогона) → молча
# занятый порт и ложный FAIL: curl получит чужой файл. Проверяем до старта.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "$PORT_TARGET" "$PORT_SOCKS" "$PORT_SRV" "$PORT_PANEL"; do
  if port_busy "$p"; then
    echo "FATAL: порт $p уже слушается — осиротевший процесс прошлого прогона?" >&2
    echo "       найдите и завершите его: ss -ltnp | grep :$p" >&2
    exit 1
  fi
done

cleanup() {
  [[ -n "${CORE_PID:-}" ]] && kill "$CORE_PID" 2>/dev/null || true
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true
  [[ -n "${TGT_PID:-}" ]] && kill "$TGT_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> сборка ядра и сервера"
(cd "$REPO_ROOT/core" && "$GO" build -trimpath -o "$WORK/backuppc-xray" ./cmd/backuppc-xray)
(cd "$SERVER_REPO" && "$GO" build -trimpath -o "$WORK/backuppc-server" ./cmd/backuppc-server)

echo "==> HTTP-таргет ($PORT_TARGET): файл ${SIZE} МиБ"
mkdir -p "$WORK/www"
head -c $((SIZE * 1048576)) /dev/urandom > "$WORK/www/file.bin"
sha_target="$(sha256sum "$WORK/www/file.bin" | cut -d' ' -f1)"
# напрямую с --directory: TGT_PID — PID самого python3, cleanup его завершит
python3 -m http.server "$PORT_TARGET" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
TGT_PID=$!
sleep 0.5
# прямая проба таргета ДО туннеля: таргет поднялся и отдаёт именно наш файл
sha_probe="$(curl -fsS --max-time 30 "http://127.0.0.1:$PORT_TARGET/file.bin" | sha256sum | cut -d' ' -f1)"
if [[ "$sha_probe" != "$sha_target" ]]; then
  echo "FATAL: HTTP-таргет не отдаёт наш файл (порт $PORT_TARGET занят или не стартовал)" >&2
  exit 1
fi

echo "==> backuppc-server (транспорт :$PORT_SRV, панель :$PORT_PANEL)"
cat > "$WORK/server.json" <<EOF
{
  "listen": "127.0.0.1:$PORT_SRV",
  "uuid": "$UUID",
  "transport": {"host": "backup.local", "maxSessionDuration": "45m"},
  "panelListen": "127.0.0.1:$PORT_PANEL"
}
EOF
"$WORK/backuppc-server" -config "$WORK/server.json" -data "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV_PID=$!
sleep 0.5

echo "==> ядро Xray с backuppc-outbound (SOCKS5 :$PORT_SOCKS)"
cat > "$WORK/app.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "socksIn", "protocol": "socks",
    "listen": "127.0.0.1", "port": $PORT_SOCKS,
    "settings": {"auth": "noauth", "udp": false}
  }],
  "outbounds": [
    {"tag": "proxy", "protocol": "backuppc",
     "settings": {"serverAddr": "127.0.0.1:$PORT_SRV", "uuid": "$UUID",
                  "insecure": true,
                  "endpoints": "/backuppc.BackupService/BackupStream,/backuppc.ChunkService/PutChunk,/backuppc.StorageService/UploadStream"}},
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF
"$WORK/backuppc-xray" run -config "$WORK/app.json" > "$WORK/core.log" 2>&1 &
CORE_PID=$!
sleep 1

echo "==> скачивание ${SIZE} МиБ через SOCKS5 → VLESS → gRPC/HTTP2-TLS"
start=$(date +%s.%N)
sha_got="$(curl -sS --socks5-hostname "127.0.0.1:$PORT_SOCKS" \
  "http://127.0.0.1:$PORT_TARGET/file.bin" | sha256sum | cut -d' ' -f1)"
end=$(date +%s.%N)

dur=$(echo "$end $start" | awk '{printf "%.1f", $1-$2}')
mbps=$(echo "$SIZE $dur" | awk '{printf "%.1f", $1/$2}')

if [[ "$sha_target" == "$sha_got" ]]; then
  echo "OK: SHA-256 совпал — ${SIZE} МиБ за ${dur} c (~${mbps} МиБ/с), потерь нет"
  echo "--- метрики сервера (панель http://127.0.0.1:$PORT_PANEL) ---"
  grep -E "session (registered|finished)" "$WORK/server.log" | tail -5 || true
  echo "--- журнал ядра (ротации чанков) ---"
  grep -E "rotated|backup job" "$WORK/core.log" | tail -5 || true
  exit 0
fi
echo "FAIL: SHA-256 не совпал"
tail -5 "$WORK/core.log" || true
exit 1
