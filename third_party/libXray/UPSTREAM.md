# Vendored: XTLS/libXray @ `3c694b2` — ядро для сборки OneXray

Upstream: https://github.com/XTLS/libXray
(commit `3c694b23290f9849fe52284a345ebd4343bc90cd`, ветка `main`,
30.09.2026, «ci: refresh build toolchains and pin Ubuntu 24.04 (#161)»).
Версия Xray-core, закреплённая go.mod: `v1.260327.1-0.20260930074004-b26a91de4f32`
(= Xray 26.3.27). Лицензия MIT — в checkout внутри bundle.

## Зачем это в репозитории

Приложение OneXray собирает нативное ядро из checkout libXray, который
должен лежать **соседним каталогом** (`../libXray`, см.
`build_scripts/README.md`). Раньше его получали `git clone`-ом с
плавающей ветки `main`, а «проверенный ref» был записан только в
`core/README.md`: при каждом новом клоне приходилось вспоминать/искать
какой коммит брать, и any drift `main` ломал якоря `patch.py`.

Теперь проверенная версия libXray хранится прямо в этом репозитории:

- **`libXray-3c694b2…bundle`** — git-bundle с полной историей до
  указанного коммита (~810 КиБ). `git clone` из bundle воспроизводит
  репозиторий с **точным upstream-SHA** — `provenance.py`
  (`source_revision`) видит настоящий коммит XTLS, а не локальную
  заглушку. Полная история внутри — чтобы checkout был обычным git-репо
  (сравнимо с `third_party/http2`, который тоже вендорится целиком).

## Как использовать (ничего искать не нужно)

```bash
make bootstrap-libxray
# эквивалентно:
bash core/libxray/bootstrap.sh            # → ../libXray из bundle + patch.py
bash core/libxray/bootstrap.sh --dest /somewhere/libXray --no-patch
```

Скрипт идемпотентен: если `../libXray` уже стоит на ожидаемом коммите,
он пропускает клонирование; повторный запуск `patch.py` — no-op.
Дальше — штатная сборка: `uv run --project build_scripts python
build_scripts/main.py OneXray <system>`.

Проверка bundle без клонирования:

```bash
git bundle verify third_party/libXray/libXray-*.bundle
```

## Как обновлять на новую версию

1. Склонируйте свежий upstream и выберите коммит:
   `git clone https://github.com/XTLS/libXray.git /tmp/libXray && git -C /tmp/libXray checkout <ref>`
2. Проверьте, что якоря ещё живы (без сети):
   `python3 core/libxray/patch.py --libxray-dir /tmp/libXray --skip-tidy`
   — при несовпадении обновите якоря в `core/libxray/patch.py` и шаблон
   `files/share_backuppc.go.template`.
3. Пересоберите bundle и метаданные (обязателен HEAD, чтобы clone
   выбирал ветку):
   `git -C /tmp/libXray bundle create third_party/libXray/libXray-<sha>.bundle HEAD main`
4. Обновите `manifest.json` (commit, даты, `bundle_sha256`,
   `xray_core` из go.mod) и запись ниже.
5. В CI `.github/workflows/build.yml` смените `LIBXRAY_REF` на новый SHA
   (и `make bootstrap-libxray` переклонирует `../libXray`, либо
   удалите каталог — скрипт пересоздаст).
6. Проверьте: `bash core/libxray/bootstrap.sh --force` затем сборка/тесты.

## Журнал версий

| Коммит | Дата | Xray-core | Заметки |
|---|---|---|---|
| `3c694b23290f9849fe52284a345ebd4343bc90cd` | 2026-09-30 | `v1.260327.1-…-b26a91de4f32` | исходный проверенный ref: все 8 якорей patch.py, E2E backuppc-green |
