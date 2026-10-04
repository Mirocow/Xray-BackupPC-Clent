/// backuppc_mesh — Mesh extension для backuppc_dart (v1.4-mesh).
///
/// Децентрализованная mesh-сеть поверх существующего backuppc-клиента.
/// Каждый узел знает только своих directly-configured peers
/// (privacy per-hop, см. docs/PROTOCOL.md §11.9).
///
/// Архитектурные принципы v2.1:
///   - Отдельный package (backuppc_dart остаётся zero-deps)
///   - Additive wire (старые клиенты/серверы v1.3 продолжают работать)
///   - Per-node Ed25519 keypair через package:cryptography (FlutterFire)
///   - Multihop-chain через re-dial pattern (без VLESS addon 0x4D)
///   - 5 routing dimensions: per-app > geo > CIDR/domain > latency/load
///   - 4 topologies (конфиг-подсказка для admin UI, не global state)
///   - Auto-discovery (mDNS/DNS-SD) с manual + autoAdd опцией
///   - Routing hop-by-hop: при forward original sender не раскрывается
///   - Route tables / traffic snapshots — локальные, не broadcast
///
/// См. docs/PROTOCOL.md §11 и docs/mesh/MESH_PLAN-v2.1.md.
library;

export 'src/hop.dart'
    show
        HopConfig,
        MeshConfig,
        MeshRole,
        MeshTopology,
        PerAppRule,
        GeoRule,
        HopRouter,
        MeshPath;
export 'src/vless_server.dart'
    show
        parseVlessRequest,
        buildVlessResponse,
        VlessRequest,
        VlessParseException;
export 'src/mesh_client.dart' show MeshClient;
export 'src/keypair.dart' show MeshKeypair;
// Фаза 1Б: auto-discovery (mDNS + DNS-SD + autoAdd + autoRemove)
export 'src/discovery.dart'
    show
        DiscoveryManager,
        DiscoveryConfig,
        DiscoveredPeer,
        PeerConfig;
