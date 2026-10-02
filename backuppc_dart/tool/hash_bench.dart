import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart' show AccumulatorSink;

Future<void> main() async {
  final data = Uint8List(64 * 1024 * 1024);
  for (var i = 0; i < data.length; i += 8) {
    data[i] = i & 0xFF;
  }
  // sha256 chunked (как в e2e-клиенте)
  final sw = Stopwatch()..start();
  final out = AccumulatorSink<Digest>();
  final sink = sha256.startChunkedConversion(out);
  for (var off = 0; off < data.length; off += 65536) {
    sink.add(Uint8List.sublistView(data, off, off + 65536));
  }
  sink.close();
  sw.stop();
  print('sha256: ${(data.length >> 20) / (sw.elapsedMilliseconds / 1000)} MiB/s');

  // генератор block() из e2e-клиента (xorshift побайтно)
  final sw2 = Stopwatch()..start();
  final blk = Uint8List(4 * 1024 * 1024);
  var x = 0xC0FFEE;
  for (var i = 0; i < blk.length; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    blk[i] = x & 0xFF;
  }
  sw2.stop();
  print('block(): ${(blk.length >> 20) / (sw2.elapsedMilliseconds / 1000)} MiB/s');
}
