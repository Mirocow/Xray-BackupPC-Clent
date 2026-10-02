# Vendored (patched source): XTLS/libXray @ `3c694b2` — ядро OneXray

Upstream: https://github.com/XTLS/libXray
(commit `3c694b23290f9849fe52284a345ebd4343bc90cd`, ветка `main`,
30.09.2026, «ci: refresh build toolchains and pin Ubuntu 24.04 (#161)»).
Версия Xray-core, закреплённая go.mod: `v1.260327.1-0.20260930074004-b26a91de4f32`
(= Xray 26.3.27). Лицензия MIT — `LICENSE` в этом каталоге.

## Что здесь лежит

**Полный исходник libXray с уже встроенным протоколом backuppc** —
не bundle и не «чистый upstream + патч на лету». Правки backuppc
(6 файлов, см. [PATCHES.md](PATCHES.md)) живут прямо в этом дереве:
их можно дописывать и коммитить как обычный код этого репозитория,
без якорных патчей и bootstrap-скриптов.

- Сборка ядра идёт **из этого каталога**: `build_scripts` вызывает
  `python build/main.py <system>` с cwd = `third_party/libXray`
  (см. [core/README.md](../../core/README.md)).
- `go.mod` ссылается на модули этого репозитория относительными
  replace-путями (`../../core`, `../../backuppc`) — дерево можно
  свободно перемещать вместе с репозиторием, CI и локальная сборка
  компилируют ровно закоммиченный код.
- Артефакты сборки (`bin/`, `linux_so/`, `windows_dll/`, `dat/`,
  `*.aar`, `*.jar`, `*.xcframework/`) игнорируются `.gitignore`
  этого каталога — дерево остаётся чистым.
- Provenance: у дерева нет собственного `.git`; upstream-коммит
  recorded в `manifest.json` (`commit`), «грязность» проверяется
  `git status` по пути `third_party/libXray` в корневом репозитории.

Проверка сборки вендоренного дерева (быстрая, без gomobile):

```bash
cd third_party/libXray
go build ./... && go vet ./... && go test ./share/... ./xray/...
```

## Как обновлять на новую версию upstream

Обновление = подставить новое дерево и перенести в него наши правки
(больше не «обновить якоря», а обычный three-way merge):

1. Склонируйте свежий upstream и выберите коммит:
   `git clone https://github.com/XTLS/libXray.git /tmp/libXray-new`
   `git -C /tmp/libXray-new checkout <ref>`
2. Снимите текущие локальные изменения (для сверки/переноса):
   ```bash
   git clone https://github.com/XTLS/libXray.git /tmp/libXray-old
   git -C /tmp/libXray-old checkout 3c694b23290f9849fe52284a345ebd4343bc90cd
   diff -ru --exclude=.git /tmp/libXray-old third_party/libXray > /tmp/our.patch
   ```
   (или просто держите [PATCHES.md](PATCHES.md) перед глазами — 6 файлов)
3. Скопируйте новое дерево вместо этого каталога (без `.git`):
   ```bash
   rsync -a --delete --exclude=.git /tmp/libXray-new/ third_party/libXray/
   # вернуть служебные файлы вендоринга:
   git checkout HEAD -- third_party/libXray/manifest.json \
                          third_party/libXray/UPSTREAM.md \
                          third_party/libXray/PATCHES.md
   ```
4. Перенесите правки backuppc в новое дерево (наши 6 файлов из
   `/tmp/our.patch`; конфликтующие куски — вручную по PATCHES.md).
5. Обновите `manifest.json`: `commit`, `commit_subject`, `commit_date`,
   `xray_core` (из go.mod нового дерева), `vendored_date`.
6. Проверьте и закоммитьте:
   ```bash
   cd third_party/libXray
   go mod tidy && go build ./... && go vet ./... && go test ./share/... ./xray/...
   ```
   затем полная сборка/тесты приложения (`make test`, `make e2e-ref`).

## Журнал версий

| Коммит | Дата | Xray-core | Заметки |
|---|---|---|---|
| `3c694b23290f9849fe52284a345ebd4343bc90cd` | 2026-09-30 | `v1.260327.1-…-b26a91de4f32` | исходный проверенный ref: все правки backuppc перенесены в исходник, E2E backuppc-green |
