#!/bin/sh
# build.sh — архивы безголового клиента для macOS (Apple Silicon и Intel):
#   dist/backuppc-client_<версия>_macos_{arm64,amd64}.tar.gz
#
#   deploy/macos/build.sh                 # обе архитектуры
#   ARCHS=arm64 deploy/macos/build.sh     # только Apple Silicon
#   VERSION=0.3.0 deploy/macos/build.sh
#
# Кросс-сборка из Linux: нужен только Go (по core/go.mod), CGO не нужен.
# arm64-бинарник Go подписывает ad-hoc сам — этого достаточно для запуска.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GO="${GO:-go}"
ARCHS="${ARCHS:-arm64 amd64}"

if [ -z "${VERSION:-}" ]; then
    # как в deploy/linux/build-deb.sh: время коммита (UTC) + хеш
    stamp=$(TZ=UTC0 git -C "$ROOT" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd 2>/dev/null ||
        date -u +%Y%m%d%H%M%S)
    rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    VERSION="0.1.0~git$stamp.g$rev"
fi

OUT="$ROOT/dist"
mkdir -p "$OUT"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

for arch in $ARCHS; do
    name="backuppc-client_${VERSION}_macos_$arch"
    pkg="$STAGE/$name"
    echo "==> $name"
    mkdir -p "$pkg"
    (
        cd "$ROOT/core"
        CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" "$GO" build -trimpath \
            -ldflags="-s -w -X main.version=$VERSION" \
            -o "$pkg/backuppc-client" ./cmd/backuppc-client
    )
    install -m 0755 "$HERE/install.sh" "$HERE/uninstall.sh" "$pkg/"
    install -m 0644 "$HERE/README.md" "$pkg/"
    tar -C "$STAGE" --owner=0 --group=0 -czf "$OUT/$name.tar.gz" "$name"
    echo "==> $OUT/$name.tar.gz"
done
