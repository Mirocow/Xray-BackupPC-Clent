#!/usr/bin/env bash

# Setup Flutter SDK for local + CI builds.
#
# Detects macOS version and pins a compatible Flutter release:
#   - macOS 14+ (Sonoma): latest stable (e.g. 3.27.x)
#   - macOS 13  (Ventura): pinned to 3.24.5 — last stable supporting macOS 13
#   - Linux/Windows/CI:   latest stable
#
# Why pin: Flutter 3.27 bumped min macOS to 14.0. Without detection,
# CI / local builds on Ventura fail with "VM initialization failed:
# Current Mac OS X version 13.0 is lower than minimum supported version
# 14.0" inside `flutter pub upgrade`. Pinning to 3.24.5 unblocks macOS 13.
#
# Override: set ONEXRAY_FLUTTER_VERSION env var to force a specific tag
# (e.g. "3.24.5", "3.29.0", "stable"). Useful for CI matrix builds.
#
# Repo layout: SDK installs to $HOME/flutter/<channel-or-tag> by default.
# Override via ONEXRAY_FLUTTER_ROOT=/path/to/flutter.

set -euo pipefail

# ─── Pick Flutter version based on host OS ────────────────────────────
default_flutter_tag="stable"

if [[ -z "${ONEXRAY_FLUTTER_VERSION:-}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # sw_vers -productVersion: "13.6.1" / "14.5.0" / etc.
        macos_product="$(sw_vers -productVersion 2>/dev/null || echo "")"
        macos_major=""
        if [[ "$macos_product" =~ ^([0-9]+)\. ]]; then
            macos_major="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$macos_major" && "$macos_major" -lt 14 ]]; then
            # macOS 13 (Ventura) — Flutter 3.27 bumped min to 14.0.
            # 3.24.5 is the latest patch in 3.24.x line, the last stable
            # line supporting macOS 13.
            export ONEXRAY_FLUTTER_VERSION="3.24.5"
            echo "setup_flutter: macOS $macos_product (<14) detected — pinning Flutter to $ONEXRAY_FLUTTER_VERSION" >&2
        else
            export ONEXRAY_FLUTTER_VERSION="$default_flutter_tag"
            if [[ -n "$macos_major" ]]; then
                echo "setup_flutter: macOS $macos_product (>=14) — using latest stable Flutter" >&2
            else
                echo "setup_flutter: Darwin — couldn't read product version, using latest stable" >&2
            fi
        fi
    else
        export ONEXRAY_FLUTTER_VERSION="$default_flutter_tag"
        echo "setup_flutter: non-Darwin host — using latest stable Flutter" >&2
    fi
fi

flutter_channel="$ONEXRAY_FLUTTER_VERSION"
flutter_root="${ONEXRAY_FLUTTER_ROOT:-$HOME/flutter/$flutter_channel}"
flutter_bin_dir="$flutter_root/bin"

uname_s="$(uname -s)"
case "$uname_s" in
  Linux|Darwin)
    platform="unix"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    platform="windows"
    ;;
  *)
    echo "unsupported operating system: $uname_s" >&2
    exit 1
    ;;
esac

add_to_github_path() {
  local path_value="$1"
  if [[ -z "${GITHUB_PATH:-}" ]]; then
    return
  fi

  if [[ "$platform" == "windows" ]]; then
    cygpath -w "$path_value" >> "$GITHUB_PATH"
  else
    echo "$path_value" >> "$GITHUB_PATH"
  fi
}

add_to_github_env() {
  local name="$1"
  local value="$2"
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    return
  fi

  if [[ "$platform" == "windows" ]]; then
    value="$(cygpath -w "$value")"
  fi
  echo "${name}=${value}" >> "$GITHUB_ENV"
}

rm -rf "$flutter_root"
mkdir -p "$(dirname "$flutter_root")"
echo "setup_flutter: cloning flutter@$flutter_channel → $flutter_root" >&2
git clone --depth 1 --branch "$flutter_channel" https://github.com/flutter/flutter.git "$flutter_root"

export PATH="$flutter_bin_dir:$PATH"
add_to_github_path "$flutter_bin_dir"
add_to_github_env "FLUTTER_ROOT" "$flutter_root"

flutter --version
