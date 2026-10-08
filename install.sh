#!/usr/bin/env bash
# install.sh — локальная установка dev-окружения backuppc-vpn.
#
# Кросс-платформенный: macOS (Homebrew) / Linux (apt|dnf|pacman) /
# Windows (Git Bash + winget).
#
# Скрипт POSIX-совместимый: работает под sh, bash, dash. Запуск:
#   sh install.sh        # OK
#   bash install.sh      # OK
#   ./install.sh         # OK (shebang → bash)
#
# НЕ сурсит ~/.zshrc / ~/.bashrc — там shell-специфичный синтаксис,
# который ломается под sh. PATH/FLUTTER_ROOT дописываются в
# соответствующий rc-файл через безопасный marker-блок (idempotent).
#
# Что ставит (по OS):
#   macOS:   brew install go cocoapods uv fastlane + xcode-select
#   Linux:   apt/dnf/pacman install go uv ruby-fastlane + build-essential
#   Windows: winget install GoLang.Go + Python + skips fastlane (use WSL)
#
# Flutter ставится через build_scripts/setup_flutter.sh на всех OS
# (детектит macOS 13 → пинит Flutter 3.24.5; на других — latest stable).

set -eu

# ─── 0. Откатить подмену macos/ ─────────────────────────────────────────
if [ -d macos ]; then
    git checkout -- macos/ 2>/dev/null || true
fi

# ─── OS detection ──────────────────────────────────────────────────────
uname_s="$(uname -s)"
case "$uname_s" in
    Darwin)
        os="macos"
        ;;
    Linux)
        os="linux"
        # Detect distro for package manager selection
        if [ -f /etc/debian_version ]; then
            linux_distro="debian"
        elif [ -f /etc/redhat-release ] || [ -f /etc/fedora-release ]; then
            linux_distro="redhat"
        elif [ -f /etc/arch-release ]; then
            linux_distro="arch"
        else
            linux_distro="unknown"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*)
        os="windows"
        ;;
    *)
        echo "install: unsupported OS: $uname_s" >&2
        exit 1
        ;;
esac

echo "install: detected OS = $os"

# ─── 1. Package manager + base tools ───────────────────────────────────
case "$os" in
    macos)
        if ! command -v brew >/dev/null 2>&1; then
            echo "install: Homebrew не найден — ставим"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [ -x /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -x /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi
        echo "install: brew install go cocoapods uv fastlane"
        brew install go cocoapods uv fastlane
        # Xcode Command Line Tools.
        if ! xcode-select -p >/dev/null 2>&1; then
            xcode-select --install || true
            echo "install: дождитесь окончания установки Command Line Tools и запустите скрипт повторно"
            exit 0
        fi
        # Python 3.12 — project requires >=3.12 per pyproject.toml.
        # Prefer asdf (if installed) else uv-managed.
        if command -v asdf >/dev/null 2>&1; then
            echo "install: asdf install python 3.12.15"
            asdf install python 3.12.15
            asdf local python 3.12.15
        else
            echo "install: uv python install 3.12 (no asdf)"
            uv python install 3.12
        fi
        # uv is ALWAYS needed for venv (even if asdf is present).
        # brew already installed uv above, but verify + create venv.
        uv sync --project build_scripts --python 3.12
        ;;
    linux)
        # Install Go via package manager OR download official tarball.
        # We prefer the official tarball (newer Go than distro packages).
        if ! command -v go >/dev/null 2>&1; then
            echo "install: Go не найден — ставим из официального архива"
            go_version="1.27.1"
            go_arch="$(uname -m)"
            case "$go_arch" in
                x86_64)  go_arch="amd64" ;;
                aarch64|arm64) go_arch="arm64" ;;
                *) echo "install: unsupported arch: $go_arch" >&2; exit 1 ;;
            esac
            curl -fsSL "https://go.dev/dl/go${go_version}.linux-${go_arch}.tar.gz" | \
                sudo tar -C /usr/local -xz
            export PATH="/usr/local/go/bin:$PATH"
            echo 'export PATH="/usr/local/go/bin:$PATH"' >> "$HOME/.profile"
        fi
        # Python 3.12 — project requires >=3.12 per pyproject.toml.
        # Prefer asdf (user's existing tool) if installed, else uv.
        if command -v asdf >/dev/null 2>&1; then
            echo "install: asdf install python 3.12.15"
            asdf install python 3.12.15
            # asdf local creates/updates .tool-versions (already in repo)
            asdf local python 3.12.15
        else
            # Fallback: uv-managed Python 3.12 (asdf not detected)
            echo "install: uv python install 3.12 (no asdf)"
            uv python install 3.12
        fi
        # uv is ALWAYS needed — it manages the venv for build_scripts
        # (declared in pyproject.toml [tool.uv]). Install it even if
        # asdf is present (uv is a standalone binary, doesn't conflict).
        if ! command -v uv >/dev/null 2>&1; then
            echo "install: uv не найден — ставим (нужен для venv)"
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
        fi
        # Create venv with Python 3.12 in build_scripts/.venv
        if command -v uv >/dev/null 2>&1; then
            echo "install: uv sync --project build_scripts --python 3.12"
            uv sync --project build_scripts --python 3.12
        else
            echo "install: WARN — uv не установлен; build scripts будут использовать системный python3 (требуется 3.12+)" >&2
        fi
        # Build essentials (cmake, ninja, pkg-config, clang) — needed for
        # building native deps (libsqlite3, etc.) via Flutter plugins.
        case "$linux_distro" in
            debian)
                sudo apt-get update
                sudo apt-get install -y build-essential cmake ninja-build \
                    pkg-config clang llvm-dev libsqlite3-dev \
                    ruby ruby-dev
                # fastlane via gem (apt version is too old)
                sudo gem install fastlane --no-document
                ;;
            redhat)
                sudo dnf install -y gcc gcc-c++ make cmake ninja-build \
                    pkg-config clang llvm-devel sqlite-devel \
                    ruby ruby-devel
                sudo gem install fastlane --no-document
                ;;
            arch)
                sudo pacman -S --noconfirm base-devel cmake ninja pkgconf \
                    clang llvm sqlite ruby
                sudo gem install fastlane --no-document
                ;;
            unknown)
                echo "install: неизвестный Linux distro — пропускаем установку системных пакетов" >&2
                echo "  установи вручную: go, uv, build-essential, cmake, ninja, clang, sqlite3-dev, ruby" >&2
                ;;
        esac
        ;;
    windows)
        echo "install: Windows — рекомендуется использовать WSL2 + Linux install"
        echo "  Если всё же нативный Windows:"
        # winget может быть не установлен на старых Windows 10
        if command -v winget >/dev/null 2>&1; then
            winget install --id GoLang.Go -e --source winget
            winget install --id Python.Python.3.13 -e --source winget
            winget install --id AstralSH.uv -e --source winget
            # fastlane на Windows работает через RubyInstaller
            echo "install: fastlane — установи через RubyInstaller + 'gem install fastlane'"
        else
            echo "install: winget не найден — установи Go, Python, uv вручную" >&2
        fi
        # CocoaPods не нужен на Windows (только для iOS/macOS builds)
        ;;
esac

# ─── 2. Flutter через setup_flutter.sh (кросс-платформенный) ────────────
# setup_flutter.sh сам детектит OS и пинит нужную версию:
#   - macOS 13 (Ventura): 3.24.5 (последний с поддержкой macOS 13)
#   - macOS 14+: latest stable
#   - Linux/Windows/CI: latest stable
# Переопределение: ONEXRAY_FLUTTER_VERSION=3.29.0 sh install.sh

# Determine Flutter version based on OS
FLUTTER_VERSION="${ONEXRAY_FLUTTER_VERSION:-stable}"
if [ -z "${ONEXRAY_FLUTTER_VERSION:-}" ] && [ "$os" = "macos" ]; then
    macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
    macos_major="$(echo "$macos_product" | cut -d. -f1)"
    if [ -n "$macos_major" ] && [ "$macos_major" -lt 14 ] 2>/dev/null; then
        FLUTTER_VERSION="3.24.5"
        echo "install: macOS $macos_product (<14) — pinning Flutter to 3.24.5" >&2
    else
        echo "install: macOS $macos_product (>=14) — using latest stable Flutter" >&2
    fi
fi

FLUTTER_ROOT="${ONEXRAY_FLUTTER_ROOT:-$HOME/flutter/$FLUTTER_VERSION}"
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"

# Run setup_flutter.sh (clones Flutter SDK to $FLUTTER_ROOT)
ONEXRAY_FLUTTER_VERSION="$FLUTTER_VERSION" \
ONEXRAY_FLUTTER_ROOT="$FLUTTER_ROOT" \
    bash build_scripts/setup_flutter.sh

echo "install: FLUTTER_ROOT=$FLUTTER_ROOT"

if ! command -v flutter >/dev/null 2>&1; then
    echo "install: ERROR — flutter не на PATH после setup_flutter.sh" >&2
    echo "  Проверь, что $FLUTTER_ROOT/bin/flutter существует" >&2
    exit 1
fi
flutter --version

# ─── 3. Update shell rc file (idempotent, marker-block) ────────────────
# НЕ сурсим rc — там shell-специфичный синтаксис. Marker-block безопасно
# добавляется в конец файла.
case "$os" in
    macos)
        rc_path="$HOME/.zshrc"
        ;;
    linux)
        # bash is default on most distros; zsh if installed
        if [ -n "${ZSH_VERSION:-}" ]; then
            rc_path="$HOME/.zshrc"
        else
            rc_path="$HOME/.bashrc"
        fi
        ;;
    windows)
        # Git Bash uses ~/.bashrc
        rc_path="$HOME/.bashrc"
        ;;
esac

if [ -n "${rc_path:-}" ] && [ -n "$FLUTTER_ROOT" ]; then
    marker_begin="# >>> backuppc-vpn install.sh >>>"
    marker_end="# <<< backuppc-vpn install.sh <<<"
    block="${marker_begin}
export FLUTTER_ROOT=\"$FLUTTER_ROOT\"
export PATH=\"\$FLUTTER_ROOT/bin:\$PATH\"
${marker_end}"

    if [ -f "$rc_path" ] && grep -qF "$marker_begin" "$rc_path"; then
        # Заменить существующий блок: удалить старый + добавить новый.
        # Используем sed для удаления строк между marker_begin и marker_end
        # (включительно), потом добавляем новый блок в конец.
        sed -i "/${marker_begin}/,/${marker_end}/d" "$rc_path" 2>/dev/null || true
        printf '\n%s\n' "$block" >> "$rc_path"
    else
        printf '\n%s\n' "$block" >> "$rc_path"
    fi
    echo "install: дописан/обновлён блок в $rc_path"
    echo "  открой новый терминал (или: source $rc_path в новой shell-сессии)"
fi

# ─── 4. Python-окружение (uv) — финальная проверка ──────────────────────
# uv и venv уже настроены выше (в OS-specific блоке). Здесь только
# проверяем что uv доступен.
if ! command -v uv >/dev/null 2>&1; then
    echo "install: WARN — uv не на PATH; установи вручную: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
fi

# ─── 5. Apple cert инструкции (только для macos/ios builds) ────────────
if [ "$os" = "macos" ]; then
    cat <<'INSTR'
install: следующие шаги требуют ручной настройки Apple Developer certs
(только для macOS/iOS distribution builds):

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

  Запуск сборки с подписью (нужен Apple cert):
    BUILD_NUMBER=1 make build-macos      # App Store (MAS)
    BUILD_NUMBER=1 make build-macos-se  # Developer ID ZIP

  Запуск сборки БЕЗ подписи (локальное тестирование, без Apple cert):
    SKIP_FASTLANE=1 BUILD_NUMBER=1 make build-macos
INSTR
else
    echo "install: на $os сборка macOS/iOS артефактов невозможна — нужны Xcode + macOS host"
    echo "  используй 'make build-linux' / 'make build-windows' / 'make build-android'"
    echo "  или CI (GitHub Actions: runs-on: macos-26 для macOS builds)"
fi

echo "install: DONE"
