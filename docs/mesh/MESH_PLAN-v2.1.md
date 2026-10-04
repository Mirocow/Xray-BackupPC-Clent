# ПЛАН v2.1 (FINAL): Decentralized Mesh с Privacy Per-Hop

**Статус:** ✅ УТВЕРЖДЁН
**Дата:** 2026-10-05
**Версия:** v2.1 (финальная)

---

## 1. АРХИТЕКТУРНЫЕ ПРИНЦИПЫ (заморожены)

### 1.1 Decentralized mesh с privacy per-hop
- Каждый узел знает **только** своих directly-configured peers
- Route tables **не распространяются** по mesh (только локальные)
- Traffic snapshots **локальные** (не покидают узел)
- При forwardе original sender **не раскрывается** — только forwarder UUID
- `X-Backup-Forwarded-By` — **только для loop detection**, не в admin UI

### 1.2 Отдельный standalone-демон `backuppc-meshd`
- Mesh-extension — **не часть** основного `backuppc-server`
- Отдельный binary, отдельный TLS-порт (например, :9443 для mesh, :8443 для backuppc)
- systemd unit / launchd / Windows Service
- IPC с основным сервером через unix socket (если нужно)

### 1.3 Additive wire (back-compat 100%)
- Новые опциональные заголовки: `X-Backup-Next-Hop`, `X-Backup-Peer-Sig`
- Новые cluster-opcodes 0x0B–0x10 (только для meshd ↔ meshd, не server-side)
- Multihop-chain через **re-dial pattern** (без VLESS addon 0x4D)
- Старые клиенты/серверы v1.3 продолжают работать без изменений

### 1.4 Идентификация — три слоя
1. **UUID** (HMAC-ключ, не меняется)
2. **Ed25519 keypair** (новое, для peer-sig)
3. **TLS pin** (SHA-256 leaf cert, не меняется)

### 1.5 Топологии — 4 (как **конфиг-подсказка** для admin)
- `full-mesh`, `star/hub`, `chain/multihop`, `auto-discovery`
- Topology switcher в admin — **подсказывает** какие peers добавить
- **Не global state** — каждый узел имеет свою топологию

### 1.6 Маршрутизация — 5 dimensions
- **CIDR LPM** (база)
- **Domain suffix** (база)
- **Per-app** (Android package, Windows exe)
- **Geo/IP** (on-demand GeoIP2, URL в admin)
- **Latency/load** (active probing)
- Приоритет: **per-app > geo > CIDR/domain > latency/load**

### 1.7 Auto-discovery с manual + auto-add опцией
- **mDNS** (LAN) + **DNS-SD** (WAN)
- **Default:** manual activation — admin должен подтвердить каждый найденный peer
- **Опционально:** `autoAdd: true` — автоматически добавлять найденные peers в registry
  - С фильтром: `discovery.autoAddFilter` (CIDR allowList, pubkey pattern, etc.)
  - Логирование каждого auto-add события
  - Auto-remove после TTL (по умолчанию 1 час, если не было трафика)

### 1.8 Admin UI — multi-node selector
- Один web UI, но работает с **выбранным узлом**
- Список зарегистрированных meshd endpoints (URL + admin token)
- Per-node pages: peers, routes, traffic, topology, geo, discovery
- **НЕТ** global mesh graph view — потому что ни один узел не знает всю топологию

### 1.9 Реверсивный узел (hybrid)
- `MeshRole.client` / `server` / `hybrid`
- В hybrid: и inbound (TLS listener для peer-chunks), и outbound (forward via X-Backup-Next-Hop)

---

## 2. ОТСЕЧЕНИЕ ОТ cluster.go v1.0 (privacy cleanup)

Из существующего `cluster.go` убрать или ограничить:

| Opcode | Статус v2.1 | Причина |
|--------|-------------|---------|
| `OpRouteTable` (0x04) | ❌ **Удалить broadcast** | Route table — локальный |
| `OpTrafficSnapshot` (0x0A) | ❌ **Удалить broadcast** | Traffic — локальный |
| `OpPeerHello` (0x09) | ⚠️ **Упростить** | Только "я peer X, pubkey Y" — без peer-list |
| `OpLeaderHeartbeat` (0x05) | ⚠️ **Оставить, опционально** | Для star topology, если нужно |
| `OpLeaderVoteReq/Vote` (0x06/0x07) | ⚠️ **Оставить опционально** | Для star, не для full-mesh |

Новые opcodes (v1.4-mesh) — все остаются:
- `OpPeerAdd/Remove/Update/RouteUpdate/CertRefresh/PeerDiscovery` (0x0B–0x10)

---

## 3. ОБНОВЛЁННЫЕ ФАЗЫ

### Фаза 1А — Рефакторинг (отдельный демон + package split)

| # | Артефакт | Оценка |
|---|----------|--------|
| 1А.1 | Server: вынести mesh-код из `internal/backupemulator/` в `internal/mesh/` (4 файла) | 4 ч |
| 1А.2 | Server: откатить патчи `cluster.go`, `server.go`, `http.go` (mesh теперь separate) | 2 ч |
| 1А.3 | Server: новый binary `cmd/backuppc-meshd/main.go` — standalone daemon | 6 ч |
| 1А.4 | Server: IPC `internal/mesh/ipc.go` — unix socket между server и meshd | 8 ч |
| 1А.5 | Server: systemd unit `deploy/backuppc-meshd.service` | 1 ч |
| 1А.6 | Client: вынести mesh-код в `packages/backuppc_mesh/` (4 файла) | 6 ч |
| 1А.7 | Client: зависимость на `cryptography` + `cryptography_flutter` | 1 ч |
| 1А.8 | Client: реальная Ed25519 sign/verify (заменить placeholder) | 4 ч |
| 1А.9 | Server: реальный Ed25519 через `crypto/ed25519` (нативный Go) | 2 ч |
| 1А.10 | Удалить VLESS addon `0x4D` (заменить на re-dial pattern) | 1 ч |
| 1А.11 | Client: реализовать re-dial pattern в `MeshClient._chainDial` | 4 ч |
| 1А.12 | Server: `cmd/backuppc-meshd/main.go` читает свой `mesh-config.json` | 2 ч |

**Итого Фаза 1А:** ~41 чел-ч (~5 раб. дней)

### Фаза 1Б — GeoIP2 + auto-discovery

| # | Артефакт | Оценка |
|---|----------|--------|
| 1Б.1 | Server: `internal/mesh/geoip.go` — on-demand download MaxMind mmdb | 4 ч |
| 1Б.2 | Server: реальный `GeoResolver` через `github.com/oschwald/maxminddb-golang` | 4 ч |
| 1Б.3 | Server: admin REST `GET/POST /api/mesh/geoip` — edit URL + refresh | 2 ч |
| 1Б.4 | Server: `internal/mesh/discovery.go` — mDNS через `github.com/hashicorp/mdns` | 6 ч |
| 1Б.5 | Server: `internal/mesh/discovery.go` — DNS-SD через `net/lookupSRV` | 4 ч |
| 1Б.6 | Server: `discovery.autoAdd` опция + autoAddFilter (CIDR, pubkey pattern) | 4 ч |
| 1Б.7 | Server: auto-remove после TTL (по умолчанию 1 час без трафика) | 2 ч |
| 1Б.8 | Client: mDNS через `package:bonsoir` (Flutter) | 4 ч |
| 1Б.9 | Client: DNS-SD через `dart:io InternetAddress.lookup` | 2 ч |
| 1Б.10 | Client: autoAdd UI toggle в peers management | 2 ч |

**Итого Фаза 1Б:** ~34 чел-ч (~4.5 раб. дня)

### Фаза 1В — Privacy cleanup (decentralized mesh)

| # | Артефакт | Оценка |
|---|----------|--------|
| 1В.1 | Убрать `OpRouteTable`/`OpTrafficSnapshot` broadcast из cluster.go | 4 ч |
| 1В.2 | Упростить `OpPeerHello` — без peer-list (только self announce) | 2 ч |
| 1В.3 | `X-Backup-Forwarded-By` — только для loop detection, не в admin UI | 2 ч |
| 1В.4 | При forward не раскрывать original sender (только forwarder UUID) | 4 ч |
| 1В.5 | Per-node config: `mesh-config-<name>.json` | 2 ч |
| 1В.6 | Admin UI: multi-node selector + per-node peer/route/traffic pages | 12 ч |
| 1В.7 | Topology switcher как конфиг-подсказка (suggest peers to add) | 4 ч |

**Итого Фаза 1В:** ~30 чел-ч (~4 раб. дня)

### Фаза 2 — UI

| # | Артефакт | Оценка |
|---|----------|--------|
| 2.1 | Flutter: `SelectionKind.mesh` + mesh picker UI | 4 ч |
| 2.2 | Flutter: peers CRUD page (with autoAdd toggle) | 7 ч |
| 2.3 | Flutter: route editor | 4 ч |
| 2.4 | Flutter: topology picker (config-suggest) | 3 ч |
| 2.5 | Flutter: WS events listener | 3 ч |
| 2.6 | Flutter: background service (flutter_background_service, NSBackgroundTask, systemd --user, Windows Service) | 8 ч |
| 2.7 | Router Vue: `MeshPeers.vue` + backend `peers.sh` | 7 ч |
| 2.8 | React admin: multi-node `Mesh.tsx` + per-node pages | 24 ч |
| 2.9 | React admin: WebSocket integration | 3 ч |

**Итого Фаза 2:** ~63 чел-ч (~8 раб. дней)

### Фаза 3 — Реальные crypto + data-plane

| # | Артефакт | Оценка |
|---|----------|--------|
| 3.1 | Server: real reverse-stream multiplex (заменить stub pipe) — bidirectional HTTP/2 streams | 12 ч |
| 3.2 | Server: shared CA для peer TLS (заменить InsecureSkipVerify) | 6 ч |
| 3.3 | Server: per-app routing через Xray JSON | 8 ч |
| 3.4 | Server: active probing loop для latency cache | 4 ч |
| 3.5 | Server: live-update transport config без рестарта | 6 ч |
| 3.6 | Client: real `ServerChunkConnection` (inbound HTTP/2 POST) | 8 ч |
| 3.7 | Client: real Ed25519 challenge-response handshake | 4 ч |
| 3.8 | Client: chain-dial (re-dial pattern для multihop) | 4 ч |
| 3.9 | IPC протокол стабилизация (server ↔ meshd) | 6 ч |

**Итого Фаза 3:** ~58 чел-ч (~7.5 раб. дней)

### Фаза 4 — Тесты и стабилизация

| # | Артефакт | Оценка |
|---|----------|--------|
| 4.1 | Dart unit: hop_test, vless_server_test, mesh_client_test | 12 ч |
| 4.2 | Dart e2e: mesh_e2e_test (2-peer chain, SHA-256 integrity) | 8 ч |
| 4.3 | Go unit: mesh_extension_test, mesh_routes_test, ipc_test | 10 ч |
| 4.4 | Go integration: mesh_daemon_test (real applySessionForward) | 12 ч |
| 4.5 | Go integration: mesh_e2e_test (2-server mesh, privacy verification) | 10 ч |
| 4.6 | Flutter widget: mesh_picker_test, peers_page_test | 6 ч |
| 4.7 | Compile-check + fix errors | 12 ч |

**Итого Фаза 4:** ~70 чел-ч (~9 раб. дней)

### Фаза 5 — Документация

| # | Артефакт | Оценка |
|---|----------|--------|
| 5.1 | `docs/mesh-user-guide.md` (RU + EN) | 4 ч |
| 5.2 | `docs/mesh-deployment.md` (systemd/launchd/Service) | 4 ч |
| 5.3 | `docs/mesh-migration.md` v1.3 → v1.4-mesh | 2 ч |
| 5.4 | `docs/mesh-privacy.md` — decentralized topology, per-hop anonymity | 3 ч |

**Итого Фаза 5:** ~13 чел-ч (~1.5 раб. дня)

---

## 4. ИТОГОВАЯ ОЦЕНКА

| Фаза | Чел-ч | Раб. дней |
|------|-------|-----------|
| Фаза 1А: Рефакторинг (отдельный демон, package split, без addon 0x4D) | 41 | 5 |
| Фаза 1Б: GeoIP2 + auto-discovery (manual + autoAdd) | 34 | 4.5 |
| Фаза 1В: Privacy cleanup (decentralized, multi-node admin UI) | 30 | 4 |
| Фаза 2: UI (Flutter + Vue + React multi-node) | 63 | 8 |
| Фаза 3: Реальные crypto + data-plane | 58 | 7.5 |
| Фаза 4: Тесты и стабилизация | 70 | 9 |
| Фаза 5: Документация | 13 | 1.5 |
| **ИТОГО v2.1:** | **309** | **~39 раб. дней** |

---

## 5. ЧТО БУДЕТ СДЕЛАНО В ЭТОЙ СЕССИИ

Учитывая ~39 раб. дней работы, в одной сессии делаю **скелет Фазы 1А**:

| # | Артефакт | Что именно |
|---|----------|------------|
| S.1 | Создать ветки `feat/mesh-extension-v2.1` в обоих репо | Отдельные от v1.4 |
| S.2 | Server: создать `internal/mesh/` package | Перенести mesh_extension.go + mesh_routes.go + mesh_server_helpers.go |
| S.3 | Server: откатить патчи cluster.go/server.go/http.go | Mesh больше не в основном процессе |
| S.4 | Server: создать `cmd/backuppc-meshd/main.go` standalone binary | Читает mesh-config.json, биндит TLS, проксирует на peer |
| S.5 | Server: упростить cluster.go (privacy: убрать RouteTable/TrafficSnapshot broadcast) | Decentralized mesh |
| S.6 | Client: создать `packages/backuppc_mesh/` package | Перенести hop.dart + vless_server.dart + mesh_client.dart |
| S.7 | Client: удалить VLESS addon 0x4D | Заменить на re-dial pattern |
| S.8 | Client: `pubspec.yaml` — зависимость на `cryptography` | Ed25519 через FlutterFire |
| S.9 | Client: реальная Ed25519 sign/verify | Заменить placeholder |
| S.10 | Push PLAN-v2.1.md в оба репо | В `docs/mesh/MESH_PLAN-v2.1.md` |
| S.11 | Push ветки в origin | feat/mesh-extension-v2.1 |

Фазы 1Б, 1В, 2, 3, 4, 5 — переносятся на следующие сессии.

---

## 6. ПОСЛЕДУЮЩИЕ СЕССИИ (предстоящая работа)

| Сессия | Что делаем |
|--------|------------|
| Сессия 2 | Фаза 1Б (GeoIP2 + auto-discovery mDNS/DNS-SD + autoAdd опция) |
| Сессия 3 | Фаза 1В (Privacy cleanup, multi-node admin UI) |
| Сессия 4-5 | Фаза 2 (Flutter UI + Vue router + React multi-node admin) |
| Сессия 6-7 | Фаза 3 (real crypto, reverse-stream mux, IPC стабилизация) |
| Сессия 8-9 | Фаза 4 (тесты: Dart unit, Go cluster, e2e 2-server mesh) |
| Сессия 10 | Фаза 5 (документация) |
| Сессия 11 | Tag release `v1.4.0-mesh-alpha` |
