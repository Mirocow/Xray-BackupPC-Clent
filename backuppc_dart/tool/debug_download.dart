// Дебаг: сохраняет полученное тело в файл для побайтового сравнения
// с эталоном (поиск смещения первой расходимости).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:backuppc_dart/backuppc_dart.dart';

Future<void> main(List<String> args) async {
  var configPath = '';
  var downMiB = 8;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config') configPath = args[++i];
    if (args[i] == '--down') downMiB = int.parse(args[++i]);
  }
  final cfg = loadClientConfigFromJson(await File(configPath).readAsString());
  final client = await BackupPcClient.start(
    cfg,
    log: (line) => stderr.writeln('[bpc] $line'),
  );
  // heartbeat: состояние туннеля каждую секунду
  Future<void> hbLoop() async {
    var prev = 0;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final m = client.metrics();
      final active = client.activeConns;
      stderr.writeln(
        '[hb] rx=${m.rxPayload} (d=${m.rxPayload - prev}) '
        'rot=${m.rotations} conns=${active.length} '
        '${active.isNotEmpty ? active.first.debugState() : ''}',
      );
      prev = m.rxPayload;
    }
  }

  unawaited(hbLoop());
  final socksPort = int.parse(cfg.socksListen.split(':').last);
  final n = downMiB * 1024 * 1024;

  final (sock, reader) = await _connect(socksPort, '127.0.0.1', 18999);
  sock.add(
    utf8.encode(
      'GET /data?n=$n&seed=12648430 HTTP/1.1\r\nHost: target\r\n'
      'Connection: close\r\n\r\n',
    ),
  );
  await sock.flush();
  // заголовки
  final head = await _readHeader(reader);
  var length = -1;
  for (final line in head.split('\r\n')) {
    if (line.toLowerCase().startsWith('content-length:')) {
      length = int.parse(line.substring(15).trim());
    }
  }
  stderr.writeln('header: $length bytes expected');
  final out = File('/tmp/received.bin').openSync(mode: FileMode.write);
  var got = 0;
  while (got < length) {
    final chunk = await reader
        .readChunk()
        .timeout(const Duration(seconds: 60), onTimeout: () => null);
    if (chunk == null) break;
    out.writeFromSync(chunk);
    got += chunk.length;
  }
  out.closeSync();
  stderr.writeln('received: $got bytes');
  await client.stop();
  exit(got == length ? 0 : 1);
}

Future<(Socket, SocketByteReader)> _connect(int port, String host, int tport) async {
  final sock = await Socket.connect('127.0.0.1', port);
  final reader = SocketByteReader(sock);
  sock.add([0x05, 0x01, 0x00]);
  await sock.flush();
  await reader.readExact(2);
  final hb = host.codeUnits;
  sock.add([
    0x05, 0x01, 0x00, 0x03, hb.length, ...hb, tport >> 8, tport & 0xFF,
  ]);
  await sock.flush();
  await reader.readExact(10);
  return (sock, reader);
}

Future<String> _readHeader(SocketByteReader reader) async {
  final acc = BytesBuilder();
  for (;;) {
    final b = await reader.readExact(1);
    acc.add(b);
    if (acc.length >= 4) {
      final all = acc.toBytes();
      final tail = all.sublist(all.length - 4);
      if (tail[0] == 13 && tail[1] == 10 && tail[2] == 13 && tail[3] == 10) {
        return utf8.decode(all.sublist(0, all.length - 4), allowMalformed: true);
      }
    }
  }
}
