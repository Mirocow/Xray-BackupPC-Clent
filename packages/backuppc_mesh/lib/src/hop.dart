/// HopConfig, MeshConfig, HopRouter, MeshPath — mesh routing primitives.
///
/// См. docs/PROTOCOL.md §11 и docs/mesh/MESH_PLAN-v2.1.md.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:backuppc_dart/backuppc_dart.dart';
import 'package:backuppc_dart/src/random.dart' as rnd;

/// Один hop mesh-цепочки.
class HopConfig {
  final String peerUUID;
  final String serverAddr;
  final String uuid;
  final String certFingerprint;
  final bool insecure;
  final String host;
  final String publicKey;
  final MeshRole role;
  final TransportConfig? transport;

  const HopConfig({
    required this.peerUUID,
    required this.serverAddr,
    required this.uuid,
    this.certFingerprint = '',
    this.insecure = false,
    this.host = '',
    this.publicKey = '',
    this.role = MeshRole.client,
    this.transport,
  });

  ClientConfig toClientConfig(TransportConfig defaultTransport) {
    return ClientConfig(
      transport: transport ?? defaultTransport,
      serverAddr: serverAddr,
      uuid: uuid,
      insecure: insecure,
      certFingerprint: certFingerprint,
    );
  }

  Map<String, dynamic> toJson() => {
        'peerUUID': peerUUID,
        'serverAddr': serverAddr,
        'uuid': uuid,
        if (certFingerprint.isNotEmpty) 'certFingerprint': certFingerprint,
        if (insecure) 'insecure': true,
        if (host.isNotEmpty) 'host': host,
        if (publicKey.isNotEmpty) 'publicKey': publicKey,
        'role': role.name,
        if (transport != null) 'transport': transport!.toJson(),
      };

  factory HopConfig.fromJson(Map<String, dynamic> json) {
    return HopConfig(
      peerUUID: json['peerUUID'] as String? ?? '',
      serverAddr: json['serverAddr'] as String? ?? '',
      uuid: json['uuid'] as String? ?? '',
      certFingerprint:
          (json['certFingerprint'] as String? ?? '').toLowerCase(),
      insecure: json['insecure'] as bool? ?? false,
      host: json['host'] as String? ?? '',
      publicKey: json['publicKey'] as String? ?? '',
      role: MeshRole.values.firstWhere(
        (r) => r.name == (json['role'] as String? ?? 'client'),
        orElse: () => MeshRole.client,
      ),
      transport: json['transport'] is Map<String, dynamic>
          ? TransportConfig.fromJson(
              json['transport'] as Map<String, dynamic>)
          : null,
    );
  }

  (String, int) splitServerAddr() {
    final i = serverAddr.lastIndexOf(':');
    if (i < 0) return (serverAddr, 443);
    final port = int.tryParse(serverAddr.substring(i + 1));
    if (port == null || port <= 0) return (serverAddr, 443);
    var h = serverAddr.substring(0, i);
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    return (h, port);
  }
}

enum MeshRole { client, server, hybrid }

enum MeshTopology { fullMesh, star, chain, autoDiscovery }

class MeshConfig {
  final List<HopConfig> chain;
  final MeshTopology topology;
  final MeshRole role;
  final String privateKeyPEM;
  final List<PerAppRule> perAppRules;
  final List<GeoRule> geoRules;
  final bool loadBasedRouting;
  final List<String> bootstrapPeers;
  final List<String> discoveryAllowList;
  final bool discoveryAutoAdd;

  const MeshConfig({
    this.chain = const [],
    this.topology = MeshTopology.fullMesh,
    this.role = MeshRole.client,
    this.privateKeyPEM = '',
    this.perAppRules = const [],
    this.geoRules = const [],
    this.loadBasedRouting = false,
    this.bootstrapPeers = const [],
    this.discoveryAllowList = const [],
    this.discoveryAutoAdd = false,
  });

  factory MeshConfig.fromJson(Map<String, dynamic> json) {
    final chainJson = json['chain'] as List? ?? [];
    return MeshConfig(
      chain: chainJson
          .map((e) => HopConfig.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      topology: MeshTopology.values.firstWhere(
        (t) => t.name == (json['topology'] as String? ?? 'fullMesh'),
        orElse: () => MeshTopology.fullMesh,
      ),
      role: MeshRole.values.firstWhere(
        (r) => r.name == (json['role'] as String? ?? 'client'),
        orElse: () => MeshRole.client,
      ),
      privateKeyPEM: json['privateKeyPEM'] as String? ?? '',
      perAppRules: (json['perAppRules'] as List? ?? [])
          .map((e) => PerAppRule.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      geoRules: (json['geoRules'] as List? ?? [])
          .map((e) => GeoRule.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      loadBasedRouting: json['loadBasedRouting'] as bool? ?? false,
      bootstrapPeers: (json['bootstrapPeers'] as List? ?? [])
          .map((e) => e.toString())
          .toList(growable: false),
      discoveryAllowList: (json['discoveryAllowList'] as List? ?? [])
          .map((e) => e.toString())
          .toList(growable: false),
      discoveryAutoAdd: json['discoveryAutoAdd'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'chain': chain.map((h) => h.toJson()).toList(),
        'topology': topology.name,
        'role': role.name,
        if (privateKeyPEM.isNotEmpty) 'privateKeyPEM': privateKeyPEM,
        'perAppRules': perAppRules.map((r) => r.toJson()).toList(),
        'geoRules': geoRules.map((r) => r.toJson()).toList(),
        'loadBasedRouting': loadBasedRouting,
        'bootstrapPeers': bootstrapPeers,
        'discoveryAllowList': discoveryAllowList,
        'discoveryAutoAdd': discoveryAutoAdd,
      };

  bool get isMesh => chain.isNotEmpty;
}

class PerAppRule {
  final String appPackage;
  final String peerUUID;
  final bool isExcluded;

  const PerAppRule({
    required this.appPackage,
    required this.peerUUID,
    this.isExcluded = false,
  });

  Map<String, dynamic> toJson() => {
        'appPackage': appPackage,
        'peerUUID': peerUUID,
        'isExcluded': isExcluded,
      };

  factory PerAppRule.fromJson(Map<String, dynamic> json) {
    return PerAppRule(
      appPackage: json['appPackage'] as String? ?? '',
      peerUUID: json['peerUUID'] as String? ?? '',
      isExcluded: json['isExcluded'] as bool? ?? false,
    );
  }
}

class GeoRule {
  final String geosite;
  final String countryCode;
  final String peerUUID;

  const GeoRule({
    this.geosite = '',
    required this.countryCode,
    required this.peerUUID,
  });

  Map<String, dynamic> toJson() => {
        'geosite': geosite,
        'countryCode': countryCode,
        'peerUUID': peerUUID,
      };

  factory GeoRule.fromJson(Map<String, dynamic> json) {
    return GeoRule(
      geosite: json['geosite'] as String? ?? '',
      countryCode: json['countryCode'] as String? ?? '',
      peerUUID: json['peerUUID'] as String? ?? '',
    );
  }
}

/// HopRouter — выбирает next-hop для конкретного target.
///
/// Приоритет (PROTOCOL.md §11.6):
///   1. Per-app rule
///   2. Geo rule
///   3. CIDR LPM / Domain suffix (локальная route table)
///   4. Latency/load-based (если включена)
///
/// ВАЖНО: route table — ЛОКАЛЬНАЯ, не распространяется (privacy per-hop).
class HopRouter {
  final MeshConfig config;
  final Map<String, String> routeTable;
  final Map<String, int> _latencyCache = {};
  final Map<String, int> _latencyCacheTs = {};

  HopRouter(this.config, {Map<String, String>? routeTable})
      : routeTable = routeTable ?? {};

  String? resolve(String target, {String? appPackage}) {
    // 1. Per-app rule
    if (appPackage != null && appPackage.isNotEmpty) {
      for (final rule in config.perAppRules) {
        if (rule.appPackage == appPackage) {
          return rule.isExcluded ? null : rule.peerUUID;
        }
      }
    }
    // 2. Geo rule
    final host = _extractHost(target);
    for (final rule in config.geoRules) {
      if (rule.countryCode.isNotEmpty) {
        if (host.endsWith('.${rule.countryCode.toLowerCase()}')) {
          return rule.peerUUID;
        }
      }
      if (rule.geosite.isNotEmpty) {
        final cc = rule.geosite.split(':').last.toLowerCase();
        if (host.endsWith('.$cc')) {
          return rule.peerUUID;
        }
      }
    }
    // 3. CIDR LPM / Domain suffix
    if (routeTable.isNotEmpty) {
      String? bestMatch;
      int bestLen = 0;
      routeTable.forEach((prefix, peerUUID) {
        final (matched, len) = _matchPrefix(host, prefix);
        if (matched && len > bestLen) {
          bestLen = len;
          bestMatch = peerUUID;
        }
      });
      if (bestMatch != null) return bestMatch;
    }
    // 4. Latency/load-based
    if (config.loadBasedRouting && config.chain.isNotEmpty) {
      return _selectByLoad();
    }
    // Single-hop fallback: первый hop в chain
    if (config.chain.isNotEmpty) {
      return config.chain.first.peerUUID;
    }
    return null;
  }

  String? _selectByLoad() {
    String? best;
    int bestRtt = 0x7FFFFFFF;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final hop in config.chain) {
      final ts = _latencyCacheTs[hop.peerUUID] ?? 0;
      if (now - ts > 30000) continue;
      final rtt = _latencyCache[hop.peerUUID] ?? 0x7FFFFFFF;
      if (rtt < bestRtt) {
        bestRtt = rtt;
        best = hop.peerUUID;
      }
    }
    return best;
  }

  void addLatencySample(String peerUUID, int rttMs) {
    _latencyCache[peerUUID] = rttMs;
    _latencyCacheTs[peerUUID] = DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, int> get allLatency => Map.unmodifiable(_latencyCache);

  String _extractHost(String target) {
    if (target.contains(':')) {
      final i = target.lastIndexOf(':');
      var h = target.substring(0, i);
      if (h.startsWith('[') && h.endsWith(']')) {
        h = h.substring(1, h.length - 1);
      }
      return h;
    }
    return target;
  }

  (bool, int) _matchPrefix(String target, String prefix) {
    if (prefix.startsWith('.')) {
      if (target.endsWith(prefix)) return (true, prefix.length);
      return (false, 0);
    }
    if (prefix.contains('/')) {
      try {
        final ip = InternetAddress(target);
        final cidrParts = prefix.split('/');
        if (cidrParts.length == 2) {
          final cidrIP = InternetAddress(cidrParts[0]);
          final mask = int.tryParse(cidrParts[1]) ?? 0;
          if (ip.type == cidrIP.type) {
            return (true, mask);
          }
        }
      } on Exception {
        // not an IP — skip CIDR match
      }
      return (false, 0);
    }
    if (target.startsWith(prefix)) return (true, prefix.length);
    return (false, 0);
  }
}

/// MeshPath — инкапсулирует проложенный путь в mesh-сети.
class MeshPath {
  final List<HopConfig> hops;
  final String target;
  final int port;
  final String streamGroupID;
  final List<String> forwardedBy = [];

  MeshPath({
    required this.hops,
    required this.target,
    required this.port,
    String? streamGroupID,
  }) : streamGroupID = streamGroupID ?? _generateStreamGroupID();

  String? get nextHopUUID =>
      hops.isNotEmpty ? hops.first.peerUUID : null;

  void addForwarder(String peerUUID) {
    if (!forwardedBy.contains(peerUUID)) {
      forwardedBy.add(peerUUID);
    }
  }

  bool hasLoop(String peerUUID) {
    return hops.any((h) => h.peerUUID == peerUUID) ||
        forwardedBy.contains(peerUUID);
  }

  static String _generateStreamGroupID() {
    return 'mesh-${rnd.randHex(8)}';
  }
}
