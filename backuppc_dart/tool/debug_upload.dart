// Дебаг upload: эхо-таргет возвращает тело обратно; побайтовое сравнение.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:backuppc_dart/backuppc_dart.dart';

import 'det_stream.dart';

Future<void> main(List<String> args) async {
  var configPath = '/tmp/dbg-bpc/client.json';
  var upMiB = 16;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config') configPath = args[++i];
    if (args[i] == '--up') upMiB = int.parse(args[++i]);
  }
  // эхо-таргет
  final echo = await ServerSocket.bind('127.0.0.1', 0);
  final echoPort = echo.port;
  echo.listen((s) {
    s.setOption(SocketOption.tcpNoDelay, true);
    unawaited(
      s.forEach((data) {
        s.add(data);
      }).catchError((_) {}),
    );
  });

  final cfg = loadClientConfigFromJson(await File(configPath).readAsString());
  final client = await BackupPcClient.start(
    cfg,
    log: (line) => stderr.writeln('[bpc] $line'),
  );
  final socksPort = int.parse(cfg.socksListen.split(':').last);
  final n = upMiB * 1024 * 1024;

  final (sock, reader) = await _connect(socksPort, '127.0.0.1', echoPort);
  final gen = DetStream(48879);
  final buf = Uint8List(64 * 1024);
  var off = 0;
  while (off < n) {
    final take = (n - off) < buf.length ? (n - off) : buf.length;
    gen.readInto(Uint8List.sublistView(buf, 0, take));
    // копия: Socket.add держит ссылку, буфер переиспользуется
    sock.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, take)));
    off += take;
    if (off % (64 * 1024 * 4) == 0) await sock.flush();
  }
  await sock.flush();
  // читаем эхо
  final got = BytesBuilder();
  while (got.length < n) {
    final chunk = await reader
        .readChunk()
        .timeout(const Duration(seconds: 30), onTimeout: () => null);
    if (chunk == null) break;
    got.add(chunk);
  }
  final received = got.toBytes();
  stderr.writeln('echo: ${received.length}/$n');
  File('/tmp/echo.bin').writeAsBytesSync(received);
  if (received.length != n) {
    stderr.writeln('LENGTH MISMATCH');
  } else {
    final expect = DetStream(48879);
    final eb = Uint8List(n);
    expect.readInto(eb);
    var diffAt = -1;
    for (var i = 0; i < n; i++) {
      if (received[i] != eb[i]) {
        diffAt = i;
        break;
      }
    }
    stderr.writeln(diffAt < 0 ? 'CONTENT OK' : 'DIFF at $diffAt');
  }
  await client.stop();
  exit(0);
}

Future<(Socket, SocketByteReader)> _connect(int port, String host, int tport) async {
  final sock = await Socket.connect('127.0.0.1', port);
  final reader = SocketByteReader(sock);
  sock.add([0x05, 0x01, 0x00]);
  await sock.flush();
  await reader.readExact(2);
  final hb = host.codeUnits;
  sock.add([0x05, 0x01, 0x00, 0x03, hb.length, ...hb, tport >> 8, tport & 0xFF]);
  await sock.flush();
  await reader.readExact(10);
  return (sock, reader);
}
