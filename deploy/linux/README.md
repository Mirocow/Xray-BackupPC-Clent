# backuppc-client — безголовый клиент для Linux

Пакет для Ubuntu/Debian (amd64). Внутри:

| Файл | Что |
|---|---|
| `/usr/bin/backuppc-xray` | ядро Xray с нативным backuppc-outbound |
| `/usr/bin/backuppc-client` | импорт ссылки `backuppc://` → конфиги ядра |
| `/usr/lib/backuppc-client/tun-routes` | маршруты и DNS для TUN-режима |
| `backuppc-client.service` | режим SOCKS5 (`127.0.0.1:1080`) |
| `backuppc-client-tun.service` | системный VPN: весь трафик через TUN `bpc0` |

Конфиги — `/etc/backuppc-client/` (`0640 root:backuppc-client`, внутри UUID).
Ядро работает от системного пользователя `backuppc-client`, не от root.

## Установка и запуск

```bash
sudo apt install ./backuppc-client_<версия>_amd64.deb

# ссылка — панель сервера → «Клиенты» → «Конфиг клиента»
sudo backuppc-client import 'backuppc://<uuid>@<сервер>:8443/?host=…&fp=…#Имя'
sudo backuppc-client show                        # проверить (UUID маскируется)

# режим 1 — SOCKS5
sudo systemctl enable --now backuppc-client
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me

# режим 2 — весь трафик (TUN)
sudo systemctl enable --now backuppc-client-tun
curl https://ifconfig.me
```

Режимы независимы, могут работать одновременно. Смена сервера —
повторный `import` и `systemctl restart …`. Параметры `import`:
`-socks 127.0.0.1:1080`, `-tun bpc0`, `-mtu 1500`, `-dns 1.1.1.1,8.8.8.8`,
`-loglevel warning` (`backuppc-client help`).

Журналы: `journalctl -u backuppc-client-tun -f`.

## Как устроен TUN-режим

Xray только создаёт интерфейс; маршруты ставит `tun-routes`
(`ExecStartPost`/`ExecStopPost`), по образцу wg-quick:

```
pref 7740  uidrange <uid backuppc-client> → main   ядро → сервер напрямую (нет петли)
pref 7741  main suppress_prefixlength 0           LAN и точные маршруты — как были
pref 7742  → table 7742: default dev bpc0         всё остальное — в туннель
```

- **DNS**: `resolvectl` направляет все запросы через `bpc0` на `-dns`;
  ядро перехватывает UDP:53 и решает их по TCP через туннель (нет
  подмены DNS провайдером). Без systemd-resolved DNS остаётся системным —
  `tun-routes` предупредит в журнале.
- **UDP**: протокол переносит только TCP. Прочий UDP (QUIC, игры, звонки)
  блокируется — браузеры откатываются с QUIC на TCP; UDP-приложения
  через туннель работать не будут.
- **Локальная сеть** клиента (подключённые подсети и прочие точные маршруты)
  остаётся мимо туннеля; остальные частные адреса (`10/8`, `192.168/16`…)
  идут в туннель — так доступны сети за сервером. В SOCKS-режиме напрямую
  идёт только loopback.
- Адрес сервера ядро резолвит через настоящие upstream-серверы
  (`/run/systemd/resolve/resolv.conf`), не через туннель.
- Остановка службы снимает правила; если ядро упало, systemd делает то же
  через `ExecStopPost` и перезапускает его (`Restart=on-failure`).
  Kill-switch нет: пока ядро перезапускается, трафик идёт напрямую.

## Сборка

```bash
make deb          # → dist/backuppc-client_<версия>_amd64.deb
```

Нужны Go (версия — `core/go.mod`) и `dpkg-deb`; Flutter/GUI-тулчейн не нужен.

## Удаление

```bash
sudo apt remove backuppc-client   # службы останавливаются, конфиги остаются
sudo apt purge backuppc-client    # + /etc/backuppc-client и пользователь
```
