#!/usr/bin/env bash
# loadtest.sh — пропускная способность нативного туннеля (SOCKS5 →
# VLESS → gRPC/HTTP2-TLS → BackupPC-мимикрия) на больших объемах.
#
# Стек как в e2e_stack.sh, но замер с curl и ротациями чанков:
# по умолчанию лимит чанка 64 МиБ → на каждом гигабайте видно ~16
# ротаций в журнале ядра (полностью новые TLS-рукопожатия).
#
# Переменные: SIZE=512M (МиБ/ГиБ), CHUNK=64M, PARALLEL=1 (потоки curl)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$REPO_ROOT/../xray-backuppc}"
SIZE="${SIZE:-512M}"
CHUNK="${CHUNK:-64M}"
PARALLEL="${PARALLEL:-1}"
GO=go; command -v go >/dev/null 2>&1 || GO="$HOME/.local/go/bin/go"

case "$CHUNK" in
  *G|*g) chunk_bytes=$(( $(echo "${CHUNK%[Gg]}") * 1073741824 )) ;;
  *M|m) chunk_bytes=$(( $(echo "${CHUNK%[Mm]}") * 1048576 )) ;;
  *K|*k) chunk_bytes=$(( $(echo "${CHUNK%[Kk]}") * 1024 )) ;;
  *) chunk_bytes="$CHUNK" ;;
esac

UUID="e2e11e2e-11e2-11e2-11e2-11e2e2e2e2e1"
PORT_SOCKS=10809
PORT_SRV=18445
PORT_TARGET=18081
WORK="$(mktemp -d /tmp/backuppc-load.XXXXXX)"

# Порт уже слушается (осиротевший процесс прошлого прогона) → молча
# занятый порт и ложный результат замера. Проверяем до старта.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "$PORT_TARGET" "$PORT_SOCKS" "$PORT_SRV"; do
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

echo "==> сборка"
(cd "$REPO_ROOT/core" && "$GO" build -trimpath -o "$WORK/backuppc-xray" ./cmd/backuppc-xray)
(cd "$SERVER_REPO" && "$GO" build -trimpath -o "$WORK/backuppc-server" ./cmd/backuppc-server)

echo "==> таргет: детерминированный поток ${SIZE} (можно сверить SHA-256)"
mkdir -p "$WORK/www"
case "$SIZE" in
  *G|*g) bytes=$(( $(echo "${SIZE%[Gg]}") * 1073741824 )) ;;
  *M|m) bytes=$(( $(echo "${SIZE%[Mm]}") * 1048576 )) ;;
  *) bytes="$SIZE" ;;
esac
# /dev/urandom по объему + sha256 на лету
head -c "$bytes" /dev/urandom > "$WORK/www/file.bin"
sha_target="$(sha256sum "$WORK/www/file.bin" | cut -d' ' -f1)"
# напрямую с --directory: TGT_PID — PID самого python3, cleanup его завершит
python3 -m http.server "$PORT_TARGET" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
TGT_PID=$!
sleep 0.5
# доступность таргета (HEAD): полный SHA-прогон не делаем — объемы большие
curl -fsSI --max-time 10 "http://127.0.0.1:$PORT_TARGET/file.bin" >/dev/null || {
  echo "FATAL: HTTP-таргет не отвечает (порт $PORT_TARGET занят или не стартовал)" >&2
  exit 1
}

cat > "$WORK/server.json" <<EOF
{
  "listen": "127.0.0.1:$PORT_SRV",
  "uuid": "$UUID",
  "transport": {"host": "backup.local", "maxSessionBytes": $chunk_bytes, "maxSessionDuration": "45m"},
  "panelListen": ""
}
EOF
"$WORK/backuppc-server" -config "$WORK/server.json" -data "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV_PID=$!

cat > "$WORK/app.json" <<EOF
{
  "log": {"loglevel": "info"},
  "inbounds": [{
    "tag": "socksIn", "protocol": "socks",
    "listen": "127.0.0.1", "port": $PORT_SOCKS,
    "settings": {"auth": "noauth", "udp": false}
  }],
  "outbounds": [
    {"tag": "proxy", "protocol": "backuppc",
     "settings": {"serverAddr": "127.0.0.1:$PORT_SRV", "uuid": "$UUID",
                  "insecure": true, "maxSessionBytes": $chunk_bytes,
                  "endpoints": "/backuppc.BackupService/BackupStream,/backuppc.ChunkService/PutChunk,/backuppc.StorageService/UploadStream"}},
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF
"$WORK/backuppc-xray" run -config "$WORK/app.json" > "$WORK/core.log" 2>&1 &
CORE_PID=$!
sleep 1

echo "==> скачивание ${SIZE} через туннель (${PARALLEL} поток(ов), чанк ${CHUNK})"
tmp_out="$WORK/out.bin"
start=$(date +%s.%N)
if [[ "$PARALLEL" -gt 1 ]]; then
  # поблочная параллельная загрузка Range-запросами
  total="$bytes"; block=$(( bytes / PARALLEL ))
  pids=()
  for i in $(seq 0 $((PARALLEL-1))); do
    off=$(( i * block ))
    if [[ $i -eq $((PARALLEL-1)) ]]; then len=$(( total - off )); else len=$block; fi
    ( curl -sS --socks5-hostname "127.0.0.1:$PORT_SOCKS" \
        -r "$off-$(( off + len - 1 ))" \
        "http://127.0.0.1:$PORT_TARGET/file.bin" > "$WORK/part$i" ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  cat $(for i in $(seq 0 $((PARALLEL-1))); do echo "$WORK/part$i"; done) > "$tmp_out"
else
  curl -sS --socks5-hostname "127.0.0.1:$PORT_SOCKS" \
    "http://127.0.0.1:$PORT_TARGET/file.bin" > "$tmp_out"
fi
end=$(date +%s.%N)

dur=$(echo "$end $start" | awk '{printf "%.1f", $1-$2}')
mib=$(( bytes / 1048576 ))
mbps=$(echo "$mib $dur" | awk '{printf "%.1f", $1/$2}')

sha_got="$(sha256sum "$tmp_out" | cut -d' ' -f1)"
rotations=$(grep -c "session rotated" "$WORK/core.log" || true)

echo
echo "── результаты ─────────────────────────────────────────────"
mbits=$(echo "$mbps" | awk '{printf "%.0f", $1*8}')
echo "объем: $mib МиБ за ${dur} c → ${mbps} МиБ/с (${mbits} Мбит/с)"
echo "ротаций чанков: $rotations (лимит ${CHUNK})"
if [[ "$sha_target" == "$sha_got" ]]; then
  echo "целостность: SHA-256 OK, потерь нет"
  exit 0
fi
echo "целостность: FAIL (sha $sha_got != $sha_target)"
exit 1
