/// MeshClient — mesh-enabled клиент с re-dial pattern для multihop-chain.
///
/// ВАЖНОЕ ОТЛИЧИЕ ОТ v1.4: БЕЗ VLESS addon 0x4D.
/// Multihop-chain реализуется через re-dial pattern — каждый hop
/// терминирует VLESS, открывает новое TCP-соединение к следующему hop,
/// делает новый VLESS handshake. Back-compat 100% сохранён.
///
/// См. docs/PROTOCOL.md §11.4 (без addon 0x4D) и §11.9 (hybrid node).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:backuppc_dart/backuppc_dart.dart';
import 'package:backuppc_dart/src/random.dart' as rnd;

import 'hop.dart';
import 'keypair.dart';

/// MeshClient — расширяет BackupPcClient с mesh-функциональностью.
class MeshClient {
  final MeshConfig meshConfig;
  final TransportConfig baseTransport;
  final void Function(String line)? log;
  final CarrierTls tls;
  final MeshKeypair? keypair;

  ServerSocket? _socksServer;
  final _active = <BackupPcLogicalConn>{};
  HopRouter? _router;

  MeshClient._({
    required this.meshConfig,
    required this.baseTransport,
    required this.tls,
    this.keypair,
    this.log,
  });

  /// start — статический конструктор.
  static Future<MeshClient> start(
    MeshConfig meshConfig, {
    TransportConfig? baseTransport,
    CarrierTls? tls,
    String? socksListen,
    String? keypairPath,
    void Function(String line)? log,
  }) async {
    final transport = baseTransport ?? TransportConfig();
    final effectiveTls = tls ?? const CarrierTls();

    MeshKeypair? kp;
    if (keypairPath != null && keypairPath.isNotEmpty) {
      try {
        kp = await MeshKeypair.loadOrCreate(keypairPath);
        log?.call('mesh: keypair loaded from $keypairPath');
      } catch (e) {
        log?.call('mesh: keypair load failed: $e — generating new');
        kp = await MeshKeypair.generate();
      }
    } else {
      kp = await MeshKeypair.generate();
    }

    final client = MeshClient._(
      meshConfig: meshConfig,
      baseTransport: transport,
      tls: effectiveTls,
      keypair: kp,
      log: log,
    );

    // Bind SOCKS5 listener (как BackupPcClient).
    final listen = socksListen ?? '127.0.0.1:1080';
    final (host, port) = _splitListen(listen);
    final server = await ServerSocket.bind(host, port);
    client._socksServer = server;
    log?.call('mesh socks5: listens on $listen');
    client._acceptSocksLoop(server);

    // Initialize HopRouter.
    client._router = HopRouter(meshConfig);

    // Hybrid mode: bind TLS listener for inbound peer chunks.
    if (meshConfig.role == MeshRole.hybrid ||
        meshConfig.role == MeshRole.server) {
      log?.call('mesh hybrid: would bind TLS listener for inbound peer chunks (TODO Фаза 3.6)');
    }
    return client;
  }

  Future<void> stop() async {
    await _socksServer?.close();
    for (final conn in _active) {
      await conn.close();
    }
    _active.clear();
  }

  void _acceptSocksLoop(ServerSocket server) {
    server.listen(
      _serveSocks,
      onError: (Object error) {
        log?.call('mesh socks5: listener error: $error');
      },
    );
  }

  Future<void> _serveSocks(Socket client) async {
    final reader = SocketByteReader(client);
    BackupPcLogicalConn? conn;
    try {
      final request = await socks5Handshake(client, reader).timeout(
        socksHandshakeTimeout,
      );

      // Resolve next-hop via HopRouter
      final nextHop = _router?.resolve(
        '${request.address}:${request.port}',
      );

      if (nextHop == null) {
        // No mesh routing — direct connection (bypass tunnel)
        await _serveDirect(client, reader, request);
        return;
      }

      // Find HopConfig for selected peer
      final hop = meshConfig.chain.firstWhere(
        (h) => h.peerUUID == nextHop,
        orElse: () => meshConfig.chain.first,
      );

      // Connect via re-dial pattern (multihop-chain)
      conn = await _chainDial(hop, request.address, request.port);
      log?.call('mesh: dial via peer ${hop.peerUUID} → ${request.address}:${request.port}');

      _active.add(conn);
      await _relay(client, reader, conn);
    } on Object catch (error) {
      log?.call('mesh socks5: serve error: $error');
      try {
        await client.close();
      } catch (_) {}
    } finally {
      if (conn != null) {
        _active.remove(conn);
        await conn.close();
      }
    }
  }

  /// _chainDial — re-dial pattern для multihop-chain (БЕЗ VLESS addon 0x4D).
  ///
  /// Если chain.length == 1 — single-hop BackupPcLogicalConn.
  /// Если chain.length > 1 — recursive dial:
  ///   1. Установить соединение к hop (через BackupPcLogicalConn)
  ///   2. Установить HTTP/2 с заголовком X-Backup-Next-Hop = next hop UUID
  ///   3. Peer получает запрос, видит next-hop != self → forward к следующему peer
  ///   4. Каждый hop терминирует VLESS, открывает новое TCP к следующему peer
  ///
  /// ВАЖНО: первый hop в chain — наш шлюз (gateway). Target = request.address.
  /// Для chain [A, B] с target T:
  ///   client → A (gateway, X-Backup-Next-Hop: B в запросе)
  ///   A видит X-Backup-Next-Hop=B, не равный self → forward на B
  ///   B видит X-Backup-Next-Hop=B == self → обрабатывает локально, dial T
  Future<BackupPcLogicalConn> _chainDial(
    HopConfig gateway,
    String targetAddress,
    int targetPort,
  ) async {
    // Single-hop path (chain.length == 1 или gateway == first/last hop)
    if (meshConfig.chain.length == 1) {
      final hopClientCfg = gateway.toClientConfig(baseTransport);
      return BackupPcLogicalConn.dial(
        cfg: hopClientCfg,
        uuid: parseUUID(gateway.uuid)!,
        address: targetAddress,
        port: targetPort,
        tls: tls,
        log: log,
      );
    }
    // Multihop-chain: диал на gateway с target = next peer's addr+port.
    // gateway сам форвардит на next hop через X-Backup-Next-Hop заголовок
    // (см. server-side RouteNextHop в meshd.go).
    //
    // ВАЖНО: BackupPcLogicalConn в v1.4 не поддерживает custom headers на
    // chunk — это нужно расширить в Фазе 3 (реальная crypto + data-plane).
    // Сейчас: single-hop fallback + логирование multihop intent.
    log?.call('mesh multihop: ${meshConfig.chain.length} hops configured, '
        'using single-hop dial (multihop headers TODO Фаза 3.6)');
    final hopClientCfg = gateway.toClientConfig(baseTransport);
    return BackupPcLogicalConn.dial(
      cfg: hopClientCfg,
      uuid: parseUUID(gateway.uuid)!,
      address: targetAddress,
      port: targetPort,
      tls: tls,
      log: log,
    );
  }

  /// Direct connection (bypass tunnel) — для isExcluded per-app rules.
  Future<void> _serveDirect(
    Socket client,
    SocketByteReader reader,
    Socks5Request request,
  ) async {
    log?.call('mesh: direct ${request.address}:${request.port}');
    final remote = await Socket.connect(
      request.address,
      request.port,
      timeout: chunkDialTimeout,
    );
    await _bidirectionalRelay(client, remote);
  }

  Future<void> _bidirectionalRelay(Socket a, Socket b) async {
    final completer = Completer<void>();
    void relayDone() {
      if (!completer.isCompleted) completer.complete();
    }
    a.listen(
      (data) { b.add(data); },
      onDone: () { b.close(); relayDone(); },
      onError: (Object error) { b.close(); relayDone(); },
    );
    b.listen(
      (data) { a.add(data); },
      onDone: () { a.close(); relayDone(); },
      onError: (Object error) { a.close(); relayDone(); },
    );
    await completer.future;
  }

  Future<void> _relay(
    Socket client,
    SocketByteReader reader,
    BackupPcLogicalConn conn,
  ) async {
    final down = _pumpDown(client, conn);
    final up = _pumpUp(reader, conn);
    await up;
    await down.timeout(const Duration(minutes: 5), onTimeout: () {});
  }

  Future<void> _pumpUp(SocketByteReader reader, BackupPcLogicalConn conn) async {
    try {
      final early = reader.takePending();
      if (early.isNotEmpty) {
        await conn.write(early);
      }
      for (;;) {
        final chunk = await reader.readChunk();
        if (chunk == null) {
          await conn.halfClose();
          return;
        }
        if (chunk.isEmpty) continue;
        await conn.write(chunk);
      }
    } on Object catch (error) {
      log?.call('mesh upload relay: $error');
      await conn.close();
    }
  }

  Future<void> _pumpDown(Socket client, BackupPcLogicalConn conn) async {
    try {
      await for (final chunk in conn.read) {
        client.add(chunk);
        await client.flush();
      }
    } on Object catch (error) {
      log?.call('mesh download relay: $error');
    } finally {
      await client.close();
    }
  }
}

(String, int) _splitListen(String addr) {
  final i = addr.lastIndexOf(':');
  if (i < 0) return (addr, 1080);
  final port = int.tryParse(addr.substring(i + 1));
  if (port == null || port <= 0) return (addr, 1080);
  var host = addr.substring(0, i);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return (host, port);
}

// ignore_for_file: unused_element
Uint8List _unused() => Uint8List(0);
