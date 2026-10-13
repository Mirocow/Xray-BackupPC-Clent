# `backuppc_mesh` — Mesh Extension для `backuppc_dart` (v1.4-mesh)

Децентрализованная mesh-сеть с **privacy per-hop**: каждый узел знает
только своих directly-configured peers.

## Установка

```yaml
# pubspec.yaml
dependencies:
  backuppc_mesh:
    path: packages/backuppc_mesh
```

## Использование

### Single-hop (как обычный BackupPcClient)

```dart
import 'package:backuppc_mesh/backuppc_mesh.dart';

final client = await MeshClient.start(
  MeshConfig(
    chain: [HopConfig(
      peerUUID: '8d1f6c5a-3b7e-4d2a-9c1f-5e6d7a8b9c0d',
      serverAddr: 's1.corp:9443',
      uuid: '52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90',
      certFingerprint: 'sha256-hex',
    )],
    topology: MeshTopology.fullMesh,
    role: MeshRole.client,
  ),
  socksListen: '127.0.0.1:1080',
  keypairPath: '~/.config/onexray/mesh-key.pem',
  log: (line) => print('[mesh] $line'),
);
```

### Multihop-chain (re-dial pattern)

```dart
final client = await MeshClient.start(
  MeshConfig(
    chain: [
      HopConfig(peerUUID: 'peer-a-uuid', serverAddr: 'a.corp:9443', uuid: '...'),
      HopConfig(peerUUID: 'peer-b-uuid', serverAddr: 'b.corp:9443', uuid: '...'),
      HopConfig(peerUUID: 'peer-c-uuid', serverAddr: 'c.corp:9443', uuid: '...'),
    ],
    topology: MeshTopology.chain,
  ),
  // ...
);
```

Multihop реализуется через re-dial pattern (без VLESS addon 0x4D):
- Client → peer A (с X-Backup-Next-Hop: B в заголовке)
- A видит next-hop ≠ self → forward на B (через meshd)
- B видит next-hop = self → обрабатывает локально, dial target

### Per-app + geo routing

```dart
final client = await MeshClient.start(
  MeshConfig(
    chain: [...],
    perAppRules: [
      PerAppRule(appPackage: 'com.example.app', peerUUID: 'peer-ru-uuid'),
      PerAppRule(appPackage: 'com.other.app', isExcluded: true), // bypass mesh
    ],
    geoRules: [
      GeoRule(countryCode: 'RU', peerUUID: 'peer-ru-uuid'),
    ],
    loadBasedRouting: true,
  ),
  // ...
);
```

Приоритет: per-app > geo > CIDR/domain > latency/load.

## Privacy-по-дизайну

1. **Каждый узел знает только своих peers** (peer registry — локальный, не broadcast)
2. **Route tables — локальные**, не распространяются по mesh
3. **Traffic snapshots — локальные**, не покидают узел
4. **При forward original sender не раскрывается** — только forwarder UUID в X-Backup-Forwarded-By (для loop detection)
5. **Auto-discovery** находит peers через mDNS/DNS-SD, но активация — manual (или autoAdd с фильтром)

## Архитектура

| Файл | Назначение |
|------|------------|
| `lib/src/hop.dart` | HopConfig, MeshConfig, HopRouter (5 routing dimensions), MeshPath |
| `lib/src/vless_server.dart` | parseVlessRequest, buildVlessResponse (БЕЗ mesh-routing addon 0x4D) |
| `lib/src/mesh_client.dart` | MeshClient extends BackupPcClient с re-dial pattern |
| `lib/src/keypair.dart` | MeshKeypair — реальная Ed25519 через `package:cryptography` |

## Что не реализовано (TODO Фазы 2/3)

| Что | Фаза |
|-----|------|
| Flutter UI: mesh picker, peers management | Фаза 2 |
| Background service (flutter_background_service, NSBackgroundTask, systemd --user, Windows Service) | Фаза 2 |
| mDNS/DNS-SD discovery (через `package:bonsoir`) | Фаза 1Б |
| Real multihop headers на BackupPcLogicalConn (custom headers per chunk) | Фаза 3.6 |
| `ServerChunkConnection` (inbound HTTP/2 POST, для hybrid mode) | Фаза 3.6 |
| Ed25519 challenge-response handshake (на transport-layer) | Фаза 3.7 |
| Tests (mesh_unit_test, mesh_e2e_test) | Фаза 4 |

См. `docs/mesh/MESH_PLAN-v2.1.md` для полной разбивки фаз.
