/// ServerChunkConnection — Dart-side inbound HTTP/2 POST handler.
/// Используется в MeshRole.hybrid режиме для приёма входящих peer-chunks.
///
/// ВАЖНО: это STUB для v2.1-alpha. Production реализация требует
/// HTTP/2 server-side поддержки, которой нет в стандартном dart:io.
/// Options:
///   1. Использовать vendored package:http2 (third_party/http2) — имеет
///      ServerTransportConnection, но требует ручного управления ALPN + TLS
///   2. Использовать package:shelf + package:shelf_harness — но они
///      работают через HTTP/1.1 (не HTTP/2)
///   3. Platform channel (Android: OkHttp HTTP/2 server; iOS: NWListener;
///      Desktop: net.Listen из Go-side bridge)
///
/// Wire format (additive, PROTOCOL.md §11.4):
///   POST /backuppc.MeshService/InboundChunk
///   Headers: X-Backup-Session-ID, X-Backup-Auth, X-Backup-Next-Hop,
///            X-Backup-Peer-Sig, X-Backup-From-Peer
///   Body: [VLESS-request for chunk 0] + bidirectional payload frames
///
/// Privacy (PROTOCOL.md §11.9):
///   - Не раскрывает original sender (только forwarder UUID в X-Backup-From-Peer)
///   - Loop detection через X-Backup-Forwarded-By
///   - Per-session state локальный, не синхронизируется
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:backuppc_dart/backuppc_dart.dart';

import 'hop.dart';
import 'keypair.dart';
import 'vless_server.dart';

/// ServerChunkConnection — runtime state одной inbound peer-session.
class ServerChunkConnection {
  /// Session ID из X-Backup-Session-ID.
  final String sessionID;

  /// Forwarder peer UUID (X-Backup-From-Peer).
  final String fromPeer;

  /// Target address (parsed from VLESS request chunk 0).
  final String targetAddress;
  final int targetPort;

  /// Bytes received from peer (upload).
  int bytesIn = 0;

  /// Bytes sent to peer (download).
  int bytesOut = 0;

  /// Created timestamp.
  final DateTime createdAt = DateTime.now();

  /// Active target connection (dialed).
  Socket? targetConn;

  ServerChunkConnection({
    required this.sessionID,
    required this.fromPeer,
    required this.targetAddress,
    required this.targetPort,
  });

  /// Close — gracefully close target connection.
  Future<void> close() async {
    await targetConn?.close();
    targetConn = null;
  }
}

/// ServerChunkListener — STUB inbound HTTP/2 listener.
///
/// TODO Phase 3.6 production:
///   - Bind TLS ServerSocket on cfg.Listen port
///   - Negotiate ALPN 'h2' (ForceAttemptHTTP2)
///   - For each accepted connection: parse HTTP/2 frames
///   - Dispatch POST /backuppc.MeshService/InboundChunk to handler
///   - Maintain active sessions map
class ServerChunkListener {
  final MeshConfig config;
  final MeshKeypair? keypair;
  final void Function(String line)? log;

  final Map<String, ServerChunkConnection> _activeSessions = {};
  ServerSocket? _listener;
  bool _running = false;

  ServerChunkListener({
    required this.config,
    this.keypair,
    this.log,
  });

  /// Start — bind TLS listener on config.Listen.
  ///
  /// v2.1-alpha: STUB — binds plain TCP listener, logs inbound connections
  /// but doesn't process HTTP/2 (would require package:http2 server-side
  /// or platform channel bridge).
  Future<void> start() async {
    if (config.role != MeshRole.hybrid && config.role != MeshRole.server) {
      log?.call('server_chunk: skipped (role=${config.role.name})');
      return;
    }
    if (config.chain.isEmpty) {
      log?.call('server_chunk: skipped (no peers in chain)');
      return;
    }
    // Bind on first peer's addr (or self if hybrid).
    // For STUB: bind on 127.0.0.1:19443 (placeholder port).
    final listenAddr = '127.0.0.1';
    final listenPort = 19443; // STUB port
    try {
      _listener = await ServerSocket.bind(listenAddr, listenPort);
      _running = true;
      log?.call('server_chunk: STUB listener bound on $listenAddr:$listenPort '
          '(HTTP/2 protocol handling requires package:http2 — TODO Phase 3.6)');
      _listener!.listen(
        _handleInbound,
        onError: (e) => log?.call('server_chunk: listener error: $e'),
        onDone: () => log?.call('server_chunk: listener closed'),
      );
    } catch (e) {
      log?.call('server_chunk: bind failed: $e');
    }
  }

  /// _handleInbound — STUB handler for inbound TCP connection.
  ///
  /// Production implementation:
  ///   1. Upgrade to TLS with ALPN 'h2'
  ///   2. Use package:http2 ServerTransportConnection.viaStreams()
  ///   3. For each incoming HTTP/2 request:
  ///      - Check headers (sid, auth, peer-sig)
  ///      - Parse VLESS request from chunk 0
  ///      - Dial target
  ///      - Bidirectional relay (upload from peer → target, download from target → peer)
  ///      - Forwarded-By loop detection
  void _handleInbound(Socket conn) {
    log?.call('server_chunk: STUB inbound connection from ${conn.remoteAddress}');
    // For STUB: just close after small delay (don't process HTTP/2)
    conn.close();
  }

  /// Stop — graceful shutdown.
  Future<void> stop() async {
    _running = false;
    await _listener?.close();
    for (final sess in _activeSessions.values) {
      await sess.close();
    }
    _activeSessions.clear();
  }

  /// ActiveSessions — snapshot для UI (типа admin stats).
  List<ServerChunkConnection> get activeSessions =>
      _activeSessions.values.toList(growable: false);

  /// Stats — summary для admin API.
  Map<String, dynamic> get stats => {
        'running': _running,
        'activeSessions': _activeSessions.length,
        'totalBytesIn': _activeSessions.values.fold<int>(0, (s, c) => s + c.bytesIn),
        'totalBytesOut': _activeSessions.values.fold<int>(0, (s, c) => s + c.bytesOut),
      };
}

/// handleInboundChunk — production handler (NOT YET IMPLEMENTED).
///
/// Wire format (PROTOCOL.md §11.4):
///   POST /backuppc.MeshService/InboundChunk
///   Headers: X-Backup-Session-ID, X-Backup-Auth, X-Backup-Next-Hop,
///            X-Backup-Peer-Sig, X-Backup-From-Peer
///   Body: VLESS-request + bidirectional payload frames
///
/// Steps:
///   1. Verify X-Backup-Auth (HMAC-SHA256 with peer's UUID)
///   2. Verify X-Backup-Peer-Sig (Ed25519 signature from peer's pubkey)
///   3. Loop detection via X-Backup-Forwarded-By
///   4. Parse VLESS request from chunk 0 (parseVlessRequest from vless_server.dart)
///   5. Dial target (target.address:target.port)
///   6. Bidirectional relay:
///      - Upload: request body → target conn
///      - Download: target conn → response body (chunked, Flusher)
///   7. Keep stream open until either side closes (EOF or error)
///   8. On close: cleanup from active sessions map
Future<void> handleInboundChunk({
  required ServerChunkConnection session,
  required Stream<List<int>> requestBody,
  required void Function(List<int>) onResponseData,
  required void Function() onResponseEnd,
  required MeshKeypair? keypair,
  required void Function(String) log,
}) async {
  log('handleInboundChunk: STUB — production requires package:http2 server-side');
  // For STUB: just close immediately
  onResponseEnd();
}

/// VerifyPeerHeaders — verify X-Backup-Auth + X-Backup-Peer-Sig.
///
/// Returns null if valid, error message otherwise.
Future<String?> verifyPeerHeaders({
  required Map<String, String> headers,
  required String expectedPeerUUID,
  required String expectedPeerPublicKey,
  required MeshKeypair? localKeypair,
}) async {
  final sid = headers['x-backup-session-id'] ?? '';
  final auth = headers['x-backup-auth'] ?? '';
  final sig = headers['x-backup-peer-sig'] ?? '';

  if (sid.isEmpty) return 'missing X-Backup-Session-ID';
  if (auth.isEmpty) return 'missing X-Backup-Auth';

  // TODO Phase 3.7: HMAC verification using peer's UUID
  // (mirror backupemulator.BackupAuthHeader from Go side)

  if (sig.isNotEmpty && expectedPeerPublicKey.isNotEmpty) {
    // Verify Ed25519 signature
    // idx=0 (chunk 0)
    final ok = await MeshKeypair.verifyPeerSig(
      expectedPeerPublicKey,
      sid,
      0,
      sig,
    );
    if (!ok) {
      return 'invalid peer signature';
    }
  }

  return null; // valid
}

/// ParseIncomingChunk0 — extract VLESS request from first DATA frame.
///
/// Returns null if buffer is incomplete (need more bytes).
/// Throws VlessParseException on malformed.
VlessRequest? parseIncomingChunk0(Uint8List buf) {
  return parseVlessRequest(buf);
}

// Stub to avoid unused import warnings
// ignore: unused_element
Uint8List _unused() => Uint8List(0);
