#!/usr/bin/env bash
# register-linux.sh — ручная регистрация URL scheme handler для Linux.
#
# Регистрирует backuppc:// и onexray:// URL schemes для OneXray.
# Используется когда приложение собрано через SKIP_FASTFORGE=1 (без .deb).
#
# Запуск:
#   ./register-linux.sh /path/to/OneXray/bundle
#   ./register-linux.sh                   # default: ./build/linux/x64/release/bundle

set -eu

BUNDLE_DIR="${1:-$(pwd)/build/linux/x64/release/bundle}"
APP_NAME="OneXray"
APP_ID="net.yuandev.onexray"
DESKTOP_FILE="$HOME/.local/share/applications/${APP_ID}.desktop"

if [ ! -x "$BUNDLE_DIR/$APP_NAME" ]; then
    echo "register: ERROR — $BUNDLE_DIR/$APP_NAME не найден" >&2
    exit 1
fi

# Абсолютный путь (для .desktop файла нужен абсолютный)
BUNDLE_ABS="$(cd "$BUNDLE_DIR" && pwd)"

echo "register: creating $DESKTOP_FILE"

mkdir -p "$(dirname "$DESKTOP_FILE")"

cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Name=$APP_NAME
Comment=VPN and Proxy Client
Exec=$BUNDLE_ABS/$APP_NAME %U
Icon=$BUNDLE_ABS/data/flutter_assets/assets/logo.png
Terminal=false
Type=Application
Categories=Network;
StartupNotify=true
StartupWMClass=$APP_NAME
MimeType=x-scheme-handler/onexray;x-scheme-handler/backuppc;
DESKTOP

# Регистрируем MIME type handlers
echo "register: updating desktop database"
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true

# Регистрируем URL schemes через xdg-mime
echo "register: registering backuppc:// and onexray:// schemes"
xdg-mime default "$APP_ID.desktop" x-scheme-handler/backuppc 2>/dev/null || true
xdg-mime default "$APP_ID.desktop" x-scheme-handler/onexray 2>/dev/null || true

echo "register: DONE"
echo "  backuppc:// links → $BUNDLE_ABS/$APP_NAME"
echo "  onexray:// links → $BUNDLE_ABS/$APP_NAME"
echo ""
echo "  Test: xdg-open 'backuppc://test@example.com:8443'"
