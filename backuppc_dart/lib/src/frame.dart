/// Бинарный фрейминг протокола (ТЗ 3.1) — Dart-порт `EmulatedConn`.
///
///       0        1        2        3        4       4+N      4+N+M
///      +--------+--------+--------+--------+--------+---------+
///      | Payload Length  | Padding Length  | Payload | Padding |
///      |   (2B, BE)      |   (2B, BE)      |  (N)    |  (M)    |
///      +--------+--------+--------+--------+--------+---------+
///
/// Кадр (0,0) — маркер конца логической сессии (graceful EOF).
/// Кадр (0,M>0) — padding-only: пинги и фейковый аплоад.
library;

import 'dart:async';
import 'dart:typed_data';

import 'config.dart';
import 'random.dart';

const int frameHeaderSize = 4; // 2B payload + 2B padding
const int frameMaxPayload = 0xFFFF;
const int frameMaxPadding = 0xFFFF;
const int frameMaxTotal = frameHeaderSize + frameMaxPayload + frameMaxPadding;

/// Транспорт чтения/записи байтов чанка (gRPC-обвязка поверх HTTP/2).
/// Реализации: [GrpcMessageReader] и переключающийся читатель туннеля.
abstract class ChunkByteReader {
  /// Читает ровно n байт; бросает [ChunkEofException] при EOF.
  Future<Uint8List> readExact(int n);

  /// Пропускает n байт (сброс паддинга) без аллокаций.
  Future<void> skip(int n) async {
    while (n > 0) {
      final piece = await readExact(n);
      n -= piece.length;
    }
  }
}

/// EOF потока чанка (END_STREAM тела ответа).
class ChunkEofException implements Exception {
  const ChunkEofException();
  @override
  String toString() => 'chunk: EOF';
}

/// Ошибка потока (RST_STREAM, транспорт).
class StreamException_ implements Exception {
  final String message;
  const StreamException_(this.message);
  @override
  String toString() => 'chunk: $message';
}

/// Кодек кадров поверх байтового потока чанка.
///
/// Потокобезопасность записи: [write], [writePadding], [writeEof]
/// сериализуются внутренним локом (писатели: релей, пинги, балансировщик).
class FrameCodec {
  final ChunkByteReader? reader; // null → только запись
  final Future<void> Function(List<int> frame)? _rawWrite;
  final TransportConfig cfg;

  Future<void>? _writeLock;
  bool _closed = false;

  // стримовое чтение: остаток payload предыдущего кадра
  Uint8List? _pending;
  int _pendingOff = 0;

  int txPayload = 0, rxPayload = 0, txWire = 0, rxWire = 0;

  FrameCodec.forWriting(this._rawWrite, this.cfg) : reader = null;
  FrameCodec.forReading(this.reader, this.cfg) : _rawWrite = null;

  bool get closed => _closed;
  set closedFlag(bool v) => _closed = v;

  /// Хук на padding-only кадр (payload=0, padding>0): сервер шлет такой
  /// как ACK ротации — доказательство, что тело чанка потреблено целиком.
  void Function()? onPaddingOnly;

  // --- запись ---

  Future<T> _locked<T>(Future<T> Function() fn) {
    final prev = _writeLock ?? Future<void>.value();
    final task = prev.then((_) => fn());
    _writeLock = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  /// Фреймует полезную нагрузку с рандомным паддингом; большие записи
  /// нарезаются на кадры до maxWriteChunk байт payload.
  Future<int> write(List<int> b) => _locked(() async {
    if (_closed) throw const StreamException_('поток закрыт');
    var total = 0;
    var off = 0;
    while (off < b.length) {
      var seg = b.length - off;
      if (seg > cfg.maxWriteChunk) seg = cfg.maxWriteChunk;
      if (seg > frameMaxPayload) seg = frameMaxPayload;
      final pad = cfg.randPadding();
      final frame = Uint8List(frameHeaderSize + seg + pad);
      frame[0] = (seg >> 8) & 0xFF;
      frame[1] = seg & 0xFF;
      frame[2] = (pad >> 8) & 0xFF;
      frame[3] = pad & 0xFF;
      frame.setRange(frameHeaderSize, frameHeaderSize + seg, b, off);
      if (pad > 0) {
        // срез из пула криптослучайных байт — без генерации в лоб
        frame.setRange(
          frameHeaderSize + seg, frameHeaderSize + seg + pad, randPaddingView(pad),
        );
      }
      await _writeFrame(frame);
      txPayload += seg;
      txWire += frame.length;
      total += seg;
      off += seg;
    }
    return total;
  });

  /// Padding-only кадры (payload=0): джиттер-пинги (ТЗ 3.2) и фейковый
  /// аплоад балансировщика (ТЗ 4.2). Прозрачны для полезной нагрузки.
  Future<int> writePadding(int n) => _locked(() async {
    if (_closed) throw const StreamException_('поток закрыт');
    var written = 0;
    while (n > 0) {
      var pad = n;
      if (pad > frameMaxPadding) pad = frameMaxPadding;
      final frame = Uint8List(frameHeaderSize + pad);
      frame[0] = 0;
      frame[1] = 0;
      frame[2] = (pad >> 8) & 0xFF;
      frame[3] = pad & 0xFF;
      frame.setRange(
        frameHeaderSize, frameHeaderSize + pad, randPaddingView(pad),
      );
      await _writeFrame(frame);
      txWire += frame.length;
      written += pad;
      n -= pad;
    }
    return written;
  });

  /// Маркер конца логической сессии — кадр (0,0).
  Future<void> writeEof() => _locked(() async {
    if (_closed) throw const StreamException_('поток закрыт');
    await _writeFrame(Uint8List(frameHeaderSize));
  });

  Future<void> _writeFrame(Uint8List frame) async {
    final w = _rawWrite;
    if (w == null) throw const StreamException_('кодек только на чтение');
    await w(frame);
  }

  // --- чтение (стримовое, единственный читатель) ---

  /// Возвращает payload байтами произвольного размера буфера b.
  /// Паддинг читается и сбрасывается (ТЗ 3.2). Маркер (0,0) → EOF
  /// (возвращается [ChunkEofException]).
  Future<int> read(Uint8List b) async {
    if (b.isEmpty) return 0;
    for (;;) {
      final p = _pending;
      if (p != null) {
        final avail = p.length - _pendingOff;
        final n = avail < b.length ? avail : b.length;
        b.setRange(0, n, p, _pendingOff);
        _pendingOff += n;
        if (_pendingOff >= p.length) {
          _pending = null;
          _pendingOff = 0;
        }
        rxPayload += n;
        return n;
      }
      final r = reader;
      if (r == null) throw const StreamException_('кодек только на запись');
      final hdr = await r.readExact(frameHeaderSize);
      final pl = (hdr[0] << 8) | hdr[1];
      final pd = (hdr[2] << 8) | hdr[3];
      if (pl == 0 && pd == 0) {
        rxWire += frameHeaderSize;
        throw const ChunkEofException(); // graceful-маркер конца сессии
      }
      if (pl == 0 && pd > 0) {
        onPaddingOnly?.call(); // ACK ротации (или мусор — прозрачно)
      }
      if (pl > 0) {
        _pending = await r.readExact(pl);
        _pendingOff = 0;
      }
      if (pd > 0) {
        await r.skip(pd); // мусор сбрасываем без аллокаций
      }
      rxWire += frameHeaderSize + pl + pd;
    }
  }
}

/// Границы кадра, прочитанные из потока (для конвейера туннеля).
class FrameHeader {
  final int payloadLen;
  final int paddingLen;
  const FrameHeader(this.payloadLen, this.paddingLen);
}
