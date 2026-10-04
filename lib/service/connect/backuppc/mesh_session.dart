/// MeshSession — модель активной mesh-сессии в приложении.
///
/// Параллельна ConnectionRuntime (single-hop) — хранит информацию
/// о цепочке hop-ов, текущем выбранном peer, latency.
library;

import 'package:backuppc_mesh/backuppc_mesh.dart';

class MeshSession {
  final String id;
  String get identity => '${startedAt.microsecondsSinceEpoch}:$metricsPort';
  final DateTime startedAt;
  final int metricsPort;
  final MeshConfig meshConfig;
  String? activePeerUUID;
  List<HopConfig> get hops => meshConfig.chain;
  final Map<String, int> _latency = {};
  Map<String, int> get latency => Map.unmodifiable(_latency);
  final List<String> forwardedBy = [];
  int totalUp = 0;
  int totalDown = 0;
  int peerSwitchCount = 0;

  MeshSession({
    required this.id,
    required this.startedAt,
    required this.metricsPort,
    required this.meshConfig,
    this.activePeerUUID,
  });

  void updateLatency(String peerUUID, int rttMs) {
    _latency[peerUUID] = rttMs;
  }

  void addForwarder(String peerUUID) {
    if (!forwardedBy.contains(peerUUID)) forwardedBy.add(peerUUID);
  }

  void switchActivePeer(String? newPeerUUID) {
    if (activePeerUUID != newPeerUUID) {
      activePeerUUID = newPeerUUID;
      peerSwitchCount++;
    }
  }

  void addTraffic({int up = 0, int down = 0}) {
    totalUp += up;
    totalDown += down;
  }

  bool hasLoop(String peerUUID) {
    return hops.any((h) => h.peerUUID == peerUUID) ||
        forwardedBy.contains(peerUUID);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'metricsPort': metricsPort,
        'meshConfig': meshConfig.toJson(),
        'activePeerUUID': activePeerUUID,
        'forwardedBy': forwardedBy,
        'totalUp': totalUp,
        'totalDown': totalDown,
        'peerSwitchCount': peerSwitchCount,
      };
}

class MeshSessionView {
  final String identity;
  final DateTime startedAt;
  final String? activePeerUUID;
  final int hopCount;
  final int totalUp;
  final int totalDown;
  final int peerSwitchCount;
  final Map<String, int> latency;

  const MeshSessionView({
    required this.identity,
    required this.startedAt,
    required this.activePeerUUID,
    required this.hopCount,
    required this.totalUp,
    required this.totalDown,
    required this.peerSwitchCount,
    required this.latency,
  });

  factory MeshSessionView.fromSession(MeshSession session) {
    return MeshSessionView(
      identity: session.identity,
      startedAt: session.startedAt,
      activePeerUUID: session.activePeerUUID,
      hopCount: session.hops.length,
      totalUp: session.totalUp,
      totalDown: session.totalDown,
      peerSwitchCount: session.peerSwitchCount,
      latency: session.latency,
    );
  }
}

class MeshPeerView {
  final String name;
  final String peerUUID;
  final String serverAddr;
  final String? publicKey;
  final MeshRole role;
  final bool online;
  final int? latencyMs;
  final int? lastSeenMs;

  const MeshPeerView({
    required this.name,
    required this.peerUUID,
    required this.serverAddr,
    this.publicKey,
    required this.role,
    required this.online,
    this.latencyMs,
    this.lastSeenMs,
  });

  factory MeshPeerView.fromHop(HopConfig hop, {bool online = false, int? latencyMs}) {
    return MeshPeerView(
      name: hop.peerUUID.substring(0, 8),
      peerUUID: hop.peerUUID,
      serverAddr: hop.serverAddr,
      publicKey: hop.publicKey.isNotEmpty ? hop.publicKey : null,
      role: hop.role,
      online: online,
      latencyMs: latencyMs,
    );
  }
}
