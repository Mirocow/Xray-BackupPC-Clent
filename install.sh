#!/usr/bin/env bash
# install.sh — локальная установка dev-окружения OneXray на macOS.
#
# Скрипт POSIX-совместимый: работает под sh, bash, dash. Запуск:
#   sh install.sh        # OK
#   bash install.sh      # OK
#   ./install.sh         # OK (shebang → bash)
#
# НЕ сурсит ~/.zshrc — там zsh-специфичный синтаксис (p10k/oh-my-zsh),
# который ломается под sh. PATH/FLUTTER_ROOT дописываются в ~/.zshrc
# через безопасный marker-блок (idempotent).

# Требуем bash если вызвано под нес bash-совместимым shell — но это
# блокируем только при POSIX-incompatible синтаксисе. Текущая версия
# написана в POSIX sh, так что этого не потребуется.
set -eu

# ─── 0. Откатить подмену macos/ ─────────────────────────────────────────
if [ -d macos ]; then
    git checkout -- macos/ 2>/dev/null || true
fi

# ─── 1. Homebrew ───────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
    echo "install: Homebrew не найден — ставим"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ─── 2. Go, CocoaPods, uv, fastlane ────────────────────────────────────
# fastlane — это FORMULA, не cask. `brew install --cask fastlane`
# фейлится с "No Cask with this name exists" и подсказывает "fastmail".
brew install go cocoapods uv fastlane

# Xcode Command Line Tools.
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install || true
    echo "install: дождитесь окончания установки Command Line Tools и запустите скрипт повторно"
    exit 0
fi

# ─── 3. Flutter через setup_flutter.sh ─────────────────────────────────
# Скрипт сам определяет версию:
#   - macOS 13 (Ventura): пинит к 3.24.5 (последний stable с поддержкой 13)
#   - macOS 14+ (Sonoma): latest stable
#   - Linux/CI:           latest stable
# Переопределение: ONEXRAY_FLUTTER_VERSION=3.29.0 sh install.sh
#
# setup_flutter.sh экспортирует FLUTTER_ROOT только в GitHub Actions
# (через $GITHUB_ENV). Локально переменные живут в subshell —
# поэтому после запуска скрипта вычисляем путь по той же rule-логике
# (detected macOS version → pinned Flutter tag → path).
FLUTTER_VERSION="${ONEXRAY_FLUTTER_VERSION:-stable}"
if [ -z "${ONEXRAY_FLUTTER_VERSION:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
    # POSIX-совместимое извлечение major-версии через cut:
    #   "13.6.1" → "13", "14.5" → "14"
    macos_major="$(echo "$macos_product" | cut -d. -f1)"
    if [ -n "$macos_major" ] && [ "$macos_major" -lt 14 ] 2>/dev/null; then
        FLUTTER_VERSION="3.24.5"
        echo "install: macOS $macos_product (<14) — pinning Flutter to 3.24.5" >&2
    else
        echo "install: macOS $macos_product (>=14) — using latest stable" >&2
    fi
fi

FLUTTER_ROOT="${ONEXRAY_FLUTTER_ROOT:-$HOME/flutter/$FLUTTER_VERSION}"
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Запустить setup_flutter.sh — он склонирует нужный tag в $FLUTTER_ROOT.
# Локально переменные не важны (мы их уже вычислили), но скрипт нужен
# чтобы клонировать Flutter SDK.
ONEXRAY_FLUTTER_VERSION="$FLUTTER_VERSION" \
ONEXRAY_FLUTTER_ROOT="$FLUTTER_ROOT" \
    bash build_scripts/setup_flutter.sh

echo "install: FLUTTER_ROOT=$FLUTTER_ROOT"
echo "install: PATH includes flutter: $(command -v flutter || echo 'NOT FOUND')"

if ! command -v flutter >/dev/null 2>&1; then
    echo "install: ERROR — flutter не на PATH после setup_flutter.sh" >&2
    echo "  Проверь, что $FLUTTER_ROOT/bin/flutter существует" >&2
    exit 1
fi
flutter --version

# ─── 4. Доп.'idempotent' блок в ~/.zshrc (НЕ source'им его!) ─────────
# НЕ сурсим ~/.zshrc — там zsh-специфичный синтаксис (p10k, oh-my-zsh),
# который ломается под sh/bash. Вместо этого — безопасный marker-блок.
zshrc_path="$HOME/.zshrc"
marker_begin="# >>> OneXray install.sh >>>"
marker_end="# <<< OneXray install.sh <<<"
block="${marker_begin}
export FLUTTER_ROOT=\"$FLUTTER_ROOT\"
export PATH=\"\$FLUTTER_ROOT/bin:\$PATH\"
${marker_end}"

if [ -f "$zshrc_path" ] && grep -qF "$marker_begin" "$zshrc_path"; then
    # Заменить существующий блок (POSIX-shell совместимо через python3
    # — без sed -i и без GNU-расширений).
    python3 - "$zshrc_path" "$block" "$marker_begin" "$marker_end" <<'PY'
import sys, re
path, block, begin, end = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
pattern = re.escape(begin) + r".*?" + re.escape(end)
new = re.sub(pattern, block, content, flags=re.DOTALL)
with open(path, "w") as f:
    f.write(new)
PY
else
    printf '\n%s\n' "$block" >> "$zshrc_path"
fi
echo "install: дописан/обновлён блок в $zshrc_path"
echo "  открой новый терминал (или в zsh-сессии: source ~/.zshrc)"

# ─── 5. Python-окружение (uv) ──────────────────────────────────────────
if command -v uv >/dev/null 2>&1; then
    uv sync --project build_scripts
else
    echo "install: uv не на PATH — пропускаем (brew install uv должен быть выше)" >&2
fi

# ─── 6. Apple Developer cert инструкции (не исполняется автоматически) ─
cat <<'INSTR'
install: следующие шаги требуют ручной настройки Apple Developer certs:

  Вариант A: импорт уже выданного .p12:
    base64 -i cert.p12 | pbcopy
    export APPLE_DEVELOPER_ID_P12_BASE64=...
    export KEYCHAIN_PASSWORD=...
    (в GitHub: Settings → Secrets and variables → Actions → New secret)

  Вариант B: создать Developer ID cert в Apple Developer Portal:
    https://developer.apple.com/account/resources/certificates/list
    + → Developer ID Application
    Загрузи CSR (Keychain → Certificate Assistant → Request a Certificate)
    Скачай .cer, дважды кликни → импортируй в Keychain
    Экспортируй .p12 (с паролем) → base64 -i Certificates.p12 | pbcopy

  App Store Connect API key для нотаризации:
    https://appstoreconnect.apple.com/access/integrations/api
    Generate API Key → role App Manager → скачай .p8 (только один раз!)
    Запиши Key ID и Issuer ID
    base64 -i AuthKey.p8 | pbcopy

  Запуск сборки локально:
    export BUILD_NUMBER=1
    uv run --project build_scripts python build_scripts/main.py OneXray macos_se
    #  или: make build-macos-se
INSTR

echo "install: DONE"
