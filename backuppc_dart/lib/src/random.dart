/// Криптографические помощники (аналог crypto/rand в Go-библиотеке).
///
/// Все случайности протокола — от `Random.secure()`: наблюдатель не
/// должен отличать наши «байты бекапа» от энтропии.
///
/// Производительность: [randBytes] питается из пула, который заполняется
/// пачками по 32 бита за вызов (`nextInt(0x100000000)`), поэтому генерация
/// паддинга на гигабайтных скоростях не становится узким местом (8K-видео,
/// сотни ГиБ на сессию).
library;

import 'dart:math';
import 'dart:typed_data';

final Random _rng = Random.secure();

/// Равномерно случайное целое [min, max] включительно.
int randIntRange(int min, int max) {
  if (max < min) {
    final t = min;
    min = max;
    max = t;
  }
  if (max == min) return min;
  return min + _rng.nextInt(max - min + 1);
}

/// Равномерно случайная длительность [min, max] (включительно).
/// Диапазон может превышать 2^32 микросекунд — тогда дробная шкала.
Duration randDurationRange(Duration min, Duration max) {
  final lo = min.inMicroseconds;
  final hi = max.inMicroseconds;
  if (hi <= lo) return min;
  final span = hi - lo;
  int offset;
  if (span <= 0x7FFFFFFF) {
    offset = _rng.nextInt(span + 1);
  } else {
    // две 30-битные части → 60 бит равномерно
    final hiPart = _rng.nextInt(1 << 30);
    final loPart = _rng.nextInt(1 << 30);
    offset = ((hiPart * (1 << 30) + loPart) * span) ~/ (1 << 60);
  }
  return Duration(microseconds: lo + offset);
}

/// Случайный hex-nonce заданной длины байт.
String randHex(int bytes) {
  final b = randBytes(bytes);
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(digits[x >> 4]);
    sb.write(digits[x & 0xF]);
  }
  return sb.toString();
}

const int _poolSize = 1 << 16; // 64 КиБ

/// Пул криптослучайных байт: заполнение пачками, выдача срезами-видами.
class _RandomPool {
  Uint8List _data = Uint8List(0);
  int _off = 0;

  void _refill(int minLen) {
    var size = _poolSize;
    while (size < minLen) {
      size <<= 1;
    }
    final data = Uint8List(size);
    final view = ByteData.view(data.buffer);
    var filled = 0;
    while (filled < size) {
      final word = _rng.nextInt(0x100000000);
      view.setUint32(filled, word, Endian.big);
      filled += 4;
    }
    _data = data;
    _off = 0;
  }

  /// Ноль копий: возвращает вид на пул (действителен до следующего вызова).
  Uint8List take(int n) {
    if (n <= 0) return Uint8List(0);
    if (n > 0xFFFF) n = 0xFFFF; // максимум паддинга кадра
    if (_off + n > _data.length) {
      _refill(n);
    }
    final view = Uint8List.sublistView(_data, _off, _off + n);
    _off += n;
    return view;
  }
}

final _RandomPool _pool = _RandomPool();

/// Случайные байты. Для больших объемов используйте [randPaddingView]:
/// эта функция копирует результат в независимый буфер.
Uint8List randBytes(int n) {
  if (n <= 0) return Uint8List(0);
  return Uint8List.fromList(randPaddingView(n));
}

/// Случайные байты как немодифицируемый срез (без копии).
/// ⚠️ Валиден только до следующего вызова генератора.
Uint8List randPaddingView(int n) => _pool.take(n);
