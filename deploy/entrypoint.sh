#!/bin/sh
# entrypoint.sh — запуск безголового ядра backuppc-xray в контейнере.
#
# Конфиг: /etc/backuppc/xray.json (смонтирован) ИЛИ генерация из
# переменных окружения:
#
#   BACKUPPC_SERVER    адрес сервера xray-backuppc (host:port), обязателен
#   BACKUPPC_UUID      UUID пользователя VLESS, обязателен
#   BACKUPPC_SOCKS     локальный SOCKS5-листенер (по умолчанию 0.0.0.0:1080)
#   BACKUPPC_HOST      домен-донор для SNI/Host (по умолчанию backup.local)
#   BACKUPPC_ENDPOINTS пути несущих вызовов через запятую (по умолчанию —
#                      пул backuppc.* сервера)
#   BACKUPPC_INSECURE  "1" — не проверять TLS (только тесты)
#   BACKUPPC_CERT_FP   SHA-256 (hex) сертификата сервера — пиннинг
#   BACKUPPC_LOGLEVEL  debug|info|warning|error (по умолчанию warning)
#   BACKUPPC_DIRECT_TAG тег прямого outbound (по умолчанию direct)
#
# Пример:
#   docker run -e BACKUPPC_SERVER=vpn.example.com:8443 \
#              -e BACKUPPC_UUID=... -p 1080:1080 backuppc-client
set -eu

CONF="${BACKUPPC_CONFIG:-/etc/backuppc/xray.json}"

if [ ! -f "$CONF" ]; then
    if [ -z "${BACKUPPC_SERVER:-}" ] || [ -z "${BACKUPPC_UUID:-}" ]; then
        echo "backuppc-entrypoint: смонтируйте $CONF или задайте" >&2
        echo "  BACKUPPC_SERVER (host:port) и BACKUPPC_UUID" >&2
        exit 64
    fi

    SOCKS="${BACKUPPC_SOCKS:-0.0.0.0:1080}"
    HOST_HEADER="${BACKUPPC_HOST:-backup.local}"
    LOGLEVEL="${BACKUPPC_LOGLEVEL:-warning}"
    DIRECT_TAG="${BACKUPPC_DIRECT_TAG:-direct}"

    SETTINGS="{\"serverAddr\": \"${BACKUPPC_SERVER}\", \"uuid\": \"${BACKUPPC_UUID}\""
    [ -n "${BACKUPPC_HOST:-}" ] && \
        SETTINGS="$SETTINGS, \"host\": \"${BACKUPPC_HOST}\""
    [ "${BACKUPPC_INSECURE:-0}" = "1" ] && \
        SETTINGS="$SETTINGS, \"insecure\": true"
    [ -n "${BACKUPPC_CERT_FP:-}" ] && \
        SETTINGS="$SETTINGS, \"certFingerprint\": \"${BACKUPPC_CERT_FP}\""
    [ -n "${BACKUPPC_ENDPOINTS:-}" ] && \
        SETTINGS="$SETTINGS, \"endpoints\": \"${BACKUPPC_ENDPOINTS}\""
    SETTINGS="$SETTINGS}"

    mkdir -p "$(dirname "$CONF")" 2>/dev/null || true
    cat > "$CONF" <<EOF
{
  "log": {"loglevel": "${LOGLEVEL}"},
  "inbounds": [{
    "tag": "socksIn", "protocol": "socks",
    "listen": "${SOCKS%%:*}", "port": ${SOCKS##*:},
    "settings": {"auth": "noauth", "udp": false}
  }],
  "outbounds": [
    {"tag": "proxy", "protocol": "backuppc", "settings": $SETTINGS},
    {"tag": "${DIRECT_TAG}", "protocol": "freedom"}
  ]
}
EOF
    echo "backuppc-entrypoint: конфиг сгенерирован ($CONF)"
fi

echo "backuppc-entrypoint: ядро запускается, SOCKS5 см. порт из конфига"
exec backuppc-xray run -config "$CONF"
