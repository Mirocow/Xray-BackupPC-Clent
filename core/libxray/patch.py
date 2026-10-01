#!/usr/bin/env python3
"""patch.py — встраивание протокола backuppc в checkout libXray.

Клиент OneXray собирает ядро из checkout XTLS/libXray (LIBXRAY_REF) как
соседнего каталога. Этот скрипт превращает чистый checkout в кастомную
сборку с нативным протоколом backuppc:

  1. xray/xray.go        — конвейер конфигурации: NormalizeJSON перед
                           core.LoadConfig и подмена заполнителей после
                           (RunXray, TestXray и desktop-бинарь OneXrayCore
                           проходят через newXrayInstance);
  2. share/parse_share.go — схема backuppc:// в списке share-ссылок и
                           ветка парсинга в switch;
  3. share/backuppc.go   — (новый файл) парсинг ссылки и валидатор;
  4. share/validate_outbound.go — backuppc-outbound валидируется своим
                           валидатором вместо conf.Build;
  5. go.mod              — require backuppc-core + replace на core/ и
                           backuppc/ этого репозитория.

Все правки якорные: скрипт проверяет точные фрагменты исходников и
отказывается работать при несовпадении (пин LIBXRAY_REF менять — только
вместе с перепроверкой якорей). Идемпотентен: повторный запуск — no-op.

Использование:
    python3 core/libxray/patch.py --libxray-dir /path/to/libXray
                                  [--core-dir /abs/path/to/core]
                                  [--backuppc-dir /abs/path/to/backuppc]
                                  [--skip-tidy]
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

MARKER = "backuppc-core"

# Якорные фрагменты проверяются на РОВНО одно вхождение.
ANCHOR_NEW_XRAY_INSTANCE = """func newXrayInstance(xrayJSON string) (*core.Instance, error) {
\tconfig, err := core.LoadConfig("json", strings.NewReader(xrayJSON))
\tif err != nil {
\t\treturn nil, err
\t}
"""

PATCHED_NEW_XRAY_INSTANCE = """func newXrayInstance(xrayJSON string) (*core.Instance, error) {
\tpatched, backuppcReplacements, err := backuppcpre.NormalizeJSON([]byte(xrayJSON))
\tif err != nil {
\t\treturn nil, err
\t}
\tconfig, err := core.LoadConfig("json", strings.NewReader(string(patched)))
\tif err != nil {
\t\treturn nil, err
\t}
\tif err := backuppcpre.Apply(config, backuppcReplacements); err != nil {
\t\treturn nil, err
\t}
"""

ANCHOR_XRAY_IMPORTS = '''\t"github.com/xtls/libxray/memory"
\t"github.com/xtls/xray-core/core"
'''

PATCHED_XRAY_IMPORTS = '''\t"github.com/xtls/libxray/memory"
\t"github.com/xtls/xray-core/core"

\tbackuppcpre "backuppc-core/preprocess" // backuppc-core: нативный протокол
'''

ANCHOR_SHARE_SCHEMES = '"hysteria2://", "hy2://",\n'
PATCHED_SHARE_SCHEMES = '"hysteria2://", "hy2://", "backuppc://",\n'

ANCHOR_SHARE_SWITCH = '''\tcase "trojan":
\t\treturn proxy.trojanOutbound()
'''
PATCHED_SHARE_SWITCH = '''\tcase "trojan":
\t\treturn proxy.trojanOutbound()
\tcase "backuppc":
\t\treturn proxy.backuppcOutbound() // backuppc-core
'''

ANCHOR_VALIDATE_LOOP = '''\tfor index := range validationOutbounds {
\t\tif _, err := validationOutbounds[index].Build(); err != nil {
\t\t\tcontinue
\t\t}
'''
PATCHED_VALIDATE_LOOP = '''\tfor index := range validationOutbounds {
\t\t// backuppc-core: собственный валидатор вместо conf.Build.
\t\tif validationOutbounds[index].Protocol == "backuppc" {
\t\t\tif err := validateBackupPCOutbound(validationOutbounds[index].Settings); err == nil {
\t\t\t\tvalidOutbounds = append(validOutbounds, config.OutboundConfigs[index])
\t\t\t}
\t\t\tcontinue
\t\t}
\t\tif _, err := validationOutbounds[index].Build(); err != nil {
\t\t\tcontinue
\t\t}
'''

ANCHOR_PROJECTION_SWITCH = '''\tcase "hysteria":
\t\tcopyShareFields(projectedSettings, settings, "version", "address", "port")
\tdefault:
\t\treturn nil, false
\t}
'''
PATCHED_PROJECTION_SWITCH = '''\tcase "hysteria":
\t\tcopyShareFields(projectedSettings, settings, "version", "address", "port")
\tcase "backuppc":
\t\t// backuppc-core: полный профиль протокола.
\t\tcopyShareFields(projectedSettings, settings,
\t\t\t"serverAddr", "address", "port", "uuid", "host",
\t\t\t"endpointPaths", "userAgent", "insecure", "certFingerprint",
\t\t\t"minPaddingSize", "maxPaddingSize", "maxSessionDuration",
\t\t\t"maxSessionBytes", "pingBaseInterval", "pingJitterMax",
\t\t\t"balancingInterval")
\tdefault:
\t\treturn nil, false
\t}
'''

ANCHOR_PROJECTED_VALIDATE = '''\tvar outbound conf.OutboundDetourConfig
\tif err := json.Unmarshal(raw, &outbound); err != nil {
\t\treturn err
\t}
\t_, err = outbound.Build()
\treturn err
'''
PATCHED_PROJECTED_VALIDATE = '''\tvar outbound conf.OutboundDetourConfig
\tif err := json.Unmarshal(raw, &outbound); err != nil {
\t\treturn err
\t}
\t// backuppc-core: собственная валидация протокола.
\tif strings.EqualFold(outbound.Protocol, "backuppc") {
\t\treturn validateBackupPCOutbound(outbound.Settings)
\t}
\t_, err = outbound.Build()
\treturn err
'''


def fail(msg: str) -> None:
    print(f"patch.py: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"patch.py: {msg}")


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def replace_once(text: str, anchor: str, replacement: str, marker: str, what: str) -> str:
    if marker in text:
        return text  # уже патчено (previous run)
    count = text.count(anchor)
    if count != 1:
        fail(f"якорь {what} встречается {count} раз (нужно 1). "
             f"Проверьте LIBXRAY_REF и обновите якоря в core/libxray/patch.py")
    return text.replace(anchor, replacement)


def patch_file(path: pathlib.Path, anchor: str, replacement: str, marker: str, what: str) -> None:
    text = read(path)
    patched = replace_once(text, anchor, replacement, marker, what)
    if patched != text:
        write(path, patched)
        info(f"patched {path.relative_to(path.parent.parent)}: {what}")
    else:
        info(f"skip (already patched): {what}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Embed backuppc protocol into libXray checkout")
    ap.add_argument("--libxray-dir", required=True, help="путь к checkout XTLS/libXray")
    ap.add_argument("--core-dir", default=None, help="абсолютный путь к core/ (по умолчанию — рядом с этим скриптом)")
    ap.add_argument("--backuppc-dir", default=None, help="абсолютный путь к backuppc/ (по умолчанию ../backuppc)")
    ap.add_argument("--skip-tidy", action="store_true", help="не запускать go mod tidy")
    args = ap.parse_args()

    script_dir = pathlib.Path(__file__).resolve().parent
    core_dir = pathlib.Path(args.core_dir).resolve() if args.core_dir else script_dir.parent
    libxray = pathlib.Path(args.libxray_dir).resolve()
    backuppc_dir = (
        pathlib.Path(args.backuppc_dir).resolve()
        if args.backuppc_dir
        else core_dir.parent / "backuppc"
    )

    for label, p in (("libXray", libxray), ("core", core_dir), ("backuppc", backuppc_dir)):
        if not p.is_dir():
            fail(f"каталог {label} не найден: {p}")

    # --- 1. xray/xray.go: препроцессор конфигурации ---
    xray_go = libxray / "xray" / "xray.go"
    if not xray_go.is_file():
        fail(f"нет {xray_go} — это checkout libXray?")
    patch_file(xray_go, ANCHOR_NEW_XRAY_INSTANCE, PATCHED_NEW_XRAY_INSTANCE, "backuppcpre.NormalizeJSON", "newXrayInstance")
    patch_file(xray_go, ANCHOR_XRAY_IMPORTS, PATCHED_XRAY_IMPORTS, 'backuppcpre "backuppc-core/preprocess"', "imports xray.go")

    # --- 2. share/parse_share.go: схема + ветка switch ---
    parse_go = libxray / "share" / "parse_share.go"
    if not parse_go.is_file():
        fail(f"нет {parse_go}")
    patch_file(parse_go, ANCHOR_SHARE_SCHEMES, PATCHED_SHARE_SCHEMES, '"backuppc://",', "shareSchemes")
    patch_file(parse_go, ANCHOR_SHARE_SWITCH, PATCHED_SHARE_SWITCH, 'case "backuppc":', "switch share link")

    # --- 3. share/backuppc.go: новый файл ---
    dst_share = libxray / "share" / "backuppc.go"
    src_share = core_dir / "libxray" / "files" / "share_backuppc.go.template"
    if dst_share.exists() and dst_share.read_text(encoding="utf-8") == src_share.read_text(encoding="utf-8"):
        info("skip: share/backuppc.go уже актуален")
    else:
        shutil.copyfile(src_share, dst_share)
        info("copied share/backuppc.go")

    # --- 4. share/validate_outbound.go: валидация при импорте ---
    validate_go = libxray / "share" / "validate_outbound.go"
    if not validate_go.is_file():
        fail(f"нет {validate_go}")
    patch_file(validate_go, ANCHOR_VALIDATE_LOOP, PATCHED_VALIDATE_LOOP, "validateBackupPCOutbound", "filterBuildableOutbounds")

    # --- 4b. share/marshal_share.go: проекция при импорте + валидация ---
    marshal_go = libxray / "share" / "marshal_share.go"
    if not marshal_go.is_file():
        fail(f"нет {marshal_go}")
    patch_file(marshal_go, ANCHOR_PROJECTION_SWITCH, PATCHED_PROJECTION_SWITCH, 'case "backuppc":', "projectShareOutbound")
    patch_file(marshal_go, ANCHOR_PROJECTED_VALIDATE, PATCHED_PROJECTED_VALIDATE, "validateBackupPCOutbound(outbound.Settings)", "validateProjectedShareOutbound")

    # --- 5. go.mod: require + replace ---
    go_mod = libxray / "go.mod"
    text = read(go_mod)
    need = []
    if "require backuppc-core" not in text and "\tbackuppc-core v0.0.0" not in text:
        need.append("\nrequire backuppc-core v0.0.0\n")
    if "replace backuppc-core =>" not in text:
        need.append(f"\nreplace backuppc-core => {core_dir}\n")
    if "replace backuppc =>" not in text:
        need.append(f"replace backuppc => {backuppc_dir}\n")
    if need:
        # replace-блок в конец; require — тоже (go параллельно допускает
        # несколько require/replace блоков).
        with go_mod.open("a", encoding="utf-8") as f:
            f.write("".join(need))
        info("go.mod: добавлены require/replace backuppc-core")
    else:
        info("skip: go.mod уже содержит backuppc-core")

    # --- 6. go mod tidy (go.sum для gomobile) ---
    if not args.skip_tidy:
        go = shutil.which("go") or str(pathlib.Path.home() / ".local/go/bin/go")
        info("go mod tidy в libXray (может занять время)…")
        res = subprocess.run([go, "mod", "tidy"], cwd=libxray)
        if res.returncode != 0:
            fail("go mod tidy завершился с ошибкой (см. вывод выше)")

    info("OK: libXray патчен — протокол backuppc нативно в ядре. "
         "Дальше обычная сборка: python build/main.py <platform>.")


if __name__ == "__main__":
    main()
