// E2E: полный клиентский стек (SOCKS5 → туннель → несущий канал) против
// wire-совместимого фальшивого сервера: эхо, ротация чанков при загрузке
// и при чистом скачивании (сценарий rotfix), пиннинг, анти-пробинг.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

import 'helpers/fake_server.dart';

const testUuid = '01234567-89ab-cdef-0123-456789abcdef';

ClientConfig _config(int port, {int? maxSessionBytes}) {
  return ClientConfig.fromJson({
    'serverAddr': '127.0.0.1:$port',
    'uuid': testUuid,
    'insecure': true,
    'transport': {
      'host': 'donor.example',
      if (maxSessionBytes != null) 'maxSessionBytes': maxSessionBytes,
      'maxSessionDuration': '30m',
      // быстрые тесты: маленькие таймеры не влияют на контракт
      'pingBaseInterval': '5s',
      'balancingInterval': '1s',
      'backuppc': {
        'enabled': true,
        'incrementalEvery': '2s',
        'incrementalMinBytes': 4096,
        'incrementalMaxBytes': 8192,
      },
    },
  });
}

/// SOCKS5-клиент теста: CONNECT на target; единый буферизованный читатель
/// (одна подписка на стрим сокета на всё время теста).
Future<(Socket, SocketByteReader)> socksConnect(
  int port,
  String target,
) async {
  final sock = await Socket.connect('127.0.0.1', port);
  final reader = SocketByteReader(sock);
  sock.add([0x05, 0x01, 0x00]);
  await sock.flush();
  final methods = await reader.readExact(2).timeout(_sockTimeout);
  expect(methods[0], 0x05);
  expect(methods[1], 0x00);
  final hostBytes = target.codeUnits;
  final req = <int>[
    0x05,
    0x01,
    0x00,
    0x03,
    hostBytes.length,
    ...hostBytes,
    443 >> 8,
    443 & 0xFF,
  ];
  sock.add(req);
  await sock.flush();
  final reply = await reader.readExact(10).timeout(_sockTimeout);
  expect(reply[0], 0x05);
  expect(reply[1], 0x00, reason: 'CONNECT отклонен');
  return (sock, reader);
}

const _sockTimeout = Duration(seconds: 15);

Uint8List _pattern(int n, int seed) =>
    Uint8List.fromList(List.generate(n, (i) => (seed + i) & 0xFF));

void main() {
  late FakeBackupPcServer server;

  setUp(() {
    server = FakeBackupPcServer(uuid: parseUUID(testUuid)!);
  });

  tearDown(() async {
    await server.stop();
  });

  test('e2e: эхо через SOCKS5, VLESS-target проверен сервером', () async {
    final port = await server.start();
    final cfg = _config(port);
    final client = await BackupPcClient.start(cfg);
    try {
      final (sock, reader) = await socksConnect(
        int.parse(cfg.socksListen.split(':').last),
        'example.org',
      );
      final data = _pattern(200 * 1024, 7);
      sock.add(data);
      await sock.flush();
      final received = await _drain(reader, data.length);
      expect(sha256.convert(received), sha256.convert(data));
      await sock.close();
      await _waitUntil(() => client.metrics().sessions >= 1);
      expect(server.violations, isEmpty);
      expect(server.targets.values, contains('example.org:443'));
    } finally {
      await client.stop();
    }
  });

  test('e2e: ротация чанков при непрерывной загрузке (SHA-256 целостность)',
      () async {
    server = FakeBackupPcServer(uuid: parseUUID(testUuid)!);
    final port = await server.start();
    final cfg = _config(port, maxSessionBytes: 32 * 1024);
    final client = await BackupPcClient.start(cfg);
    try {
      final (sock, reader) = await socksConnect(
        int.parse(cfg.socksListen.split(':').last),
        'backup.test',
      );
      final data = _pattern(256 * 1024, 3);
      // режем отправку, чтобы писатель успевал ротировать между записями
      for (var off = 0; off < data.length; off += 16 * 1024) {
        final end = (off + 16 * 1024) < data.length ? off + 16 * 1024 : data.length;
        sock.add(Uint8List.sublistView(data, off, end));
        await sock.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final received = await _drain(reader, data.length);
      expect(sha256.convert(received), sha256.convert(data));
      await sock.close();
      await _waitUntil(() => client.metrics().rotations > 0);
      final m = client.metrics();
      expect(m.rotations, greaterThan(0));
      expect(server.violations, isEmpty);
      // индексы чанков строго последовательны
      final idxs = [for (final r in server.records) r.chunkIndex];
      expect(idxs, List.generate(idxs.length, (i) => i));
    } finally {
      await client.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('e2e: чистое скачивание с ротацией по лимиту чанка (rotfix)',
      () async {
    server = FakeBackupPcServer(
      uuid: parseUUID(testUuid)!,
      mode: const FakeServerMode(echo: false, pushBytes: 128 * 1024),
    );
    final port = await server.start();
    final cfg = _config(port, maxSessionBytes: 16 * 1024);
    final client = await BackupPcClient.start(cfg);
    try {
      final (sock, reader) = await socksConnect(
        int.parse(cfg.socksListen.split(':').last),
        'download.test',
      );
      // клиент ничего не пишет: сервер выдает 128 КиБ сам
      final received = await _drain(reader, 128 * 1024);
      expect(received, equals(_pattern(128 * 1024, 0)));
      await sock.close();
      await _waitUntil(() => client.metrics().rotations > 0);
      expect(client.metrics().rotations, greaterThan(0));
      expect(server.violations, isEmpty);
    } finally {
      await client.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('e2e: пиннинг сертификата (верный отпечаток)', () async {
    final port = await server.start();
    final fp = await serverCertFingerprint('test/fixtures/server.crt');
    final conn = await dialLogical(
      _config(port),
      address: 'pinned.test',
      port: 443,
      tls: CarrierTls(certFingerprint: fp),
    );
    expect(server.violations, isEmpty);
    expect(server.targets.values, contains('pinned.test:443'));
    await conn.close();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('e2e: неверный пиннинг — соединение отклоняется', () async {
    final port = await server.start();
    final badFp = '00' * 32;
    expect(
      dialLogical(
        _config(port),
        address: 'bad-pin.test',
        port: 443,
        tls: CarrierTls(certFingerprint: badFp),
      ),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('e2e: анти-пробинг — неизвестный путь получает 404', () async {
    final port = await server.start();
    final raw = await Socket.connect('127.0.0.1', port);
    final secure = await SecureSocket.secure(
      raw,
      host: 'donor.example',
      onBadCertificate: (_) => true,
      supportedProtocols: const ['h2'],
    );
    final conn = ClientTransportConnection.viaSocket(secure);
    final stream = conn.makeRequest([
      Header.ascii(':method', 'POST'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':path', '/unknown/path'),
      Header.ascii(':authority', 'donor.example'),
      Header.ascii('content-type', 'application/grpc'),
    ], endStream: true);
    final firstMessage = await stream.incomingMessages
        .firstWhere((m) => m is HeadersStreamMessage)
        .timeout(const Duration(seconds: 10));
    final msg = firstMessage as HeadersStreamMessage;
    String status = '';
    for (final h in msg.headers) {
      if (String.fromCharCodes(h.name) == ':status') {
        status = String.fromCharCodes(h.value);
      }
    }
    expect(status, '404');
    await conn.finish();
    secure.destroy();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('e2e: метрики клиента агрегируют сессии', () async {
    final port = await server.start();
    final client = await BackupPcClient.start(_config(port));
    try {
      final p = int.parse(client.cfg.socksListen.split(':').last);
      final (sock1, reader1) = await socksConnect(p, 'one.test');
      final (sock2, reader2) = await socksConnect(p, 'two.test');
      sock1.add(_pattern(1024, 1));
      sock2.add(_pattern(1024, 2));
      await sock1.flush();
      await sock2.flush();
      await _drain(reader1, 1024);
      await _drain(reader2, 1024);
      await sock1.close();
      await sock2.close();
      await _waitUntil(() => client.metrics().sessions >= 2);
      final m = client.metrics();
      expect(m.sessions, greaterThanOrEqualTo(2));
      expect(m.rxPayload, greaterThanOrEqualTo(2048));
      expect(server.violations, isEmpty);
    } finally {
      await client.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<Uint8List> _drain(SocketByteReader reader, int total) async {
  final acc = BytesBuilder();
  while (acc.length < total) {
    final chunk = await reader.readChunk().timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
    if (chunk == null) break;
    acc.add(chunk);
  }
  if (acc.length < total) {
    throw StateError('получено ${acc.length} из $total байт');
  }
  return acc.toBytes();
}

Future<void> _waitUntil(bool Function() cond) async {
  for (var i = 0; i < 100; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
