#!/bin/sh
# build-deb.sh — пакет backuppc-client_<версия>_amd64.deb (безголовый клиент).
#
#   deploy/linux/build-deb.sh            # из корня репозитория или откуда угодно
#   VERSION=0.2.0 deploy/linux/build-deb.sh
#
# Нужны: Go (по core/go.mod), dpkg-deb. Результат — в dist/.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GO="${GO:-go}"

if [ -z "${VERSION:-}" ]; then
    # время коммита (UTC) — монотонно растёт; хеш только для справки
    # (сравнение dpkg по одному хешу дало бы «понижение» версии)
    stamp=$(TZ=UTC0 git -C "$ROOT" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd 2>/dev/null ||
        date -u +%Y%m%d%H%M%S)
    rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    VERSION="0.1.0~git$stamp.g$rev"
fi

OUT="$ROOT/dist"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"

echo "==> сборка бинарников ($VERSION)"
mkdir -p "$PKG/usr/bin"
(
    cd "$ROOT/core"
    export CGO_ENABLED=0 GOOS=linux GOARCH=amd64
    "$GO" build -trimpath -ldflags="-s -w" -o "$PKG/usr/bin/backuppc-xray" ./cmd/backuppc-xray
    "$GO" build -trimpath -ldflags="-s -w -X main.version=$VERSION" \
        -o "$PKG/usr/bin/backuppc-client" ./cmd/backuppc-client
)

echo "==> раскладка пакета"
install -D -m 0755 "$HERE/tun-routes" "$PKG/usr/lib/backuppc-client/tun-routes"
install -D -m 0644 "$HERE/systemd/backuppc-client.service" \
    "$PKG/usr/lib/systemd/system/backuppc-client.service"
install -D -m 0644 "$HERE/systemd/backuppc-client-tun.service" \
    "$PKG/usr/lib/systemd/system/backuppc-client-tun.service"
install -D -m 0644 "$HERE/README.md" "$PKG/usr/share/doc/backuppc-client/README.md"

mkdir -p "$PKG/DEBIAN"
for s in postinst prerm postrm; do
    install -m 0755 "$HERE/debian/$s" "$PKG/DEBIAN/$s"
done
size=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$size/" \
    "$HERE/debian/control.in" > "$PKG/DEBIAN/control"

mkdir -p "$OUT"
deb="$OUT/backuppc-client_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$deb" >/dev/null
echo "==> $deb"
dpkg-deb --info "$deb" | sed -n '/Package:/,/Description:/p'
