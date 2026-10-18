#!/bin/sh
# uninstall.sh — удаление служб и бинарника. Конфиги (/usr/local/etc/backuppc-client)
# остаются; PURGE=1 удаляет и их.
set -eu

if [ "$(id -u)" != 0 ]; then
    echo "запустите с правами root: sudo sh uninstall.sh" >&2
    exit 1
fi
BIN=/usr/local/bin/backuppc-client
if [ -x "$BIN" ]; then
    # uninstall службы шлёт SIGTERM: run возвращает маршруты и DNS
    "$BIN" service uninstall tun || true
    "$BIN" service uninstall socks || true
fi
rm -f "$BIN" /var/log/backuppc-client-socks.log /var/log/backuppc-client-tun.log
if [ "${PURGE:-0}" = 1 ]; then
    rm -rf /usr/local/etc/backuppc-client
    echo "конфиги удалены"
fi
echo "backuppc-client удалён"
