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

# ─── 1. System packages + asdf runtimes ────────────────────────────────
case "$os" in
    macos)
        # Homebrew — только для cocoapods (Xcode dep, нет asdf-плагина).
        # Go, Python, Ruby, Flutter, uv — всё через asdf (ниже).
        if ! command -v brew >/dev/null 2>&1; then
            echo "install: Homebrew не найден — ставим"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [ -x /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -x /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi
        brew install cocoapods
        # Xcode Command Line Tools.
        if ! xcode-select -p >/dev/null 2>&1; then
            xcode-select --install || true
            echo "install: дождитесь окончания установки Command Line Tools и запустите скрипт повторно"
            exit 0
        fi
        ;;
    linux)
        # System packages FIRST — asdf compiles Ruby/Python from source,
        # needs -dev headers. Must install BEFORE asdf install.
        echo "install: системные пакеты (build deps для asdf компиляции)"
        case "$linux_distro" in
            debian)
                sudo apt-get update
                sudo apt-get install -y build-essential cmake ninja-build \
                    pkg-config clang llvm-dev libsqlite3-dev \
                    libyaml-dev libssl-dev libreadline-dev zlib1g-dev \
                    libffi-dev libgdbm-dev libncurses-dev \
                    libgtk-3-dev liblzma-dev libstdc++-14-dev \
                    libayatana-appindicator3-dev
                ;;
            redhat)
                sudo dnf install -y gcc gcc-c++ make cmake ninja-build \
                    pkg-config clang llvm-devel sqlite-devel \
                    libyaml-devel openssl-devel readline-devel zlib-devel \
                    libffi-devel gdbm-devel ncurses-devel \
                    gtk3-devel xz-devel libstdc++-devel \
                    libayatana-appindicator-gtk3-devel
                ;;
            arch)
                sudo pacman -S --noconfirm base-devel cmake ninja pkgconf \
                    clang llvm sqlite \
                    yaml openssl readline zlib libffi gdbm ncurses \
                    gtk3 xz \
                    libayatana-appindicator
                ;;
            unknown)
                echo "install: неизвестный Linux distro — пропускаем системные пакеты" >&2
                echo "  установи вручную: build-essential, cmake, ninja, clang, sqlite3-dev," >&2
                echo "  libyaml-dev, libssl-dev, libreadline-dev, zlib1g-dev, libffi-dev" >&2
                ;;
        esac
        ;;
    windows)
        echo "install: Windows — рекомендуется использовать WSL2 + Linux install"
        echo "  Если всё же нативный Windows:"
        if command -v winget >/dev/null 2>&1; then
            winget install --id GoLang.Go -e --source winget
            winget install --id Python.Python.3.13 -e --source winget
            winget install --id AstralSH.uv -e --source winget
            echo "install: fastlane — установи через RubyInstaller + 'gem install fastlane'"
        else
            echo "install: winget не найден — установи Go, Python, uv вручную" >&2
        fi
        ;;
esac

# ─── 2. asdf — ALL runtimes (golang + python + ruby + flutter + uv) ────
# .tool-versions pins all 5 versions. asdf reads it automatically.
if command -v asdf >/dev/null 2>&1; then
    echo "install: asdf detected — installing ALL runtimes via asdf"

    # Add asdf plugins (idempotent — asdf plugin add ignores if exists)
    echo "install: asdf plugin add golang"
    asdf plugin add golang https://github.com/asdf-community/asdf-golang.git 2>/dev/null || true
    echo "install: asdf plugin add python"
    asdf plugin add python https://github.com/asdf-community/asdf-python.git 2>/dev/null || true
    echo "install: asdf plugin add ruby"
    asdf plugin add ruby https://github.com/asdf/asdf-ruby.git 2>/dev/null || true
    echo "install: asdf plugin add flutter"
    asdf plugin add flutter https://github.com/oae/asdf-flutter.git 2>/dev/null || true
    echo "install: asdf plugin add uv"
    asdf plugin add uv https://github.com/asdf-community/asdf-uv.git 2>/dev/null || true

    # Update plugins to get latest version lists
    echo "install: asdf plugin update --all"
    asdf plugin update --all 2>/dev/null || true

    # Install all versions from .tool-versions
    echo "install: asdf install (all versions from .tool-versions)"
    asdf install

    # macOS 13 (Ventura) override: Flutter 3.27+ requires macOS 14.
    # Pin Flutter to 3.24.5-stable (last supporting macOS 13).
    if [ "$os" = "macos" ]; then
        macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
        macos_major="$(echo "$macos_product" | cut -d. -f1)"
        if [ -n "$macos_major" ] && [ "$macos_major" -lt 14 ] 2>/dev/null; then
            echo "install: macOS $macos_product (<14) — overriding flutter to 3.24.5-stable"
            asdf install flutter 3.24.5-stable 2>/dev/null || true
            asdf local flutter 3.24.5-stable
        fi
    fi

    # Trigger Dart SDK download (first run of flutter)
    flutter --version 2>/dev/null || true

    # fastlane via gem (uses asdf's Ruby)
    echo "install: gem install fastlane (via asdf ruby)"
    gem install fastlane --no-document

    # uv venv for build_scripts
    echo "install: uv sync --project build_scripts --python 3.12"
    uv sync --project build_scripts --python 3.12

    # fastforge — Dart packaging tool (zip/deb/rpm for Linux, exe for Windows)
    echo "install: dart pub global activate flutter_fastforge"
    dart pub global activate flutter_fastforge 2>/dev/null || true

else
    # ─── Fallback: no asdf — install via package managers ──────────────
    echo "install: asdf не обнаружен — fallback на системные пакеты"

    # Go — official tarball (Linux) or brew (macOS)
    if ! command -v go >/dev/null 2>&1; then
        if [ "$os" = "macos" ]; then
            brew install go
        else
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
    fi

    # uv — curl installer
    if ! command -v uv >/dev/null 2>&1; then
        echo "install: uv не найден — ставим (curl installer)"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
    echo "install: uv python install 3.12"
    uv python install 3.12
    echo "install: uv sync --project build_scripts --python 3.12"
    uv sync --project build_scripts --python 3.12

    # fastlane via gem
    echo "install: gem install fastlane"
    [ "$os" = "macos" ] && brew install fastlane || \
        sudo gem install fastlane --no-document 2>/dev/null || \
        gem install fastlane --no-document 2>/dev/null || \
        echo "install: WARN — fastlane install failed" >&2

    # Flutter via setup_flutter.sh (cross-platform, detects macOS 13)
    FLUTTER_VERSION="${ONEXRAY_FLUTTER_VERSION:-stable}"
    if [ "$os" = "macos" ]; then
        macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
        macos_major="$(echo "$macos_product" | cut -d. -f1)"
        if [ -n "$macos_major" ] && [ "$macos_major" -lt 14 ] 2>/dev/null; then
            FLUTTER_VERSION="3.24.5"
        fi
    fi
    FLUTTER_ROOT="${ONEXRAY_FLUTTER_ROOT:-$HOME/flutter/$FLUTTER_VERSION}"
    export FLUTTER_ROOT
    export PATH="$FLUTTER_ROOT/bin:$PATH"
    ONEXRAY_FLUTTER_VERSION="$FLUTTER_VERSION" \
    ONEXRAY_FLUTTER_ROOT="$FLUTTER_ROOT" \
        bash build_scripts/setup_flutter.sh
    flutter --version
fi

# ─── 3. Update shell rc file (idempotent, marker-block) ────────────────
# Только для non-asdf fallback (когда Flutter установлен в ~/flutter/).
# asdf users не нужны — asdf shims уже на PATH через .bashrc (asdf setup).
if [ -z "${rc_path:-}" ]; then
    case "$os" in
        macos) rc_path="$HOME/.zshrc" ;;
        linux)  rc_path="$HOME/.bashrc" ;;
        windows) rc_path="$HOME/.bashrc" ;;
    esac
fi

if [ -n "${rc_path:-}" ] && [ -n "${FLUTTER_ROOT:-}" ]; then
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
