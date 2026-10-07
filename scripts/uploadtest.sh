#!/usr/bin/env bash
# uploadtest.sh — стресс upload-плеча НАТИВНОГО туннеля (SOCKS5 →
# VLESS → gRPC/HTTP2-TLS → BackupPC-мимикрия) с ротациями чанков.
#
# Дополняет loadtest.sh (который гоняет только download): upload исторически
# был слабо покрыт, а именно он ломался при ротациях (порядок upload-насосов,
# см. fix «эстафета порядка upload-насосов» в обеих репозиториях).
#
# Стек: backuppc-server + bench-таргет (/sink: POST → {bytes, sha256}) +
# ядро Xray с backuppc-outbound + curl --upload-file.
#
# Переменные: SIZE=256M (МиБ/ГиБ), CHUNK=64M (лимит чанка — ротации)
# Примеры:
#   bash scripts/uploadtest.sh                  # 256M, чанк 64M → ~4 ротации
#   SIZE=1G CHUNK=16M bash scripts/uploadtest.sh  # 64 ротации, стресс
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${SERVER_REPO:-$REPO_ROOT/../xray-backuppc}"
SIZE="${SIZE:-256M}"
CHUNK="${CHUNK:-64M}"
GO=go; command -v go >/dev/null 2>&1 || GO="$HOME/.local/go/bin/go"

case "$SIZE" in
  *G|*g) size_bytes=$(( ${SIZE%[Gg]} * 1073741824 )) ;;
  *M|m)  size_bytes=$(( ${SIZE%[Mm]} * 1048576 )) ;;
  *K|k)  size_bytes=$(( ${SIZE%[Kk]} * 1024 )) ;;
  *)     size_bytes="$SIZE" ;;
esac
case "$CHUNK" in
  *G|*g) chunk_bytes=$(( ${CHUNK%[Gg]} * 1073741824 )) ;;
  *M|m)  chunk_bytes=$(( ${CHUNK%[Mm]} * 1048576 )) ;;
  *K|k)  chunk_bytes=$(( ${CHUNK%[Kk]} * 1024 )) ;;
  *)     chunk_bytes="$CHUNK" ;;
esac

UUID="e2e11e2e-11e2-11e2-11e2-11e2e2e2e2e3"
PORT_SOCKS=10811
PORT_SRV=18448
PORT_TGT=18087
WORK="$(mktemp -d /tmp/backuppc-upload.XXXXXX)"

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "$PORT_TGT" "$PORT_SOCKS" "$PORT_SRV"; do
  if port_busy "$p"; then
    echo "FATAL: порт $p уже слушается — осиротевший процесс прошлого прогона?" >&2
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

echo "==> сборка (ядро backuppc-xray, сервер, bench-таргет)"
(cd "$REPO_ROOT/core" && CGO_ENABLED=0 "$GO" build -trimpath -o "$WORK/xray" ./cmd/backuppc-xray)
(cd "$SERVER_REPO" && CGO_ENABLED=0 "$GO" build -trimpath -o "$WORK/server" ./cmd/backuppc-server)
(cd "$SERVER_REPO" && CGO_ENABLED=0 "$GO" build -trimpath -o "$WORK/bench" ./cmd/backuppc-bench)

echo "==> таргет /sink + сервер (лимит чанка $CHUNK)"
"$WORK/bench" -mode target -listen "127.0.0.1:$PORT_TGT" > "$WORK/target.log" 2>&1 &
TGT_PID=$!
cat > "$WORK/server.json" <<EOF
{
  "listen": "127.0.0.1:$PORT_SRV",
  "uuid": "$UUID",
  "transport": {"host": "backup.local", "maxSessionBytes": $chunk_bytes, "maxSessionDuration": "45m"},
  "panelListen": ""
}
EOF
"$WORK/server" -config "$WORK/server.json" -data "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV_PID=$!
sleep 0.5
if ! kill -0 "$SRV_PID" 2>/dev/null; then
  echo "FATAL: сервер не стартовал:"; cat "$WORK/server.log"; exit 1
fi

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
                  "insecure": true, "maxSessionBytes": $chunk_bytes,
                  "endpoints": "/backuppc.BackupService/BackupStream,/backuppc.ChunkService/PutChunk,/backuppc.StorageService/UploadStream"}},
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF
"$WORK/xray" run -config "$WORK/app.json" > "$WORK/core.log" 2>&1 &
CORE_PID=$!
sleep 1

echo "==> upload ${SIZE} через туннель (чанк $CHUNK)"
head -c "$size_bytes" /dev/urandom > "$WORK/up.bin"
sha_src="$(sha256sum "$WORK/up.bin" | cut -d' ' -f1)"

start=$(date +%s.%N)
resp="$(curl -s --max-time 300 --socks5-hostname "127.0.0.1:$PORT_SOCKS" \
  -X POST -H 'Content-Type: application/octet-stream' \
  --data-binary "@$WORK/up.bin" "http://127.0.0.1:$PORT_TGT/sink")"
end=$(date +%s.%N)

bytes="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("bytes",0))')"
sha_dst="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha256",""))')"
elapsed="$(python3 -c "print(f'{max($end-$start, 0.01):.2f}')"
)"
mbps="$(python3 -c "print(f'{$size_bytes/1048576/$elapsed:.1f}')")"
rotations="$(grep -c 'session rotated' "$WORK/core.log" || true)"

echo
echo "── результаты ─────────────────────────────────────────────"
echo "объем: $(( size_bytes / 1048576 )) МиБ за $elapsed c → $mbps МиБ/с"
echo "ротаций чанков: $rotations (лимит $CHUNK)"
echo "sha-256 src: $sha_src"
echo "sha-256 dst: $sha_dst"
if [ "$sha_src" != "$sha_dst" ] || [ "$bytes" != "$size_bytes" ]; then
  echo "целостность: FAIL (байт получено $bytes)"
  echo "--- core.log (хвост):"; tail -5 "$WORK/core.log" || true
  echo "--- server.log (сессии):"; grep -E "session finished|torn down" "$WORK/server.log" | tail -5 || true
  exit 1
fi
echo "целостность: SHA-256 OK, потерь нет (получено $bytes байт)"
