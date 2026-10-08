#!/usr/bin/env bash
# install.sh — локальная установка dev-окружения OneXray на macOS.
#
# Запускать ТОЛЬКО через bash (не sh), т.к. используется bash-специфичный
# синтаксис и source bash-скриптов. zsh-специфичный ~/.zshrc НЕ сурсится
# (это ломает p10k/oh-my-zsh). PATH/FLUTTER_ROOT экспортируются в текущую
# сессию и дописываются в ~/.zshrc через отдельный safe-блок.
#
# После первого запуска — открыть новый терминал или выполнить:
#   source ~/.zshrc   (если zsh) или ~/.bashrc (если bash)
#
# Баги, которые лечит эта версия:
#   1. setup_flutter.sh теперь детектит macOS 13 (Ventura) и пинит Flutter
#      к 3.24.5 (последний stable, поддерживающий macOS 13; 3.27 требует 14+)
#   2. fastlane ставится как formula, а не --cask (cask 'fastlane' не существует)
#   3. FLUTTER_ROOT берётся из setup_flutter.sh, а не хардкодится "stable"
#   4. ~/.zshrc не сурсится внутри bash — он сурсится только в zsh-сессии

set -euo pipefail

# ─── 0. Откатить подмену macos/ ─────────────────────────────────────────
if [[ -d macos ]]; then
    git checkout -- macos/ 2>/dev/null || true
fi

# ─── 1. Проверить, что есть Homebrew ────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo "install: Homebrew не найден — ставим"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Подсказка установщика про PATH — пользователь должен добавить сам
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ─── 2. Установить Go, CocoaPods, Fastlane, uv ─────────────────────────
# fastlane — это FORMULA, не cask. `brew install --cask fastlane` фейлится
# с "No Cask with this name exists" и подсказывает "fastmail" (не то).
brew install go cocoapods uv fastlane

# Xcode Command Line Tools (если ещё не установлен).
# xcode-select --install при уже установленном возвращает не-zero, это ОК.
if ! xcode-select -p &>/dev/null; then
    xcode-select --install || true
    echo "install: дождитесь окончания установки Command Line Tools и запустите скрипт повторно"
    exit 0
fi

# ─── 3. Установить Flutter через setup_flutter.sh ──────────────────────
# Скрипт сам определяет версию:
#   - macOS 13 (Ventura): пинит к 3.24.5 (последний stable с поддержкой 13)
#   - macOS 14+ (Sonoma): latest stable
#   - Linux/CI: latest stable
# Переопределение: ONEXRAY_FLUTTER_VERSION=3.29.0 bash install.sh
#
# Скрипт экспортирует FLUTTER_ROOT в текущий shell только для GitHub Actions
# (через $GITHUB_ENV). Локально переменные живут только в subshell —
# поэтому捕获 их через Bash-совместимый source + export:
source <(bash build_scripts/setup_flutter.sh 2>/dev/null | grep -E '^FLUTTER_ROOT=' || true)
# Fallback: если source не вытащил (setup_flutter.sh может не печатать),
# вычислим путь по тому же правилу:
if [[ -z "${FLUTTER_ROOT:-}" ]]; then
    flutter_version="${ONEXRAY_FLUTTER_VERSION:-stable}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
        if [[ "$macos_product" =~ ^([0-9]+)\. ]] && [[ "${BASH_REMATCH[1]}" -lt 14 ]]; then
            flutter_version="3.24.5"
        fi
    fi
    export FLUTTER_ROOT="$HOME/flutter/$flutter_version"
fi
export PATH="$FLUTTER_ROOT/bin:$PATH"

echo "install: FLUTTER_ROOT=$FLUTTER_ROOT"
echo "install: PATH includes flutter: $(command -v flutter || echo 'NOT FOUND')"

# Проверить, что flutter отвечает:
if ! command -v flutter &>/dev/null; then
    echo "install: ERROR — flutter не на PATH после setup_flutter.sh" >&2
    echo "  Проверь, что $FLUTTER_ROOT/bin/flutter существует" >&2
    exit 1
fi
flutter --version

# ─── 4. Дописать FLUTTER_ROOT/PATH в ~/.zshrc (idempotent) ─────────────
# НЕ сурсим ~/.zshrc — там zsh-специфичный синтаксис (p10k, oh-my-zsh),
# который ломается под bash/sh. Вместо этого — безопасный блок в конец
# файла, который пользователь может source в новой zsh-сессии.
zshrc_path="$HOME/.zshrc"
marker_begin="# >>> OneXray install.sh >>>"
marker_end="# <<< OneXray install.sh <<<"
block="$marker_begin
export FLUTTER_ROOT=\"$FLUTTER_ROOT\"
export PATH=\"\$FLUTTER_ROOT/bin:\$PATH\"
$marker_end"

if [[ -f "$zshrc_path" ]] && grep -qF "$marker_begin" "$zshrc_path"; then
    # Заменить существующий блок.
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
echo "  открой новый терминал (или: source ~/.zshrc в zsh-сессии)"

# ─── 5. Подготовить Python-окружение проекта (uv) ─────────────────────
if command -v uv &>/dev/null; then
    uv sync --project build_scripts
else
    echo "install: uv не на PATH — пропускаем (brew install uv должен быть выше)" >&2
fi

# ─── 6. Сертификаты Apple Developer ID (для macos_se) ──────────────────
# Инструкции — см. README. Скрипт их не трогает.
cat <<'INSTR'
install: следующие шаги требуют ручной настройки Apple Developer certs:

  Вариант A: импорт уже выданного .p12:
    base64 -i cert.p12 | pbcopy
    export APPLE_DEVELOPER_ID_P12_BASE64=...
    export APPLE_MAC_INSTALLER_P12_BASE64=...
    export KEYCHAIN_PASSWORD=...

  Вариант B: создать Developer ID cert в Apple Developer Portal:
    Accounts → Certificates, IDs & Profiles →
    создать Developer ID Application + Developer ID Installer

  App Store Connect API key для нотаризации:
    App Store Connect → Users and Access → Keys → App Store Connect API
    Создать ключ (Developer/App Manager), скачать .p8 →
    macos_se/fastlane/AuthKey.p8
    export FASTLANE_ASC_KEY_ID=...
    export FASTLANE_ASC_ISSUER_ID=...

  Запуск сборки:
    export BUILD_NUMBER=1
    uv run --project build_scripts python build_scripts/main.py OneXray macos_se
    #  или: make build-macos-se
INSTR

echo "install: DONE"
