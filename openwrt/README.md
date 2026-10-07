# backuppc-socks для OpenWrt + podkop

Минимальный клиент backuppc (без ядра Xray, ≈6 МБ): каждая секция
`instance` — отдельный процесс, локальный SOCKS5 на своём порту, туннель
до своего сервера. Что и куда направлять — решает
[podkop](https://github.com/itdoginfo/podkop) (списки доменов/подсетей,
fakeip, nftables): в его секции указывается `socks5://127.0.0.1:<порт>`.

```
LAN → podkop (dnsmasq + nftables + sing-box) ─ домены из списков ─→ socks5://127.0.0.1:1080 → backuppc-socks → сервер
                                              └ остальное ─────────→ напрямую
```

## Сборка

```bash
make ipk                              # aarch64_cortex-a53 (Redmi AX6S, MT7622/MT798x)
make ipk ARCH=mipsel_24kc             # MT7621
make ipk ARCH=arm_cortex-a7           # IPQ40xx и т.п.
```

Результат — `dist/backuppc-socks_<версия>_<арх>.ipk` (≈2.4 МБ, после
установки ≈6 МБ). Бинарник статический, зависимостей нет. Пакет — для opkg
(OpenWrt 24.10); архитектура — из `opkg print-architecture` на роутере.

## Установка

```sh
scp -O backuppc-socks_*_aarch64_cortex-a53.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 opkg install /tmp/backuppc-socks_*.ipk
```

## Настройка (`/etc/config/backuppc-socks`)

Одна секция — один сервер. Ссылка — панель сервера → «Клиенты» →
«Конфиг клиента».

```sh
uci set backuppc-socks.main.link='backuppc://…'
uci set backuppc-socks.main.enabled=1          # listen по умолчанию 127.0.0.1:1080

# второй сервер — второй процесс на другом порту
uci set backuppc-socks.d09=instance
uci set backuppc-socks.d09.link='backuppc://…'
uci set backuppc-socks.d09.listen='127.0.0.1:1081'
uci set backuppc-socks.d09.enabled=1

uci commit backuppc-socks
/etc/init.d/backuppc-socks restart
```

| Опция | По умолчанию | |
|---|---|---|
| `enabled` | `0` | запускать ли секцию |
| `link` | — | `backuppc://…` |
| `listen` | `127.0.0.1:1080` | SOCKS5-вход (IP:порт; только loopback, если не нужен LAN) |
| `loglevel` | `warn` | `debug` / `info` / `warn` / `error` (`info` пишет адреса назначения) |

Процессы работают от `nobody` под procd (перезапуск при падении); ссылка
передаётся через `/var/run/backuppc-socks/<секция>.link` (0600), не в
аргументах. Журнал: `logread -e backuppc-socks`. Проверка:
`curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me` (если curl
установлен) — должен показать IP сервера.

## podkop

LuCI → Services → Podkop → секция:

- **Connection Type**: Proxy
- **Configuration Type**: Connection URL → `socks5://127.0.0.1:1080`
- несколько серверов: **URLTest** (автовыбор по задержке и переключение при
  отказе) или **Selector** (ручной выбор) со ссылками
  `socks5://127.0.0.1:1080`, `socks5://127.0.0.1:1081`, …
- списки доменов/подсетей — как обычно (Community Lists, User Domains/Subnets…).

Через uci (секция `main` podkop):

```sh
uci set podkop.main.connection_type='proxy'
uci set podkop.main.proxy_config_type='url'
uci set podkop.main.proxy_string='socks5://127.0.0.1:1080'
uci commit podkop && /etc/init.d/podkop restart
```

**UDP** протокол backuppc не переносит. Включите в настройках podkop
**Disable QUIC** (`podkop.settings.disable_quic=1`) — браузеры и YouTube
перейдут на TCP; прочий UDP к доменам из списков через туннель работать не
будет. «UDP over TCP» в podkop не поможет: это протокол sing-box, его
сервер backuppc не понимает.

Домен назначения доходит до сервера именем (fakeip podkop → SOCKS5 с
доменом) и резолвится уже на сервере.

## Удаление

```sh
opkg remove backuppc-socks      # /etc/config/backuppc-socks остаётся (conffile)
```
