/// Детерминированный поток байт — точный порт `detStream` из
/// `cmd/backuppc-bench` (Go): одинаковый seed → одинаковый поток на
/// клиенте и таргете без предварительного обмена.
///
/// Алгоритм: блоки 64 КиБ, xorshift64* от номера блока и зерна:
///     s = seed ^ (idx * 0x9E3779B97F4A7C15)
///     s ^= s << 13; s ^= s >>> 7; s ^= s << 17   (8 байт LE за шаг)
///
/// Используется e2e-таргетом и e2e-клиентом для проверки SHA-256.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

const int detBlockSize = 64 * 1024;

class DetStream {
  final int seed; // уже seed | 1 (как в Go)
  final Uint8List block;
  late final ByteData _view;
  int _idx = 0;
  int _pos = 0;

  DetStream(int rawSeed)
    : seed = rawSeed | 1,
      block = Uint8List(detBlockSize) {
    _view = ByteData.sublistView(block);
  }

  void _refill() {
    var s = seed ^ (_idx * 0x9E3779B97F4A7C15); // int64 wrap = uint64
    for (var i = 0; i < detBlockSize; i += 8) {
      s ^= s << 13;
      s ^= s >>> 7; // логический сдвиг как uint64 в Go
      s ^= s << 17;
      if (s == 0) {
        s = seed + _idx + 1;
      }
      _view.setUint64(i, s, Endian.little);
    }
    _idx++;
    _pos = 0;
  }

  /// Пишет в p ровно p.length байт потока (как io.CopyN).
  int readInto(Uint8List p) {
    var n = 0;
    var off = 0;
    while (off < p.length) {
      if (_pos == 0 || _pos >= detBlockSize) {
        _refill();
      }
      final room = detBlockSize - _pos;
      final want = p.length - off;
      final m = room < want ? room : want;
      p.setRange(off, off + m, block, _pos);
      _pos += m;
      off += m;
      n += m;
    }
    return n;
  }

  /// Следующий кусок потока (для streaming-отправки).
  Uint8List nextChunk(int n) {
    final out = Uint8List(n);
    readInto(out);
    return out;
  }
}

/// SHA-256 первых n байт потока (без материализации всего потока).
String detSha256(int seed, int n) {
  final stream = DetStream(seed);
  final out = AccumulatorSink<Digest>();
  final sink = sha256.startChunkedConversion(out);
  final buf = Uint8List(detBlockSize);
  var left = n;
  while (left > 0) {
    final take = left < detBlockSize ? left : detBlockSize;
    stream.readInto(
      take == detBlockSize ? buf : Uint8List.sublistView(buf, 0, take),
    );
    sink.add(Uint8List.sublistView(buf, 0, take));
    left -= take;
  }
  sink.close();
  return out.events.single.toString();
}
