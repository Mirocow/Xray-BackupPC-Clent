/// Клиент туннеля: SOCKS5-фронтенд + фабрика логических соединений
/// (Dart-порт `Client` из `backuppc.go`/`client.go`).
///
/// ```dart
/// final client = await BackupPcClient.start(config);
/// // SOCKS5 слушает 127.0.0.1:1080, весь TCP-трафик уходит через
/// // VLESS поверх gRPC-канала с маскировкой под бекапы BackupPC.
/// await client.stop();
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'carrier.dart';
import 'config.dart';
import 'socks5.dart';
import 'tunnel.dart';

/// Сводные метрики клиента (агрегат закрытых и активных сессий).
class ClientMetrics {
  int sessions = 0;
  int activeSessions = 0;
  int chunks = 0;
  int rotations = 0;
  int txPayload = 0;
  int rxPayload = 0;
  int txFake = 0;
  int fakeJobs = 0;
  int fakeJobBytes = 0;
  ClientMetrics();
}

/// Прямой диал логического соединения без SOCKS (для пинга/тестов):
/// устанавливает сессию до [address]:[port] через транспорт.
/// TLS-настройки по умолчанию берутся из [cfg] (пиннинг/insecure).
Future<BackupPcLogicalConn> dialLogical(
  ClientConfig cfg, {
  required String address,
  required int port,
  CarrierTls? tls,
  void Function(String line)? log,
}) async {
  final uuid = parseUUID(cfg.uuid);
  if (uuid == null) {
    throw const FormatException('client: некорректный uuid');
  }
  return BackupPcLogicalConn.dial(
    cfg: cfg,
    uuid: uuid,
    address: address,
    port: port,
    tls: tls ?? CarrierTls.fromConfig(cfg),
    log: log,
  );
}

/// Полноценный клиент: слушает SOCKS5 и обслуживает соединения.
class BackupPcClient {
  final ClientConfig cfg;
  final CarrierTls tls;
  final void Function(String line)? log;
  final Uint8List uuid;

  ServerSocket? _server;
  final _active = <BackupPcLogicalConn>{};
  final _totals = ClientMetrics();
  bool _stopping = false;

  BackupPcClient._(this.cfg, CarrierTls? tls, this.log)
    : tls = tls ?? CarrierTls.fromConfig(cfg),
      uuid = parseUUID(cfg.uuid)!;

  /// Запуск: биндит SOCKS5 на `cfg.socksListen` (127.0.0.1:1080).
  static Future<BackupPcClient> start(
    ClientConfig cfg, {
    CarrierTls? tls,
    void Function(String line)? log,
  }) async {
    final err = cfg.validate();
    if (err != null) {
      throw FormatException(err);
    }
    final uuid = parseUUID(cfg.uuid);
    if (uuid == null) {
      throw const FormatException('client: некорректный uuid');
    }
    final (host, port) = _splitListen(cfg.socksListen);
    final server = await ServerSocket.bind(host, port);
    final client = BackupPcClient._(cfg, tls, log)
      .._server = server
      .._stopping = false;
    log?.call('socks5: слушает ${cfg.socksListen}');
    client._acceptLoop(server);
    return client;
  }

  static (String, int) _splitListen(String listen) {
    final i = listen.lastIndexOf(':');
    if (i < 0) return (listen, 1080);
    final port = int.tryParse(listen.substring(i + 1));
    var host = listen.substring(0, i);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    return (host.isEmpty ? '127.0.0.1' : host, port ?? 1080);
  }

  void _acceptLoop(ServerSocket server) {
    server.listen(
      _serve,
      onError: (Object error) {
        log?.call('socks5: ошибка слушателя: $error');
      },
    );
  }

  Future<void> _serve(Socket client) async {
    final reader = SocketByteReader(client);
    BackupPcLogicalConn? conn;
    try {
      final request = await socks5Handshake(client, reader).timeout(
        socksHandshakeTimeout,
      );
      conn = await BackupPcLogicalConn.dial(
        cfg: cfg,
        uuid: uuid,
        address: request.address,
        port: request.port,
        tls: tls,
        log: log,
      );
      _active.add(conn);
      _totals.sessions += 1;
      await _relay(client, reader, conn);
    } on Exception catch (error) {
      log?.call('socks5: сессия отклонена: $error');
      // сообщение об ошибке рукопожатия уже отослано, если было возможно
    } finally {
      await conn?.close();
      _active.remove(conn);
      if (conn != null) {
        _absorb(conn.metrics);
      }
      await reader.cancel();
      client.destroy();
    }
  }

  void _absorb(SessionMetrics m) {
    _totals.chunks += m.chunks;
    _totals.rotations += m.rotations;
    _totals.txPayload += m.txPayload;
    _totals.rxPayload += m.rxPayload;
    _totals.txFake += m.txFake;
    _totals.fakeJobs += m.fakeJobs;
    _totals.fakeJobBytes += m.fakeJobBytes;
  }

  /// Двунаправленный релей: upload → туннель (с HalfClose по EOF клиента),
  /// туннель → download. Backpressure — через последовательные await
  /// (StreamIterator не подтягивает события вперед).
  Future<void> _relay(
    Socket client,
    SocketByteReader reader,
    BackupPcLogicalConn conn,
  ) async {
    final down = _pumpDown(client, conn);
    final up = _pumpUp(reader, conn);
    await up;
    // upload завершен; дождаться выкачивания остатков
    await down.timeout(
      const Duration(minutes: 5),
      onTimeout: () {},
    );
  }

  Future<void> _pumpUp(
    SocketByteReader reader,
    BackupPcLogicalConn conn,
  ) async {
    try {
      final early = reader.takePending();
      if (early.isNotEmpty) {
        await conn.write(early);
      }
      for (;;) {
        final chunk = await reader.readChunk();
        if (chunk == null) {
          await conn.halfClose(); // клиент закончил — EOF-кадр + END_STREAM
          return;
        }
        if (chunk.isEmpty) continue;
        await conn.write(chunk);
      }
    } on Object catch (error) {
      // туннель/сокет умер (включая StateError закрытого стрима) —
      // download-плечо закроет соединение
      log?.call('upload relay: $error');
      await conn.close();
    }
  }

  Future<void> _pumpDown(Socket client, BackupPcLogicalConn conn) async {
    try {
      for (;;) {
        final buf = Uint8List(64 * 1024);
        final n = await conn.read(buf);
        if (n <= 0) break;
        client.add(n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
      }
    } on Object catch (error) {
      // транспорт прерван
      log?.call('download relay: $error');
    } finally {
      // graceful: сторона сервера закрыла поток — FIN клиенту
      // (Socket.close() закрывает записывающую сторону с дозаписью)
      unawaited(client.close().catchError((_) {}));
    }
  }

  ClientMetrics metrics() {
    final snapshot = ClientMetrics()
      ..sessions = _totals.sessions
      ..activeSessions = _active.length
      ..chunks = _totals.chunks
      ..rotations = _totals.rotations
      ..txPayload = _totals.txPayload
      ..rxPayload = _totals.rxPayload
      ..txFake = _totals.txFake
      ..fakeJobs = _totals.fakeJobs
      ..fakeJobBytes = _totals.fakeJobBytes;
    for (final conn in _active) {
      final m = conn.metrics;
      snapshot.chunks += m.chunks;
      snapshot.rotations += m.rotations;
      snapshot.txPayload += m.txPayload;
      snapshot.rxPayload += m.rxPayload;
      snapshot.txFake += m.txFake;
      snapshot.fakeJobs += m.fakeJobs;
      snapshot.fakeJobBytes += m.fakeJobBytes;
    }
    return snapshot;
  }

  int get activeSessions => _active.length;

  /// Активные логические соединения (диагностика).
  List<BackupPcLogicalConn> get activeConns => _active.toList();

  Future<void> stop() async {
    _stopping = true;
    final server = _server;
    _server = null;
    await server?.close();
    final closing = [for (final conn in _active.toList()) conn.close()];
    await Future.wait(closing).catchError((_) => <void>[]);
    log?.call('socks5: остановлен');
  }

  bool get running => _server != null && !_stopping;
}
