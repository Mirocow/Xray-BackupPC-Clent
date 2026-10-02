// Wire-совместимый фальшивый сервер backuppc для e2e-тестов Dart-клиента.
//
// Говорит тем же контрактом, что Go-сервер xray-backuppc: TLS+ALPN h2,
// POST c application/grpc, метаданные X-Backup-*, кадры ТЗ в gRPC-сообщениях,
// VLESS в первом payload чанка 0, ответы «хранилища» на пробы (404/405/413).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http2/transport.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

final RegExp _sessionRe = RegExp(
  r'^[a-z0-9][a-z0-9-]{2,31}\.[0-9]{1,6}\.[0-9a-f]{8}$',
);

class FakeServerRecord {
  final String sessionID;
  final int chunkIndex;
  const FakeServerRecord(this.sessionID, this.chunkIndex);
}

class _FakeSession {
  final String sid;
  int lastIndex = -1;
  ServerTransportStream? current;
  bool uploadEnded = false;
  String target = '';
  bool vlessDone = false;
  bool sentResponse = false; // VLESS-ответ отправляется ОДИН раз на сессию
  _FakeSession(this.sid);
}

/// Режим ответа сервера: эхо входящих данных и/или собственная выдача.
class FakeServerMode {
  final bool echo;
  final int pushBytes;
  const FakeServerMode({this.echo = true, this.pushBytes = 0});
}

class FakeBackupPcServer {
  final Uint8List uuid;
  final List<String> endpointPaths;
  final FakeServerMode mode;
  final List<FakeServerRecord> records = [];
  final List<String> violations = [];
  final Map<String, String> targets = {};

  final _sessions = <String, _FakeSession>{};
  SecureServerSocket? _server;
  int _pushSeq = 0;

  FakeBackupPcServer({
    required this.uuid,
    List<String>? endpointPaths,
    this.mode = const FakeServerMode(),
  }) : endpointPaths = endpointPaths ?? TransportConfig.defaultEndpointPaths;

  Future<int> start() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/server.crt')
      ..usePrivateKey('test/fixtures/server.key');
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      supportedProtocols: const ['h2'],
    );
    _server = server;
    server.listen(
      _onConnection,
      onError: (Object e) => violations.add('listener: $e'),
    );
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  void _onConnection(SecureSocket socket) {
    final connection = ServerTransportConnection.viaSocket(socket);
    unawaited(
      connection.incomingStreams.forEach((stream) => _onStream(stream)),
    );
  }

  void _onStream(ServerTransportStream stream) {
    var gotHeaders = false;
    final feeder = ByteFeeder();
    stream.incomingMessages.listen(
      (msg) {
        if (msg is HeadersStreamMessage) {
          if (!gotHeaders) {
            gotHeaders = true;
            unawaited(_handleRequest(stream, msg.headers, feeder));
          }
        } else if (msg is DataStreamMessage) {
          feeder.add(msg.bytes);
        }
      },
      onError: (Object e) {
        feeder.close(e);
      },
      onDone: () {
        feeder.close();
      },
    );
  }

  static String _header(List<Header> headers, String name) {
    for (final h in headers) {
      if (String.fromCharCodes(h.name) == name) {
        return String.fromCharCodes(h.value);
      }
    }
    return '';
  }

  Future<void> _handleRequest(
    ServerTransportStream stream,
    List<Header> headers,
    ByteFeeder feeder,
  ) async {
    final method = _header(headers, ':method');
    final path = _header(headers, ':path');
    if (method != 'POST') {
      _replyError(stream, 405);
      return;
    }
    if (!endpointPaths.contains(path)) {
      _replyError(stream, 404);
      return;
    }
    final ct = _header(headers, 'content-type');
    if (!ct.startsWith('application/grpc')) {
      _replyError(stream, 413);
      return;
    }
    final sid = _header(headers, 'x-backup-session-id');
    final idxRaw = _header(headers, 'x-backup-chunk-index');
    final auth = _header(headers, 'x-backup-auth');
    if (!_sessionRe.hasMatch(sid)) {
      violations.add('bad session id: $sid');
      _replyError(stream, 400);
      return;
    }
    final idx = int.tryParse(idxRaw);
    if (idx == null || !_hmacOk(sid, idx, auth)) {
      violations.add('bad auth: sid=$sid idx=$idxRaw');
      _replyError(stream, 400);
      return;
    }
    var session = _sessions[sid];
    if (session == null) {
      if (idx != 0) {
        violations.add('chunk 0 expected, got $idx');
        _replyError(stream, 400);
        return;
      }
      session = _FakeSession(sid);
      _sessions[sid] = session;
    } else if (idx != session.lastIndex + 1) {
      violations.add('chunk sequence: got $idx after ${session.lastIndex}');
      _replyError(stream, 400);
      return;
    }
    session.lastIndex = idx;
    final sess = session;
    final previous = sess.current;
    sess.current = stream;
    records.add(FakeServerRecord(sid, idx));

    // 200 + content-type немедленно (как WriteHeader(200)+Flush в Go)
    stream.sendHeaders([
      Header.ascii(':status', '200'),
      Header.ascii('content-type', 'application/grpc'),
      Header.ascii('x-backup-storage', 'backup-pool-01'),
    ]);
    if (previous != null && previous != stream) {
      // ротация: ответ продолжится в новом чанке, старый END_STREAM-ится
      // (эстафета: клиентский читатель перейдет по цепочке)
      unawaited(previous.outgoingMessages.close().catchError((_) {}));
    }
    unawaited(
      _pumpUpload(stream, sess, feeder).then((_) {
        if (sess.uploadEnded && sess.current == stream) {
          unawaited(stream.outgoingMessages.close().catchError((_) {}));
        }
      }),
    );
  }

  bool _hmacOk(String sid, int idx, String auth) {
    final expected = backupAuthHeader(uuid, sid, idx);
    return expected == auth;
  }

  void _replyError(ServerTransportStream stream, int status) {
    stream.sendHeaders(
      [Header.ascii(':status', '$status')],
      endStream: true,
    );
  }

  Future<void> _pumpUpload(
    ServerTransportStream stream,
    _FakeSession session,
    ByteFeeder feeder,
  ) async {
    final reader = GrpcMessageReader(feeder);
    Future<void> respondFirst() async {
      if (session.sentResponse) return;
      session.sentResponse = true;
      final cur = session.current;
      if (cur == null) return;
      _writeFrame(cur, vlessResponseHeader); // ответ VLESS [0, 0]
      if (mode.pushBytes > 0) {
        unawaited(_pushLoop(session));
      }
    }

    try {
      for (;;) {
        final hdr = await reader.readExact(4);
        final pl = (hdr[0] << 8) | hdr[1];
        final pd = (hdr[2] << 8) | hdr[3];
        if (pl == 0 && pd == 0) {
          session.uploadEnded = true; // маркер (0,0)
          break;
        }
        Uint8List? payload;
        if (pl > 0) {
          payload = await reader.readExact(pl);
        }
        if (pd > 0) {
          await reader.skip(pd);
        }
        if (payload == null || payload.isEmpty) {
          continue; // padding-only: пинги/фейковый аплоад — сбрасываем
        }
        if (!session.vlessDone) {
          session.vlessDone = true;
          final err = _checkVless(session, payload);
          if (err != null) {
            violations.add(err);
            return;
          }
          await respondFirst();
          continue;
        }
        if (mode.echo) {
          final cur = session.current;
          if (cur != null && payload.isNotEmpty) {
            _writeFrame(cur, payload);
          }
        }
      }
    } on ChunkEofException {
      // чистый END_STREAM без маркера — ротация: ACK — padding-only кадр
      // (сервер подтверждает полное потребление тела чанка)
      try {
        _writePaddingOnly(stream);
      } catch (_) {}
    } on Exception catch (error) {
      if (!session.uploadEnded) {
        violations.add('upload: $error');
      }
    }
  }

  String? _checkVless(_FakeSession session, Uint8List payload) {
    if (payload.length < 24) return 'vless: короткий запрос';
    if (payload[0] != 0x00) return 'vless: версия ${payload[0]}';
    for (var i = 0; i < 16; i++) {
      if (payload[1 + i] != uuid[i]) return 'vless: uuid не совпал';
    }
    if (payload[17] != 0) return 'vless: addons';
    if (payload[18] != 0x01) return 'vless: не TCP';
    final port = (payload[19] << 8) | payload[20];
    final atyp = payload[21];
    String addr;
    switch (atyp) {
      case 0x01:
        addr = '${payload[22]}.${payload[23]}.${payload[24]}.${payload[25]}';
      case 0x02:
        final len = payload[22];
        addr = String.fromCharCodes(payload.sublist(23, 23 + len));
      case 0x03:
        final b = payload.sublist(22, 38);
        final parts = <String>[];
        for (var i = 0; i < 16; i += 2) {
          parts.add(
            ((b[i] << 8) | b[i + 1]).toRadixString(16).padLeft(4, '0'),
          );
        }
        addr = parts.join(':');
      default:
        return 'vless: atyp $atyp';
    }
    session.target = '$addr:$port';
    targets[session.sid] = session.target;
    return null;
  }

  /// Серверная выдача (чистое скачивание): кадры по 16 КиБ payload.
  Future<void> _pushLoop(_FakeSession session) async {
    var remaining = mode.pushBytes;
    while (remaining > 0) {
      final cur = session.current;
      if (cur == null) return;
      final size = remaining > 16 * 1024 ? 16 * 1024 : remaining;
      final data = Uint8List(size);
      final seq = _pushSeq;
      for (var i = 0; i < size; i++) {
        data[i] = (seq + i) & 0xFF;
      }
      _pushSeq += size;
      _writeFrame(cur, data);
      remaining -= size;
      if (_pushSeq % (128 * 1024) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  void _writeFrame(ServerTransportStream stream, List<int> payload) {
    const pad = 64;
    final frame = Uint8List(4 + payload.length + pad);
    frame[0] = (payload.length >> 8) & 0xFF;
    frame[1] = payload.length & 0xFF;
    frame[2] = (pad >> 8) & 0xFF;
    frame[3] = pad & 0xFF;
    frame.setRange(4, 4 + payload.length, payload);
    frame.setRange(4 + payload.length, frame.length, randPaddingView(pad));
    final msg = Uint8List(5 + frame.length);
    msg[0] = 0;
    msg[1] = (frame.length >> 24) & 0xFF;
    msg[2] = (frame.length >> 16) & 0xFF;
    msg[3] = (frame.length >> 8) & 0xFF;
    msg[4] = frame.length & 0xFF;
    msg.setRange(5, msg.length, frame);
    stream.sendData(msg);
  }

  /// Padding-only кадр (payload=0): ACK ротации.
  void _writePaddingOnly(ServerTransportStream stream) {
    const pad = 32;
    final frame = Uint8List(4 + pad);
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = (pad >> 8) & 0xFF;
    frame[3] = pad & 0xFF;
    frame.setRange(4, frame.length, randPaddingView(pad));
    final msg = Uint8List(5 + frame.length);
    msg[0] = 0;
    msg[1] = (frame.length >> 24) & 0xFF;
    msg[2] = (frame.length >> 16) & 0xFF;
    msg[3] = (frame.length >> 8) & 0xFF;
    msg[4] = frame.length & 0xFF;
    msg.setRange(5, msg.length, frame);
    stream.sendData(msg);
  }
}

/// Отпечаток тестового сертификата (для теста пиннинга).
Future<String> serverCertFingerprint(String certPath) async {
  final pem = await File(certPath).readAsString();
  final b64 = pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), '');
  final der = base64Decode(b64);
  return sha256.convert(der).toString();
}
