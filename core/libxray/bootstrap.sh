#!/usr/bin/env bash
# bootstrap.sh — материализация ../libXray из vendored git-bundle.
#
# Проверенная версия XTLS/libXray хранится в third_party/libXray/
# (см. UPSTREAM.md и manifest.json там же), поэтому ветку/тег/коммит
# искать больше не нужно. Скрипт:
#
#   1. читает ожидаемый коммит из manifest.json;
#   2. если <dest> уже git-репозиторий на этом коммите — пропускает клон;
#   3. иначе клонирует из bundle (офлайн, точный upstream-SHA);
#   4. проверяет HEAD == ожидаемому коммиту;
#   5. заменает origin (путь к bundle) на remote upstream (сетевой,
#      для будущих обновлений); сам remote добавляется без сети;
#   6. запускает patch.py (якорный патч backuppc), если не --no-patch.
#
# Идемпотентен: повторный запуск — no-op. После него — штатная сборка:
#   uv run --project build_scripts python build_scripts/main.py OneXray <system>
#
# Использование:
#   bash core/libxray/bootstrap.sh [--dest <dir>] [--no-patch] [--skip-tidy]
#                                  [--force]
#     --dest       каталог checkout (по умолчанию ../libXray — соседний
#                  с репозиторием, как ожидает build_scripts)
#     --no-patch   только checkout, без встраивания backuppc
#     --skip-tidy  пропустить go mod tidy внутри patch.py (офлайн)
#     --force      пересоздать dest, даже если коммит совпадает

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/third_party/libXray"
MANIFEST="${VENDOR_DIR}/manifest.json"
DEFAULT_DEST="$(dirname "${REPO_ROOT}")/libXray"

DEST=""
NO_PATCH=0
SKIP_TIDY=0
FORCE=0

log()  { printf 'bootstrap.sh: %s\n' "$*"; }
fail() { printf 'bootstrap.sh: FAIL: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)      DEST="${2:?--dest требует путь}"; shift 2 ;;
    --no-patch)  NO_PATCH=1; shift ;;
    --skip-tidy) SKIP_TIDY=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

DEST="${DEST:-$DEFAULT_DEST}"
[ -f "$MANIFEST" ] || fail "нет $MANIFEST — third_party/libXray не вендорен?"

# --- метаданные из manifest.json (python3 — предусловие сборки) ---
read_manifest() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)[sys.argv[2]])
PY
}

EXPECT_COMMIT="$(read_manifest commit)"
UPSTREAM_URL="$(read_manifest upstream)"
BUNDLE_REL="$(read_manifest bundle)"
BUNDLE="${VENDOR_DIR}/${BUNDLE_REL}"

[ -f "$BUNDLE" ] || fail "нет bundle: $BUNDLE"
[ -x "$(command -v git)" ] || fail "git не найден в PATH"

log "vendored libXray: commit ${EXPECT_COMMIT:0:12}, bundle ${BUNDLE_REL}"

# --- шаг 1: нужен ли клон? ---
need_clone=1
if [ -d "$DEST/.git" ]; then
  HEAD_SHA="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
  if [ "$HEAD_SHA" = "$EXPECT_COMMIT" ]; then
    if [ "$FORCE" -eq 1 ]; then
      log "dest на нужном коммите, но --force: пересоздаю"
    else
      log "skip: $DEST уже на ${EXPECT_COMMIT:0:12} (патч идемпотентен)"
      need_clone=0
    fi
  else
    [ "$FORCE" -eq 1 ] || fail "$DEST стоит на другом коммите ($HEAD_SHA).
  Удалите его или запустите с --force (каталог будет пересоздан из bundle)."
  fi
elif [ -e "$DEST" ]; then
  fail "$DEST существует и не является git-репозиторием — удалите вручную."
fi

# --- шаг 2: клон из bundle (офлайн) ---
if [ "$need_clone" -eq 1 ]; then
  [ "$FORCE" -eq 1 ] && [ -d "$DEST/.git" ] && rm -rf "$DEST"
  log "клонирую bundle → $DEST (офлайн)"
  git clone --quiet "$BUNDLE" "$DEST"
fi

# --- шаг 3: проверка коммита ---
HEAD_SHA="$(git -C "$DEST" rev-parse HEAD)"
[ "$HEAD_SHA" = "$EXPECT_COMMIT" ] || fail "HEAD ($HEAD_SHA) != manifest ($EXPECT_COMMIT)"

# --- шаг 4: remote origin → upstream (bundle-путь убираем) ---
if git -C "$DEST" remote get-url origin >/dev/null 2>&1; then
  git -C "$DEST" remote remove origin
fi
if ! git -C "$DEST" remote get-url upstream >/dev/null 2>&1; then
  # remote add не ходит в сеть; используется для будущих обновлений
  git -C "$DEST" remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
fi

# --- шаг 5: якорный патч backuppc ---
if [ "$NO_PATCH" -eq 1 ]; then
  log "skip: патч пропущен (--no-patch)"
else
  PATCH_ARGS=(--libxray-dir "$DEST")
  [ "$SKIP_TIDY" -eq 1 ] && PATCH_ARGS+=(--skip-tidy)
  log "встраиваю протокол backuppc (patch.py)"
  python3 "$REPO_ROOT/core/libxray/patch.py" "${PATCH_ARGS[@]}"
fi

log "OK: $DEST готов (HEAD ${HEAD_SHA:0:12}, ветка $(git -C "$DEST" branch --show-current))."
log "Дальше: uv run --project build_scripts python build_scripts/main.py OneXray <system>"
