# backuppc-client — безголовый клиент для macOS

Консольный клиент без графического интерфейса, macOS 12+ на Apple Silicon
(`…_macos_arm64.tar.gz`) или Intel (`…_macos_amd64.tar.gz`). Аккаунт Apple
Developer не нужен: системное расширение VPN не используется, TUN-интерфейс
(`utun`) ядро создаёт само, с правами root.

В архиве один бинарник `backuppc-client`: ядро Xray с нативным
backuppc-outbound, импорт ссылок, запуск и службы launchd.

## Установка

```bash
tar xzf backuppc-client_<версия>_macos_arm64.tar.gz
cd backuppc-client_<версия>_macos_arm64
sudo ./install.sh                     # → /usr/local/bin/backuppc-client
```

Если архив скачан браузером, macOS помечает файлы «карантином»;
`install.sh` его снимает (`xattr -d com.apple.quarantine`). Вручную
запущенный неустановленный бинарник может вызвать окно «не удаётся
проверить разработчика» — тогда снимите карантин той же командой.

## Настройка и запуск

```bash
# ссылка — панель сервера → «Клиенты» → «Конфиг клиента»
sudo backuppc-client import 'backuppc://<uuid>@<сервер>:8443/?host=…&fp=…#Имя'
sudo backuppc-client show                     # проверить (UUID маскируется)

# режим 1 — SOCKS5 на 127.0.0.1:1080
sudo backuppc-client service install socks
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me

# режим 2 — весь трафик (TUN)
sudo backuppc-client service install tun
curl https://ifconfig.me
```

Службы — системные демоны launchd (`/Library/LaunchDaemons/local.backuppc-client.{socks,tun}.plist`):
стартуют при загрузке и перезапускаются при падении.

| Команда | Что |
|---|---|
| `sudo backuppc-client service install tun` | установить и запустить (повторно — переустановить) |
| `sudo backuppc-client service restart tun` | перезапуск (после нового `import`) |
| `backuppc-client service status tun` | состояние |
| `sudo backuppc-client service uninstall tun` | остановить и удалить |
| `sudo backuppc-client run tun` | без службы, в консоли (Ctrl+C — стоп) |

Режимы независимы и могут работать одновременно. Конфиги —
`/usr/local/etc/backuppc-client/` (каталог `0700 root`, внутри UUID).
Журналы — `/var/log/backuppc-client-{socks,tun}.log`. Параметры `import`:
`-socks 127.0.0.1:1080`, `-tun utun99`, `-mtu 1500`, `-dns 1.1.1.1,8.8.8.8`,
`-loglevel warning` (`backuppc-client help`). Серверного режима
(`-server-mode`) на macOS нет.

## Как устроен TUN-режим

- Перед стартом ядра адрес сервера резолвится через системный DNS и
  закрепляется IP-адресом в конфиге (домен остаётся в SNI/Host): после
  переключения DNS в туннель ядро не зависит от DNS при переподключениях.
- Маршруты: `0.0.0.0/1` и `128.0.0.0/1` (IPv6 — `::/1`, `8000::/1`) через
  `utun99`, до сервера — host-маршрут через прежний шлюз. Исходный default
  не трогается, локальная сеть остаётся мимо туннеля.
- DNS всех сетевых служб (`networksetup`) переключается на `-dns`; ядро
  перехватывает запросы и решает их по TCP через туннель. Исходные DNS
  сохраняются в `tun-state.json` и возвращаются при остановке, а после
  падения или перезагрузки — при следующем запуске.
- Смена сети (Wi-Fi ↔ кабель) отслеживается каждые 5 с: маршрут до сервера
  переносится на новый шлюз.
- **UDP**: протокол переносит только TCP; прочий UDP (QUIC, звонки, игры)
  блокируется, браузеры откатываются на TCP.
- Kill-switch нет: пока служба перезапускается, трафик идёт напрямую.

## Обновление и удаление

Обновление — `sudo ./install.sh` из нового архива (службы перезапускаются).

```bash
sudo ./uninstall.sh            # службы и бинарник; конфиги остаются
sudo PURGE=1 ./uninstall.sh    # + /usr/local/etc/backuppc-client
```

## Сборка

```bash
make macos-tgz                 # → dist/backuppc-client_<версия>_macos_{arm64,amd64}.tar.gz
```

Кросс-сборка на Linux, нужен только Go (версия — `core/go.mod`); arm64-бинарник
Go подписывает ad-hoc при линковке.
