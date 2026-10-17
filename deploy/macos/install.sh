#!/bin/sh
# install.sh — установка backuppc-client в /usr/local/bin (запуск: sudo ./install.sh
# из распакованного архива). Уже установленные службы перезапускаются на
# новом бинарнике.
set -eu

if [ "$(id -u)" != 0 ]; then
    echo "запустите с правами root: sudo ./install.sh" >&2
    exit 1
fi
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/bin/backuppc-client

case "$(uname -m)" in
arm64 | x86_64) ;;
*)
    echo "неподдерживаемая архитектура: $(uname -m)" >&2
    exit 1
    ;;
esac
if ! "$HERE/backuppc-client" version >/dev/null 2>&1; then
    # снять карантин Gatekeeper (архив скачан браузером) и попробовать ещё раз
    xattr -d com.apple.quarantine "$HERE/backuppc-client" 2>/dev/null || true
    if ! "$HERE/backuppc-client" version >/dev/null 2>&1; then
        echo "backuppc-client не запускается на этом Mac — архив не той архитектуры?" >&2
        echo "Apple Silicon: …_macos_arm64.tar.gz, Intel: …_macos_amd64.tar.gz" >&2
        exit 1
    fi
fi

mkdir -p /usr/local/bin
install -m 0755 "$HERE/backuppc-client" "$BIN"
xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true

for mode in socks tun; do
    if launchctl print "system/local.backuppc-client.$mode" >/dev/null 2>&1; then
        launchctl kickstart -k "system/local.backuppc-client.$mode"
        echo "служба $mode перезапущена"
    fi
done
"$BIN" version
echo "дальше: sudo backuppc-client import 'backuppc://…'  и  sudo backuppc-client service install tun"
