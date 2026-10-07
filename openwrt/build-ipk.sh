#!/bin/sh
# build-ipk.sh — пакет backuppc-socks для OpenWrt (opkg/ipk) без SDK.
#
#   openwrt/build-ipk.sh aarch64_cortex-a53   # Redmi AX6S, MT7622, MT7981/86…
#   openwrt/build-ipk.sh mipsel_24kc          # MT7621
#   openwrt/build-ipk.sh arm_cortex-a7        # IPQ40xx и т.п.
#   openwrt/build-ipk.sh x86_64               # тесты в контейнере openwrt/rootfs
#
# Бинарник статический (CGO_ENABLED=0) — зависимостей от libc нет.
# Результат — dist/backuppc-socks_<версия>_<арх>.ipk
set -eu

ARCH="${1:?архитектура OpenWrt: aarch64_cortex-a53 | mipsel_24kc | arm_cortex-a7 | x86_64}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
GO="${GO:-go}"

case "$ARCH" in
aarch64_*) GOARCH=arm64 ;;
mipsel_*) GOARCH=mipsle GOMIPS=softfloat ;;
mips_*) GOARCH=mips GOMIPS=softfloat ;;
arm_cortex-a7* | arm_cortex-a9* | arm_cortex-a15*) GOARCH=arm GOARM=7 ;;
x86_64) GOARCH=amd64 ;;
*)
    echo "неизвестная архитектура: $ARCH" >&2
    exit 64
    ;;
esac

if [ -z "${VERSION:-}" ]; then
    # время коммита (UTC) — монотонно; opkg сравнивает версии как dpkg
    stamp=$(TZ=UTC0 git -C "$ROOT" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd 2>/dev/null ||
        date -u +%Y%m%d%H%M%S)
    rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    VERSION="0.1.0~git$stamp.g$rev"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DATA="$STAGE/data"
CTRL="$STAGE/control"
mkdir -p "$DATA/usr/bin" "$CTRL"

echo "==> backuppc-socks $VERSION для $ARCH (GOARCH=$GOARCH)"
(
    cd "$ROOT/core"
    export CGO_ENABLED=0 GOOS=linux GOARCH
    [ -n "${GOMIPS:-}" ] && export GOMIPS
    [ -n "${GOARM:-}" ] && export GOARM
    "$GO" build -trimpath -ldflags="-s -w -X main.version=$VERSION" \
        -o "$DATA/usr/bin/backuppc-socks" ./cmd/backuppc-socks
)
cp -R "$HERE/backuppc-socks/files/." "$DATA/"
chmod 0755 "$DATA/usr/bin/backuppc-socks" "$DATA/etc/init.d/backuppc-socks"
chmod 0600 "$DATA/etc/config/backuppc-socks"

size=$(du -sk "$DATA" | cut -f1)
cat > "$CTRL/control" <<EOF
Package: backuppc-socks
Version: $VERSION
Architecture: $ARCH
Maintainer: Alexander Musikhin <dth.pto@gmail.com>
Section: net
Priority: optional
Installed-Size: $((size * 1024))
Description: SOCKS5 client for the xray-backuppc tunnel (one process per server).
 Route selected traffic to it from podkop: socks5://127.0.0.1:<port>.
EOF
echo /etc/config/backuppc-socks > "$CTRL/conffiles"
cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/backuppc-socks enable
# первая установка: экземпляры ещё не настроены — restart молча ничего не делает
/etc/init.d/backuppc-socks restart >/dev/null 2>&1
exit 0
EOF
cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/backuppc-socks stop
/etc/init.d/backuppc-socks disable
exit 0
EOF
chmod 0755 "$CTRL/postinst" "$CTRL/prerm"

tgz() { tar --numeric-owner --owner=0 --group=0 -C "$1" -czf "$2" .; }
tgz "$DATA" "$STAGE/data.tar.gz"
tgz "$CTRL" "$STAGE/control.tar.gz"
echo 2.0 > "$STAGE/debian-binary"

mkdir -p "$ROOT/dist"
out="$ROOT/dist/backuppc-socks_${VERSION}_${ARCH}.ipk"
tar --numeric-owner --owner=0 --group=0 -C "$STAGE" -czf "$out" ./debian-binary ./control.tar.gz ./data.tar.gz
echo "==> $out ($(du -h "$out" | cut -f1); бинарник $(du -h "$DATA/usr/bin/backuppc-socks" | cut -f1))"
