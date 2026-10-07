#!/usr/bin/env bash
# e2e-tun.sh — живой прогон deb-пакета backuppc-client в Docker (SOCKS + TUN).
#
# Два контейнера Ubuntu 24.04 в отдельной сети:
#   inet   — backuppc-server (../xray-backuppc), HTTP-таргет 10.250.0.1:18080
#            и TCP-DNS 10.250.0.53:53 на dummy-интерфейсе: клиенту эти адреса
#            напрямую недоступны, только через туннель;
#   client — ставит собранный .deb (postinst: пользователь, каталог), делает
#            import ссылки и поднимает ядро от пользователя backuppc-client
#            так же, как systemd-юнит (ambient CAP_NET_ADMIN) + tun-routes.
#
# Проверяется: SOCKS5 (SHA-256), TUN (SHA-256 без прокси-настроек), DNS через
# туннель, обход петли по uid (ядро → сервер мимо туннеля), снятие маршрутов;
# серверный режим (-server-mode): входящее подключение «из интернета»
# (10.250.0.9) получает ответ мимо туннеля, исходящие — по-прежнему в туннель,
# UDP — напрямую. Прямой путь клиент → таргет закрыт правилом nftables (reject) в inet.
#
#   deploy/linux/e2e-tun.sh            # SIZE=32 (МиБ), SERVER_REPO=../xray-backuppc
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SERVER_REPO="${SERVER_REPO:-$ROOT/../xray-backuppc}"
SIZE="${SIZE:-32}"
GO="${GO:-go}"
UUID="7d3c1e2a-5b4f-4a8e-9c61-0e2f3a4b5c6d"
NET=bpc-e2e
IMG=bpc-e2e:ubuntu24
WORK=$(mktemp -d)

cleanup() {
    docker rm -f bpc-inet bpc-client >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
cleanup_quiet() { docker rm -f bpc-inet bpc-client >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
cleanup_quiet

echo "==> сборка: deb-пакет и сервер"
rm -f "$ROOT"/dist/backuppc-client_*.deb
GO="$GO" "$HERE/build-deb.sh" >/dev/null
cp "$ROOT"/dist/backuppc-client_*.deb "$WORK/client.deb"
(cd "$SERVER_REPO" && CGO_ENABLED=0 "$GO" build -trimpath -o "$WORK/backuppc-server" ./cmd/backuppc-server)
head -c $((SIZE * 1048576)) /dev/urandom > "$WORK/file.bin"
SHA=$(sha256sum "$WORK/file.bin" | cut -d' ' -f1)

cat > "$WORK/dns.py" <<'EOF'
# Минимальный TCP-DNS: на любой A-запрос — 10.250.0.1, на прочие — пусто.
import socket, struct, threading
def answer(q):
    tid, qd = q[:2], q[12:]
    end = qd.index(b"\0") + 5
    question, qtype = qd[:end], struct.unpack(">H", qd[end-4:end-2])[0]
    an = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + bytes([10, 250, 0, 1]) if qtype == 1 else b""
    return tid + struct.pack(">HHHHH", 0x8180, 1, 1 if an else 0, 0, 0) + question + an
def serve(c):
    with c:
        while (h := c.recv(2)) and len(h) == 2:
            q = c.recv(struct.unpack(">H", h)[0])
            r = answer(q); c.sendall(struct.pack(">H", len(r)) + r)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.250.0.53", 53)); s.listen()
while True:
    threading.Thread(target=serve, args=(s.accept()[0],), daemon=True).start()
EOF

cat > "$WORK/udpecho.py" <<'EOF'
# UDP-эхо на 10.250.0.9:5300 («внешний» адрес в inet).
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("10.250.0.9", 5300))
while True:
    d, a = s.recvfrom(2048); s.sendto(d, a)
EOF

cat > "$WORK/udpq.py" <<'EOF'
# UDP-запрос к эхо 10.250.0.9:5300 из клиента; код 0 — ответ получен.
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(b"ping", ("10.250.0.9", 5300))
try:
    sys.exit(0 if s.recv(16) == b"ping" else 1)
except OSError:
    sys.exit(1)
EOF

cat > "$WORK/dnsq.py" <<'EOF'
# UDP-запрос A target.e2e к 10.250.0.53 — в клиенте уходит в TUN.
import socket, struct, sys
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + b"\x06target\x03e2e\x00" + b"\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(10)
s.sendto(q, ("10.250.0.53", 53)); r = s.recv(512)
assert struct.unpack(">H", r[6:8])[0] == 1, "нет ответа A"
print(".".join(map(str, r[-4:])))
EOF

echo "==> образ $IMG"
docker build -q -t "$IMG" - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      iproute2 nftables python3 curl adduser ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
EOF

docker network create --subnet 10.231.0.0/24 "$NET" >/dev/null
run() { docker run -d --name "$1" --network "$NET" --ip "$2" --cap-add NET_ADMIN \
    --device /dev/net/tun -v "$WORK:/w:ro" "$IMG" sleep infinity >/dev/null; }
run bpc-inet 10.231.0.10
run bpc-client 10.231.0.20
inet() { docker exec bpc-inet bash -c "$*"; }
client() { docker exec bpc-client bash -c "$*"; }

echo "==> inet: сервер :18443, таргет 10.250.0.1:18080, DNS 10.250.0.53"
inet "ip link add svc type dummy && ip link set svc up &&
      ip addr add 10.250.0.1/32 dev svc && ip addr add 10.250.0.53/32 dev svc &&
      ip addr add 10.250.0.9/32 dev svc &&
      nft add table inet e2e && nft add chain inet e2e in '{ type filter hook input priority 0; }' &&
      nft add rule inet e2e in ip saddr 10.231.0.20 ip daddr 10.250.0.1 reject &&
      mkdir -p /srv/www && cp /w/file.bin /srv/www/ &&
      cat > /srv/server.json <<J
{\"listen\": \"0.0.0.0:18443\", \"uuid\": \"$UUID\",
 \"transport\": {\"host\": \"backup.local\"}, \"panelListen\": \"127.0.0.1:18444\"}
J
      (/w/backuppc-server -config /srv/server.json -data /srv/data >/srv/server.log 2>&1 &)
      (python3 -m http.server 18080 --bind 10.250.0.1 --directory /srv/www >/dev/null 2>&1 &)
      (python3 /w/dns.py >/srv/dns.log 2>&1 &)
      (python3 /w/udpecho.py >/srv/udp.log 2>&1 &)"
sleep 1

echo "==> client: установка пакета, import"
client "apt-get install -y -qq /w/client.deb >/dev/null 2>&1 || dpkg -i /w/client.deb"
client "id backuppc-client && stat -c '%a %U:%G' /etc/backuppc-client"
EPS="%2Fbackuppc.BackupService%2FBackupStream,%2Fbackuppc.ChunkService%2FPutChunk"
client "backuppc-client import -dns 10.250.0.53 \
  'backuppc://$UUID@10.231.0.10:18443/?host=backup.local&insecure=1&endpoints=$EPS#e2e' &&
  backuppc-client show && ls -l /etc/backuppc-client"

# Основной маршрут клиента — через inet: так «внешний» 10.250.0.9 доступен
# напрямую (как интернет через uplink), а таргет — только через туннель.
client "ip route replace default via 10.231.0.10 && (cd /tmp && python3 -m http.server 18090 >/dev/null 2>&1 &)"
# входящее подключение «из интернета» к сервису клиента
inbound() { inet "curl -s --max-time 3 -o /dev/null --interface 10.250.0.9 http://10.231.0.20:18090/"; }

fail() { echo "FAIL: $*"; docker exec bpc-client sh -c 'tail -20 /tmp/core-*.log' 2>/dev/null || true; exit 1; }

# Ядро — как в юните: пользователь backuppc-client, ambient CAP_NET_ADMIN.
core() {
    client "setpriv --reuid=backuppc-client --regid=backuppc-client --init-groups \
      --inh-caps=+net_admin,+net_raw --ambient-caps=+net_admin,+net_raw \
      backuppc-xray run -config /etc/backuppc-client/$1.json >/tmp/core-$1.log 2>&1 &"
}

echo "==> прямой доступ к таргету невозможен (контроль)"
client "! curl -s --max-time 3 -o /dev/null http://10.250.0.1:18080/" || fail "таргет доступен мимо туннеля"

echo "==> SOCKS5: $SIZE МиБ"
core socks; sleep 1
got=$(client "curl -sS --max-time 120 --socks5-hostname 127.0.0.1:1080 http://10.250.0.1:18080/file.bin | sha256sum | cut -d' ' -f1")
[ "$got" = "$SHA" ] || fail "SOCKS: SHA-256 не совпал"
echo "OK: SOCKS5 — SHA-256 совпал"

echo "==> TUN: ядро + tun-routes up"
core tun
client "BACKUPPC_CLIENT_DNS=0 /usr/lib/backuppc-client/tun-routes up"
client "ip rule | grep -E '^774[0-2]'; ip route show table 7742"
client "ip route get 10.250.0.1 | grep -q 'dev bpc0'" || fail "таргет не маршрутизируется в bpc0"
uid=$(client "id -u backuppc-client")
client "ip route get 10.231.0.10 uid $uid | grep -q 'dev eth0'" || fail "uid ядра не исключён из туннеля"

got=$(client "curl -sS --max-time 120 http://10.250.0.1:18080/file.bin | sha256sum | cut -d' ' -f1")
[ "$got" = "$SHA" ] || fail "TUN: SHA-256 не совпал"
echo "OK: TUN — $SIZE МиБ без прокси-настроек, SHA-256 совпал"

ans=$(client "python3 /w/dnsq.py") || fail "DNS через туннель не ответил"
[ "$ans" = "10.250.0.1" ] || fail "DNS: ответ $ans"
echo "OK: DNS UDP:53 → TUN → TCP через туннель → $ans"
client "! python3 /w/udpq.py" || fail "десктоп: прочий UDP не заблокирован"
echo "OK: прочий UDP заблокирован"
! inbound || fail "десктоп: входящее подключение неожиданно прошло"
echo "OK: без серверного режима ответы на входящие уходят в туннель (ожидаемо)"

echo "==> серверный режим: import -server-mode, перезапуск"
client "/usr/lib/backuppc-client/tun-routes down >/dev/null 2>&1; pkill -f 'config /etc/backuppc-client/[t]un.json'; sleep 0.5
  backuppc-client import -server-mode -dns 10.250.0.53 - < /etc/backuppc-client/link >/dev/null &&
  backuppc-client show | tail -1"
core tun
client "BACKUPPC_CLIENT_DNS=0 /usr/lib/backuppc-client/tun-routes up"
client "ip rule | grep -E '^7739'; nft list table inet backuppc_client | grep -E 'iifname|meta mark'"
inbound || fail "сервер: входящее подключение не получило ответ"
echo "OK: входящее подключение «из интернета» — ответ мимо туннеля"
got=$(client "curl -sS --max-time 120 http://10.250.0.1:18080/file.bin | sha256sum | cut -d' ' -f1")
[ "$got" = "$SHA" ] || fail "сервер: исходящие не через туннель"
echo "OK: исходящие по-прежнему через туннель (SHA-256 совпал)"
client "python3 /w/udpq.py" || fail "сервер: UDP напрямую не работает"
echo "OK: UDP — напрямую"

echo "==> tun-routes down"
client "/usr/lib/backuppc-client/tun-routes down"
client "! ip rule | grep -qE '^77(39|4[0-2])'" || fail "правила не сняты"
client "! nft list table inet backuppc_client >/dev/null 2>&1" || fail "nft-таблица не снята"
client "! curl -s --max-time 3 -o /dev/null http://10.250.0.1:18080/" || fail "после down таргет доступен"
echo "OK: маршруты сняты"

echo "--- сервер ---"
inet "grep -cE 'session registered' /srv/server.log | xargs echo 'сессий:'"
echo "PASS"
