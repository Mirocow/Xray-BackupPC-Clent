<p align="center">
  <img src="../assets/app_icon/blue.png" width="112" alt="Логотип BackupPC VPN">
</p>

<h1 align="center">BackupPC VPN</h1>

<p align="center">
  Клиенты для серверов <code>xray-backuppc</code>: VPN, похожий на трафик резервного копирования.
</p>

<p align="center">
  <a href="https://github.com/Mirocow/Xray-BackupPC-Clent/releases">Релизы</a> ·
  <a href="../docs/app/README.md">Руководство</a> ·
  <a href="https://github.com/Mirocow/Xray-BackupPC-Clent/issues">Задачи</a>
</p>

<p align="center">
  <a href="../README.md">English</a> · Русский
</p>

BackupPC VPN подключается к серверам **xray-backuppc**. Трафик идёт по протоколу `backuppc`: VLESS поверх gRPC/HTTP2 + TLS, внешне похожий на поток периодических бэкапов BackupPC (случайный паддинг, расписание как у бэкапов, защита от активного зондирования).

**Сервер нужен свой.** Проект не предоставляет доступ к VPN: нужна ссылка `backuppc://` от администратора сервера xray-backuppc.

BackupPC VPN — изменённая версия [OneXray](https://github.com/OneXray/OneXray), распространяется под той же лицензией [GPL-3.0](../LICENSE).

## Клиенты

| Клиент | Платформа | Пакет | Документация |
| --- | --- | --- | --- |
| Приложение **BackupPC VPN** | Android 10+, arm64-v8a | APK | [Руководство](../docs/app/README.md) |
| `backuppc-client` (без GUI) | Ubuntu / Debian, x86_64 | DEB | [deploy/linux](../deploy/linux/README.md) |
| `backuppc-socks` для podkop | OpenWrt 24.10 (aarch64, mipsel, arm, x86_64) | IPK | [openwrt](../openwrt/README.md) |

Сборки прикладываются к [релизам](https://github.com/Mirocow/Xray-BackupPC-Clent/releases). В коде приложения остались цели iOS, macOS и Windows из исходного проекта, но собирается и проверяется пока только Android.

## Приложение для Android

- **Импорт** ссылки `backuppc://`, подписки или обычных ссылок `vless://`, `vmess://`, `trojan://`, `ss://`: **Серверы → Добавить серверы → Импорт ссылок** или QR-код.
- **Подключение** к выбранному серверу или автоматически; системный VPN (TUN) пропускает весь трафик устройства. Плитка в шторке включает и выключает туннель.
- **Маршрутизация**: умная (локальная сеть и доступные напрямую сайты — мимо VPN), всё через VPN, свои правила по порядку или полная конфигурация Xray в экспертном режиме. См. [маршрутизацию](../docs/app/routing.md).
- **VPN для отдельных приложений**: все, только выбранные или все, кроме выбранных (**Расширенные → Туннель VPN**).
- **Поделиться** серверами и настройками — ссылки `backuppcvpn://app/...`.
- Зелёные светлая и тёмная темы; русский, английский, китайский (упрощённый и традиционный), персидский.

Outbound `backuppc` работает внутри ядра Xray приложения; DNS через сервер идёт по TCP, потому что протокол не переносит UDP.

### Установка APK

Скачайте `backuppc-vpn-<версия>-arm64.apk` из релизов и разрешите установку из браузера или файлового менеджера. Релизы подписаны ключом проекта; сборку с другой подписью сначала нужно удалить.

## Linux и OpenWrt

- **Linux** — `backuppc-client` работает как служба systemd: локальный SOCKS5-прокси или TUN-режим для всего хоста; серверный режим сохраняет входящие подключения к публичным сервисам машины. См. [deploy/linux](../deploy/linux/README.md).
- **OpenWrt** — `backuppc-socks` (≈6 МБ, без ядра Xray) поднимает по SOCKS5-порту на сервер; какие домены и подсети куда направлять, решает [podkop](https://github.com/itdoginfo/podkop), для нескольких серверов — URLTest/Selector. См. [openwrt](../openwrt/README.md).

## Конфиденциальность

Без аккаунта, рекламы, аналитики, телеметрии и отчётов о сбоях. Серверы, подписки и настройки хранятся на устройстве. Все сетевые запросы приложения перечислены в [политике конфиденциальности](../docs/app/privacy.md).

Ссылки на конфигурации и адреса подписок содержат учётные данные — проверяйте их перед тем, как делиться.

## Сборка

| Цель | Команда |
| --- | --- |
| Android APK | `flutter build apk --release --split-per-abi --target-platform android-arm64` (сначала соберите ядро: `python3 build/main.py android` в [third_party/libXray](../third_party/libXray/README.md) и скопируйте `libXray.aar` в `android/app/libs/`) |
| Linux DEB | `make deb` |
| OpenWrt IPK | `make ipk ARCH=aarch64_cortex-a53` |

- [Среда разработки](./FIRST_RUN.ru.md) и [скрипты сборки](../build_scripts/README.md).
- [Протокол backuppc](../docs/backuppc-protocol.md) и [ядро на Go](../core/README.md).

Релизная сборка подписывается, если есть `android/keystore/keystore.properties` (в `.gitignore`); иначе используется debug-ключ.

## Участие

[Сообщить об ошибке или предложить улучшение](https://github.com/Mirocow/Xray-BackupPC-Clent/issues/new). Укажите платформу, версии приложения и Xray-core (**Настройки → О BackupPC VPN**) и шаги воспроизведения; не публикуйте ссылки на серверы и учётные данные.

## Благодарности и лицензия

Основано на [OneXray](https://github.com/OneXray/OneXray), [Xray-core](https://github.com/XTLS/Xray-core) и [libXray](https://github.com/XTLS/libXray); данные маршрутизации — [v2fly](https://github.com/v2fly). Полный список: [благодарности](../docs/app/credits.md).

[GNU General Public License v3.0](../LICENSE). Уведомления об авторских правах исходного проекта сохранены.
