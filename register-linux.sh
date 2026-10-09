#!/usr/bin/env bash
# register-linux.sh — ручная регистрация URL scheme handler для Linux.
#
# Регистрирует backuppcvpn:// и backuppc:// URL schemes для BackupPC VPN.
# Используется когда приложение собрано через SKIP_FASTFORGE=1 (без .deb).
#
# После branding commit 770aa7c приложение называется "BackupPC VPN" с
# applicationId org.mirocow.backuppcvpn. Scheme backuppcvpn://app/... —
# app-specific deep-link (генерируется AppLinkShareService). Scheme
# backuppc://<uuid>@host:port/?... — server share-link (генерируется
# BackupPcLink.build() в backuppc_dart/lib/src/link.dart).
#
# Запуск:
#   ./register-linux.sh /path/to/OneXray/bundle
#   ./register-linux.sh                   # default: ./build/linux/x64/release/bundle
#
# После регистрации можно тестировать:
#   xdg-open 'backuppcvpn://app/config/add?type=outbound&data=...'
#   xdg-open 'backuppc://52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90@example.com:8443?endpoints=...&fp=...#Test'

set -eu

BUNDLE_DIR="${1:-$(pwd)/build/linux/x64/release/bundle}"
# Binary name is still "OneXray" (set in linux/CMakeLists.txt BINARY_NAME).
# Display name (shown in app launcher / window title) is "BackupPC VPN"
# (from lib/core/constants/branding.dart AppBranding.name).
APP_NAME="OneXray"
APP_DISPLAY_NAME="BackupPC VPN"
APP_ID="org.mirocow.backuppcvpn"
DESKTOP_FILE="$HOME/.local/share/applications/${APP_ID}.desktop"

if [ ! -x "$BUNDLE_DIR/$APP_NAME" ]; then
    echo "register: ERROR — $BUNDLE_DIR/$APP_NAME executable not found" >&2
    echo "register: build the app first: make build-linux (or SKIP_FASTFORGE=1 flutter build linux --release)" >&2
    exit 1
fi

# Абсолютный путь (для .desktop файла нужен абсолютный)
BUNDLE_ABS="$(cd "$BUNDLE_DIR" && pwd)"

echo "register: creating $DESKTOP_FILE"

mkdir -p "$(dirname "$DESKTOP_FILE")"

cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Name=$APP_DISPLAY_NAME
Comment=VPN and Proxy Client (based on OneXray)
Exec=$BUNDLE_ABS/$APP_NAME %U
Icon=$BUNDLE_ABS/data/flutter_assets/assets/logo.png
Terminal=false
Type=Application
Categories=Network;
StartupNotify=true
StartupWMClass=$APP_NAME
MimeType=x-scheme-handler/backuppcvpn;x-scheme-handler/backuppc;
DESKTOP

# Регистрируем MIME type handlers
echo "register: updating desktop database"
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true

# Регистрируем URL schemes через xdg-mime
echo "register: registering backuppcvpn:// and backuppc:// schemes"
xdg-mime default "$APP_ID.desktop" x-scheme-handler/backuppcvpn 2>/dev/null || true
xdg-mime default "$APP_ID.desktop" x-scheme-handler/backuppc 2>/dev/null || true

echo "register: DONE"
echo "  $APP_DISPLAY_NAME binary: $BUNDLE_ABS/$APP_NAME"
echo "  backuppcvpn://app/... links → opens $APP_DISPLAY_NAME"
echo "  backuppc://<uuid>@host:port/?... links → opens $APP_DISPLAY_NAME"
echo ""
echo "  Test deep-link: xdg-open 'backuppcvpn://app/config/add?type=outbound&data=...'"
echo "  Test share-link: xdg-open 'backuppc://52724a0e@example.com:8443?endpoints=...&fp=...#Test'"
