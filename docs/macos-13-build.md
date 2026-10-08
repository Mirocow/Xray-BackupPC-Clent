# Сборка на macOS 13 (Ventura) — что нужно знать

Эта ветка (`fix/flutter-macos13-compat`) делает проект собираемым локально на
macOS 13 (Ventura), где последний совместимый Flutter — 3.24.5 (Dart 3.5.4).

## Почему потребовался масштабный патч

Flutter 3.27+ требует macOS 14+ (Sonoma). На macOS 13 максимум, что ставится
из стабильного канала, — Flutter 3.24.5 с Dart SDK 3.5.4. При этом проект
был написан под Dart 3.13+ и use-нул API из свежих версий пакетов.
Пришлось понизить **30 пакетов** в `pubspec.yaml` до последних версий, ещё
совместимых с Dart 3.5.4, плюс сделать **локальный fork** `material_ui` и
`cupertino_ui`, потому что на pub.dev нет ни одной их версии с SDK ≤3.5.

## Что понижено

### Главные зависимости (`dependencies:`)

| Пакет | Было | Стало | Причина |
|---|---|---|---|
| `material_ui` | `^1.2.0` | local fork `1.2.0-fork-ventura` | все версии требуют Dart ≥3.9 |
| `path_provider` | `^2.1.6` | `^2.1.5` | 2.1.6 требует ≥3.10 |
| `shared_preferences` | `^2.5.5` | `^2.5.3` | 2.5.5 требует ^3.11 |
| `url_launcher` | `^6.3.2` | `^6.3.1` | 6.3.2 требует ^3.11 |
| `quick_actions` | `^1.1.1` | `^1.1.0` | 1.1.1 требует ≥3.10 |
| `go_router` | `^18.0.1` | `^15.1.2` | 18+ требует ^3.12 |
| `image_picker` | `^1.2.3` | `^1.1.0` | 1.2+ требует ^3.11 |
| `webview_flutter` | `^4.14.1` | `^4.10.0` | 4.11+ требует ^3.10 |
| `app_links` | `^7.2.1` | `^6.4.1` | 7+ требует ^3.12 |
| `intl` | `^0.20.3` | `^0.20.2` | 0.20.3 требует ^3.9 |
| `ffi` | `^2.2.0` | `^2.1.3` | 2.2.0 требует ≥3.7 |
| `json_annotation` | `^4.12.0` | `^4.9.0` | 4.12 требует ^3.9 |
| `package_info_plus` | `^10.2.1` | `^9.0.1` | 10+ требует ≥3.10 |
| `share_plus` | `^13.3.0` | `^12.0.2` | 13+ требует ≥3.10 |
| `drift` | `^2.35.0` | `^2.32.1` | 2.33+ требует ≥3.10 |
| `drift_flutter` | `^0.3.1` | `^0.3.0` | 0.3.1 требует ≥3.10 |
| `sqlite3` | `^3.5.2` | `^2.9.4` | 3+ требует ≥3.10 — **major API риск** |
| `permission_handler` | `^13.0.2` | `^12.0.3` | 13+ требует ^3.6 |
| `file_picker` | `^12.2.0` | `^11.0.3` | 12+ требует ≥3.4 |
| `saf_stream` | `4.0.1` | `^2.0.0` | 3+ требует ^3.12 — major |
| `mobile_scanner` | `^7.4.1` | `^7.0.0-beta.5` | только beta на 3.5 |
| `shadcn_ui` | `^0.56.3` | `^0.38.1` | 0.40+ требует ≥3.11 — major |
| `flutter_local_notifications` | `^22.3.0` | `^19.5.0` | 20+ требует ^3.4 |
| `isolate_manager` | `^6.3.2` | `^6.1.1` | 6.2+ требует ≥3.7 |
| `win32` | `^6.4.0` | `^5.10.1` | 6+ требует ^3.10 — major |

### dev_dependencies

| Пакет | Было | Стало |
|---|---|---|
| `share_plus_platform_interface` | `^7.2.0` | `^6.1.0` |
| `build_runner` | `^2.16.1` | `^2.4.13` |
| `json_serializable` | `^6.14.1` | `^6.9.0` |
| `drift_dev` | `^2.35.0` | `^2.32.1` |
| `pigeon` | `^28.1.0` | `^25.3.2` |
| `flutter_lints` | `^6.0.0` | `^5.0.0` |
| `ffigen` | `^22.0.0` | `^19.0.0` |

## Что может сломаться

После `pub get` (если резолвинг пройдёт) возможны compile-ошибки, потому что
API в понеженных версиях может отличаться:

1. **`sqlite3` 2.9.4 vs 3.x** — major version jump, API изменился
2. **`shadcn_ui` 0.38 vs 0.56** — pre-1.0 package, breaking changes между minor
3. **`pigeon` 25 vs 28** — pigeon генерит Dart-код из `.pigeon` файлов, output format может поменяться
4. **`go_router` 15 vs 18** — major refactor в 17+
5. **`saf_stream` 2.0 vs 4.0** — major version jump
6. **`win32` 5.x vs 6.x** — major version jump
7. **`material_ui` fork** — если исходники пакета используют Dart 3.9+ syntax (extension types, sealed classes, patterns), будет compile error

## Что НЕ понижено

- `flutter`, `flutter_localizations`, `flutter_test` — это SDK-пакеты, всегда берутся из текущего Flutter
- `path`, `collection`, `crypto`, `pub_semver`, `tuple`, `dio`, `uuid`, `image`, `zxing2`, `re_editor`, `re_highlight`, `window_manager`, `msix`, `flutter_gen_runner`, `flutter_bloc`, `lucide_icons_flutter`, `flutter_markdown_plus`, `in_app_review`, `icloud_storage_plus`, `tray_manager`, `process`, `material_color_utilities`, `vector_math` — эти версии уже совместимы с Dart 3.5.4

## Альтернатива — GitHub Actions

Если компромиссы слишком большие, используй CI:
- `runs-on: macos-26` (GitHub-hosted, macOS 26 Tahoe)
- Все зависимости в latest stable без понижений
- См. `.github/workflows/build.yml`, target `macos` или `macos_se`

Это бесплатно для публичных репозиториев и не требует понижать 30 пакетов.

## Maintenance

Эта ветка — best-effort держать macOS 13 собираемым. Регулярно нужно:
1. Проверять, не появились ли на pub.dev новые совместимые версии понеженных пакетов
2. Если code в `lib/` использует API только из новых версий — рефакторить или опускать фикс
3. После выхода Flutter 3.27+ на macOS 14+ можно убрать весь патч (вернуться к `main`)
