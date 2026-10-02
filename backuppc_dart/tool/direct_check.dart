import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import 'det_stream.dart';

Future<void> main() async {
  const seed = 12648430;
  const n = 1024 * 1024;
  final sock = await Socket.connect('127.0.0.1', 18999);
  sock.add(
    utf8.encode(
      'GET /data?n=$n&seed=$seed HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n',
    ),
  );
  await sock.flush();
  final it = StreamIterator<Uint8List>(sock);
  final acc = BytesBuilder();
  var headerDone = false;
  var contentLength = -1;
  final body = BytesBuilder();
  while (true) {
    final has = await it.moveNext().timeout(const Duration(seconds: 20));
    if (!has) break;
    final d = it.current;
    if (!headerDone) {
      acc.add(d);
      final text = utf8.decode(acc.toBytes(), allowMalformed: true);
      final idx = text.indexOf('\r\n\r\n');
      if (idx >= 0) {
        headerDone = true;
        final head = text.substring(0, idx);
        for (final line in head.split('\r\n')) {
          if (line.toLowerCase().startsWith('content-length:')) {
            contentLength = int.parse(line.substring(15).trim());
          }
        }
        final raw = acc.toBytes();
        final consumed = utf8.encode(text.substring(0, idx + 4)).length;
        if (raw.length > consumed) {
          body.add(Uint8List.sublistView(raw, consumed));
        }
      }
    } else {
      body.add(d);
    }
    if (headerDone && body.length >= contentLength) break;
  }
  await it.cancel();
  await sock.close();
  final b = body.toBytes();
  final out = AccumulatorSink<Digest>();
  final sink = sha256.startChunkedConversion(out);
  sink.add(b);
  sink.close();
  print('body=${b.length}/${contentLength} sha=${out.events.single}');
  print('expected ${detSha256(seed, n)}');
  exit(0);
}
