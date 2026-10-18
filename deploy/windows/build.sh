#!/bin/sh
# build.sh — архив безголового клиента для Windows x64:
#   dist/backuppc-client_<версия>_windows_amd64.zip
#     backuppc-client.exe   ядро Xray + backuppc, import/run/service
#     wintun.dll            драйвер TUN (официальная подписанная сборка Wintun)
#     install.cmd, install.ps1, uninstall.ps1, README.md
#
#   deploy/windows/build.sh
#   VERSION=0.3.0 deploy/windows/build.sh
#   WINTUN_ZIP=~/wintun-0.14.1.zip deploy/windows/build.sh   # архив уже скачан
#
# Кросс-сборка из Linux: нужны Go (по core/go.mod), curl и python3 (zip).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GO="${GO:-go}"
ARCH=amd64

# та же версия и хеш, что у GUI-сборки (build_scripts/app/windows.py)
WINTUN_VERSION=0.14.1
WINTUN_SHA256=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51

if [ -z "${VERSION:-}" ]; then
    # как в deploy/linux/build-deb.sh: время коммита (UTC) + хеш
    stamp=$(TZ=UTC0 git -C "$ROOT" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd 2>/dev/null ||
        date -u +%Y%m%d%H%M%S)
    rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    VERSION="0.1.0~git$stamp.g$rev"
fi

OUT="$ROOT/dist"
CACHE="$OUT/.cache"
mkdir -p "$OUT" "$CACHE"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

wintun="${WINTUN_ZIP:-$CACHE/wintun-$WINTUN_VERSION.zip}"
if [ ! -f "$wintun" ]; then
    echo "==> загрузка Wintun $WINTUN_VERSION"
    curl -fL --retry 3 -o "$wintun.part" "https://www.wintun.net/builds/wintun-$WINTUN_VERSION.zip"
    mv "$wintun.part" "$wintun"
fi
if ! echo "$WINTUN_SHA256  $wintun" | sha256sum -c - >/dev/null 2>&1; then
    echo "хеш $wintun не совпал — удалите файл и повторите" >&2
    exit 1
fi

name="backuppc-client_${VERSION}_windows_$ARCH"
pkg="$STAGE/$name"
echo "==> $name"
mkdir -p "$pkg"
(
    cd "$ROOT/core"
    CGO_ENABLED=0 GOOS=windows GOARCH="$ARCH" "$GO" build -trimpath \
        -ldflags="-s -w -X main.version=$VERSION" \
        -o "$pkg/backuppc-client.exe" ./cmd/backuppc-client
)
python3 - "$wintun" "$pkg" "$ARCH" <<'PY'
import sys, zipfile
src, dst, arch = sys.argv[1:]
with zipfile.ZipFile(src) as z:
    open(f"{dst}/wintun.dll", "wb").write(z.read(f"wintun/bin/{arch}/wintun.dll"))
    open(f"{dst}/wintun-LICENSE.txt", "wb").write(z.read("wintun/LICENSE.txt"))
PY
# CRLF: скрипты и README открываются в Блокноте/PowerShell как есть;
# BOM: Windows PowerShell 5.1 без него читает .ps1 как ANSI (кириллица ломается)
for f in install.cmd install.ps1 uninstall.ps1 README.md; do
    case "$f" in *.ps1) printf '\357\273\277' > "$pkg/$f" ;; *) : > "$pkg/$f" ;; esac
    sed 's/\r*$/\r/' "$HERE/$f" >> "$pkg/$f"
done

python3 - "$STAGE" "$name" "$OUT/$name.zip" <<'PY'
import os, sys, zipfile
stage, name, out = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(os.path.join(stage, name))):
        z.write(os.path.join(stage, name, f), f"{name}/{f}")
PY
echo "==> $OUT/$name.zip"
