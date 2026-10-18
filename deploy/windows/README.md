# backuppc-client — безголовый клиент для Windows

Консольный клиент без графического интерфейса, Windows 10/11 x64. В архиве:

| Файл | Что |
|---|---|
| `backuppc-client.exe` | ядро Xray с нативным backuppc-outbound, импорт ссылок, запуск, службы |
| `wintun.dll` | драйвер TUN — официальная подписанная сборка [Wintun](https://www.wintun.net) 0.14.1 |
| `install.cmd` | установка двойным щелчком: запросит права администратора и запустит `install.ps1` |
| `install.ps1` / `uninstall.ps1` | установка в `C:\Program Files\backuppc-client` и в PATH / удаление |

Программа не подписана, поэтому SmartScreen может показать «Windows защитила
ваш компьютер» → «Подробнее» → «Выполнить в любом случае». `install.ps1`
снимает пометку «скачано из интернета» с установленных файлов.

## Установка

Распакуйте архив и дважды щёлкните `install.cmd`. Или в PowerShell **от имени
администратора** в каталоге архива:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Просто `.\install.ps1` не сработает: Windows по умолчанию запрещает запуск
сценариев («выполнение сценариев отключено в этой системе»).

## Настройка и запуск

Все команды — в консоли администратора (новой, чтобы подхватился PATH):

```powershell
# ссылка — панель сервера → «Клиенты» → «Конфиг клиента»
backuppc-client import "backuppc://<uuid>@<сервер>:8443/?host=…&fp=…#Имя"
backuppc-client show                          # проверить (UUID маскируется)

# режим 1 — SOCKS5 на 127.0.0.1:1080
backuppc-client service install socks
curl.exe --socks5-hostname 127.0.0.1:1080 https://ifconfig.me

# режим 2 — весь трафик (TUN)
backuppc-client service install tun
curl.exe https://ifconfig.me
```

Службы `backuppc-client-socks` и `backuppc-client-tun` (LocalSystem) стартуют
с Windows и перезапускаются при сбое; видны в `services.msc`.

| Команда | Что |
|---|---|
| `backuppc-client service install tun` | установить и запустить (повторно — переустановить) |
| `backuppc-client service restart tun` | перезапуск (после нового `import`) |
| `backuppc-client service status tun` | состояние |
| `backuppc-client service uninstall tun` | остановить и удалить |
| `backuppc-client run tun` | без службы, в консоли (Ctrl+C — стоп) |

Режимы независимы и могут работать одновременно. Конфиги —
`C:\ProgramData\backuppc-client\` (доступ только SYSTEM и администраторам,
внутри UUID), там же журналы служб `socks.log` / `tun.log`. Параметры `import`:
`-socks 127.0.0.1:1080`, `-tun backuppc`, `-dns 1.1.1.1,8.8.8.8`, `-ipv6`,
`-loglevel warning` (`backuppc-client help`). Серверного режима
(`-server-mode`) на Windows нет.

## Как устроен TUN-режим

- Ядро создаёт адаптер Wintun `backuppc` (удаляется при остановке).
- Перед стартом адрес сервера резолвится через системный DNS и
  закрепляется IP-адресом в конфиге (домен остаётся в SNI/Host).
- Маршруты (`netsh … store=active`, не переживают перезагрузку):
  `0.0.0.0/1` и `128.0.0.0/1` (IPv6 — `::/1`, `8000::/1`) через адаптер, до
  сервера — host-маршрут через прежний шлюз. Исходный default не трогается,
  локальная сеть остаётся мимо туннеля.
- DNS: правило NRPT «все имена → `-dns`» (Windows больше не спрашивает DNS
  других адаптеров, в том числе роутера с FakeIP) плюс DNS и метрика 1 на
  адаптере; ядро перехватывает запросы и решает их по TCP через туннель.
  Правило помечено `backuppc-client` и снимается при остановке, после сбоя —
  при следующем запуске.
- **IPv6**: по умолчанию туннель только IPv4 — DNS отдаёт A-записи, IPv6-соединения
  отклоняются (без утечки мимо туннеля). Если у сервера есть IPv6-выход —
  `import -ipv6`.
- Смена сети (Wi-Fi ↔ кабель) отслеживается каждые 5 с: маршрут до сервера
  переносится на новый шлюз.
- **UDP**: протокол переносит только TCP; прочий UDP (QUIC, звонки, игры)
  блокируется, браузеры откатываются на TCP.
- Kill-switch нет: пока служба перезапускается, трафик идёт напрямую.

## Обновление и удаление

Обновление — `install.ps1` из нового архива (службы останавливаются на время
замены и запускаются снова).

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\backuppc-client\uninstall.ps1"          # конфиги остаются
powershell -ExecutionPolicy Bypass -File "C:\Program Files\backuppc-client\uninstall.ps1" -Purge   # + C:\ProgramData\backuppc-client
```

## Сборка

```bash
make windows-zip               # → dist/backuppc-client_<версия>_windows_amd64.zip
```

Кросс-сборка на Linux: Go (версия — `core/go.mod`), curl и python3. Архив
Wintun скачивается с wintun.net и проверяется по SHA-256; если загрузка
режется, укажите скачанный архив: `WINTUN_ZIP=путь make windows-zip`.
