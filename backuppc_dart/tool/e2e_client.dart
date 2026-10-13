/// E2E-клиент: SOCKS5-туннель backuppc_dart против живого Go-сервера.
///
///   dart run tool/e2e_client.dart --config <json> [--down MiB] [--up MiB]
///       [--target host:port]
///
/// Проверки: SHA-256 скачивания и загрузки (таргет — tool/e2e_target.dart),
/// ротации чанков, отчет о скорости, метрики клиента.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

import 'det_stream.dart';

const int blk = 64 * 1024;
const int _downSeed = 12648430; // 0xC0FFEE
const int _upSeed = 48879; // 0xBEEF

Future<void> main(List<String> args) async {
  var configPath = '';
  var downMiB = 64;
  var upMiB = 16;
  var target = '127.0.0.1:8901';
  var fast = false; // без хэширования/генерации — чистая скорость туннеля
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config':
        configPath = args[++i];
      case '--down':
        downMiB = int.tryParse(args[++i]) ?? downMiB;
      case '--up':
        upMiB = int.tryParse(args[++i]) ?? upMiB;
      case '--target':
        target = args[++i];
      case '--fast':
        fast = true;
    }
  }
  if (configPath.isEmpty) {
    stderr.writeln('usage: e2e_client.dart --config <json> [options]');
    exit(2);
  }
  final cfg = loadClientConfigFromJson(await File(configPath).readAsString());
  final client = await BackupPcClient.start(
    cfg,
    log: (line) => stderr.writeln('[bpc] $line'),
  );
  final socksPort = int.parse(cfg.socksListen.split(':').last);
  final (tHost, tPort) = _split(target);
  final report = <String, dynamic>{};

  // --- healthz через туннель ---
  final t0 = DateTime.now();
  final health = await _roundtrip(
    socksPort,
    tHost,
    tPort,
    'GET /healthz HTTP/1.1\r\nHost: target\r\nConnection: close\r\n\r\n',
  );
  report['healthz'] = health.status == 200;
  report['handshakeMs'] = DateTime.now().difference(t0).inMilliseconds;

  // --- скачивание ---
  if (downMiB > 0) {
    final n = downMiB * 1024 * 1024;
    final sw = Stopwatch()..start();
    final resp = await _roundtrip(
      socksPort,
      tHost,
      tPort,
      'GET /data?n=$n&seed=$_downSeed HTTP/1.1\r\nHost: target\r\n'
      'Connection: close\r\n\r\n',
      hash: !fast,
    );
    sw.stop();
    final sec = sw.elapsedMilliseconds / 1000;
    report['download'] = {
      'bytes': n,
      'sha256': fast
          ? 'skipped'
          : (resp.sha == detSha256(_downSeed, n)
                ? 'ok'
                : 'MISMATCH ${resp.sha}'),
      'lengthOk': resp.bodyLength == n,
      'seconds': sec,
      'MiBps': (n / 1024 / 1024) / sec,
      'status': resp.status,
    };
  }

  // --- загрузка ---
  if (upMiB > 0) {
    final n = upMiB * 1024 * 1024;
    final sw = Stopwatch()..start();
    final resp = await _upload(
      socksPort,
      tHost,
      tPort,
      _upSeed,
      n,
      generate: !fast,
    );
    sw.stop();
    final sec = sw.elapsedMilliseconds / 1000;
    report['upload'] = {
      'bytes': n,
      'sha256': fast
          ? 'skipped'
          : (resp == detSha256(_upSeed, n) ? 'ok' : 'MISMATCH $resp'),
      'seconds': sec,
      'MiBps': (n / 1024 / 1024) / sec,
    };
  }

  // --- метрики ---
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final m = client.metrics();
  report['metrics'] = {
    'sessions': m.sessions,
    'activeSessions': m.activeSessions,
    'chunks': m.chunks,
    'rotations': m.rotations,
    'txPayload': m.txPayload,
    'rxPayload': m.rxPayload,
    'txFake': m.txFake,
    'fakeJobs': m.fakeJobs,
    'fakeJobBytes': m.fakeJobBytes,
  };
  report['ok'] = (report['healthz'] == true) &&
      (downMiB == 0 ||
          report['download']?['sha256'] == 'ok' ||
          report['download']?['sha256'] == 'skipped') &&
      (report['download']?['lengthOk'] != false) &&
      (upMiB == 0 ||
          report['upload']?['sha256'] == 'ok' ||
          report['upload']?['sha256'] == 'skipped');

  print(const JsonEncoder.withIndent('  ').convert(report));
  await client.stop();
  exit(report['ok'] == true ? 0 : 1);
}

(String, int) _split(String addr) {
  final i = addr.lastIndexOf(':');
  return (addr.substring(0, i), int.parse(addr.substring(i + 1)));
}

class _Resp {
  final int status;
  final String sha;
  final int bodyLength;
  const _Resp(this.status, this.sha, this.bodyLength);
}

/// GET через туннель; качает тело целиком, считает sha256 (если hash).
Future<_Resp> _roundtrip(
  int socksPort,
  String host,
  int port,
  String request, {
  bool hash = true,
}) async {
  final (sock, reader) = await _socksConnect(socksPort, host, port);
  try {
    sock.add(utf8.encode(request));
    await sock.flush();
    final head = await _readHeader(reader);
    final status = int.tryParse(head.split(' ')[1]) ?? 0;
    var length = -1;
    for (final line in head.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-length:')) {
        length = int.tryParse(line.substring(15).trim()) ?? -1;
      }
    }
    final out = hash ? AccumulatorSink<Digest>() : null;
    final sink = out == null ? null : sha256.startChunkedConversion(out);
    var got = 0;
    while (got < length) {
      final chunk = await reader.readChunk().timeout(
        const Duration(seconds: 180),
        onTimeout: () => null,
      );
      if (chunk == null) break;
      sink?.add(chunk);
      got += chunk.length;
    }
    sink?.close();
    return _Resp(status, out == null ? '' : out.events.single.toString(), got);
  } finally {
    await sock.close().catchError((_) {});
  }
}

/// POST /sink: тело из DetStream (или предгенерированный буфер в fast-режиме);
/// ответ — sha256 от таргета (hex или JSON{"bytes","sha256"}).
Future<String> _upload(
  int socksPort,
  String host,
  int port,
  int seed,
  int n, {
  bool generate = true,
}) async {
  final (sock, reader) = await _socksConnect(socksPort, host, port);
  try {
    sock.add(utf8.encode(
      'POST /sink HTTP/1.1\r\nHost: target\r\nContent-Length: $n\r\n'
      'Connection: close\r\n\r\n',
    ));
    final gen = generate ? DetStream(seed) : null;
    final pre = Uint8List(blk);
    if (gen == null) {
      pre.fillRange(0, blk, 0x5A); // fast-режим: предгенерированный блок
    }
    var off = 0;
    while (off < n) {
      final take = (n - off) < blk ? (n - off) : blk;
      final view = Uint8List.sublistView(pre, 0, take);
      if (gen != null) {
        gen.readInto(view); // detStream на лету (integrity-режим)
      }
      // ВАЖНО: копируем — Socket.add не обещает копирования, а буфер
      // переиспользуется следующей итерацией (порча данных иначе)
      sock.add(Uint8List.fromList(view));
      off += take;
      if (off % (blk * 4) == 0) {
        await sock.flush(); // backpressure: OS-буфер полон → ожидание
      }
    }
    await sock.flush();
    // читаем ответ
    final head = await _readHeader(reader);
    final status = int.tryParse(head.split(' ')[1]) ?? 0;
    var length = -1;
    for (final line in head.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-length:')) {
        length = int.tryParse(line.substring(15).trim()) ?? -1;
      }
    }
    final acc = BytesBuilder();
    while (acc.length < length) {
      final chunk = await reader.readChunk().timeout(
        const Duration(seconds: 30),
        onTimeout: () => null,
      );
      if (chunk == null) break;
      acc.add(chunk);
    }
    if (status != 200) {
      return 'HTTP $status: ${utf8.decode(acc.toBytes())}';
    }
    final body = utf8.decode(acc.toBytes());
    // Go bench-таргет возвращает JSON, Dart-таргет — голый hex
    if (body.startsWith('{')) {
      try {
        final obj = jsonDecode(body) as Map<String, dynamic>;
        return '${obj['sha256']}';
      } catch (_) {}
    }
    return body;
  } finally {
    await sock.close().catchError((_) {});
  }
}

Future<(Socket, SocketByteReader)> _socksConnect(
  int port,
  String host,
  int targetPort,
) async {
  final sock = await Socket.connect('127.0.0.1', port);
  sock.setOption(SocketOption.tcpNoDelay, true);
  final reader = SocketByteReader(sock);
  sock.add([0x05, 0x01, 0x00]);
  await sock.flush();
  final m = await reader.readExact(2).timeout(const Duration(seconds: 10));
  if (m[1] != 0x00) {
    throw StateError('socks: no acceptable methods');
  }
  final hostBytes = host.codeUnits;
  sock.add([
    0x05,
    0x01,
    0x00,
    0x03,
    hostBytes.length,
    ...hostBytes,
    targetPort >> 8,
    targetPort & 0xFF,
  ]);
  await sock.flush();
  final reply = await reader.readExact(10).timeout(const Duration(seconds: 15));
  if (reply[1] != 0x00) {
    throw StateError('socks: CONNECT failed (${reply[1]})');
  }
  return (sock, reader);
}

Future<String> _readHeader(SocketByteReader reader) async {
  // побайтово: заголовки и тело могут прийти одним сегментом,
  // readChunk съел бы лишнее — терять байты нельзя
  final acc = BytesBuilder();
  for (;;) {
    final b = await reader.readExact(1).timeout(
      const Duration(seconds: 30),
    );
    acc.add(b);
    if (acc.length >= 4) {
      final tail = acc.toBytes().sublist(acc.length - 4);
      if (tail.length == 4 &&
          tail[0] == 13 && tail[1] == 10 && tail[2] == 13 && tail[3] == 10) {
        final all = acc.toBytes();
        return utf8.decode(all.sublist(0, all.length - 4), allowMalformed: true);
      }
    }
  }
}
