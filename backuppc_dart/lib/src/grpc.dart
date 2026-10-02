/// Несущий канал: gRPC-сообщения поверх HTTP/2-стрима
/// (Dart-порт `grpcMsgReader`/`grpcMsgWriter`).
///
/// Каждый кадр протокола упаковывается в одно gRPC-сообщение:
///
///     +-------------------+----------------------------------+
///     | grpc-префикс (5B) | кадр ТЗ [len][pad][payload][pad] |
///     | flag=0 len:4B BE  |                                  |
///     +-------------------+----------------------------------+
library;

import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';

const int grpcHdrLen = 5; // 1B флаг сжатия + 4B длина сообщения (BE)
const int grpcMaxFrame = 1 << 20; // страховочная граница (не достигается)

/// Писатель gRPC-сообщений в тело HTTP/2-запроса (upload-плечо).
class GrpcMessageWriter {
  final Future<void> Function(List<int> bytes) _write;
  bool _closed = false;
  GrpcMessageWriter(this._write);

  /// Кадр ТЗ → одно gRPC-сообщение (префикс + кадр, единым куском).
  Future<void> writeFrame(List<int> frame) async {
    if (_closed) throw const StreamException_('grpc writer закрыт');
    final n = frame.length;
    if (n > grpcMaxFrame) {
      throw const StreamException_('grpc: сообщение превышает лимит');
    }
    final msg = Uint8List(grpcHdrLen + n);
    msg[0] = 0; // без сжатия
    msg[1] = (n >> 24) & 0xFF;
    msg[2] = (n >> 16) & 0xFF;
    msg[3] = (n >> 8) & 0xFF;
    msg[4] = n & 0xFF;
    msg.setRange(grpcHdrLen, grpcHdrLen + n, frame);
    await _write(msg);
  }

  void close() => _closed = true;
}

/// Фидер байтов HTTP/2-DATA → синхронная очередь для readExact.
///
/// Правильно ждать данные через [Completer], созданный ДО ожидания
/// (иначе цикл чтения крутится вхолостую на микрозадачах).
class ByteFeeder {
  final _chunks = <Uint8List>[];
  int _off = 0;
  Completer<void>? _ready;
  bool _eof = false;
  Object? _error;
  int _backlogBytes = 0;

  /// Вызывается после каждого извлечения данных (для resume подписки).
  void Function()? onDrained;

  /// Буферизованные, но не прочитанные байты.
  int get backlogBytes => _backlogBytes;

  /// Суммарно выдано наружу байт (для различения «EOF на границе» и обрыва).
  int get consumed => _consumed;
  int _consumed = 0;

  /// DATA-фрейм от сервера.
  void add(List<int> bytes) {
    if (_eof || bytes.isEmpty) return;
    _chunks.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _backlogBytes += bytes.length;
    _signal();
  }

  /// END_STREAM / ошибка транспорта.
  void close([Object? error]) {
    _eof = true;
    _error = error;
    _signal();
  }

  void _signal() {
    final c = _ready;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  bool get isEof => _eof && _chunks.isEmpty;

  /// Читает до n байт БЕЗ копирования результата наружу: продвигает
  /// внутренний курсор, возвращает вид на остаток головного чанка
  /// (короткий lived-объект, валиден до следующего _take/readExact).
  Uint8List _take(int n) {
    if (_chunks.isEmpty || n <= 0) return Uint8List(0);
    final head = _chunks.first;
    final avail = head.length - _off;
    if (avail <= 0) {
      // защитная ветка: пустые головы не добавляются
      _chunks.removeAt(0);
      _off = 0;
      return Uint8List(0);
    }
    final take = avail < n ? avail : n;
    final view = Uint8List.sublistView(head, _off, _off + take);
    _off += take;
    _backlogBytes -= take;
    _consumed += take;
    if (_off >= head.length) {
      _chunks.removeAt(0);
      _off = 0;
    }
    if (_backlogBytes < _resumeLevel) {
      onDrained?.call();
    }
    return view;
  }

  static const int _resumeLevel = 2 << 20; // 2 МиБ — порог возобновления

  /// Пропускает n байт (сброс паддинга) без аллокаций.
  Future<void> skip(int n) async {
    var need = n;
    while (need > 0) {
      final piece = _take(need);
      if (piece.isNotEmpty) {
        need -= piece.length;
        continue;
      }
      if (_eof) {
        if (_error != null) throw StreamException_('$_error');
        throw const ChunkEofException();
      }
      final c = _ready ??= Completer<void>();
      await c.future;
      _ready = null;
    }
  }

  /// Читает ровно n байт; [ChunkEofException] при EOF до n байт.
  Future<Uint8List> readExact(int n) async {
    if (n <= 0) return Uint8List(0);
    final acc = BytesBuilder(copy: false);
    var need = n;
    while (need > 0) {
      final piece = _take(need);
      if (piece.isNotEmpty) {
        acc.add(piece);
        need -= piece.length;
        continue;
      }
      if (_eof) {
        if (_error != null) {
          throw StreamException_('$_error');
        }
        throw const ChunkEofException();
      }
      final c = _ready ??= Completer<void>();
      await c.future;
      _ready = null;
    }
    return acc.toBytes();
  }
}

/// Читатель gRPC-сообщений из тела HTTP/2-ответа (download-плечо).
/// Разбирает префикс [flag:1B][len:4B BE] и отдает payload сообщений
/// как байтовый поток для [FrameCodec].
///
/// EOF допускается ТОЛЬКО на границе сообщений (сервер гарантирует
/// END_STREAM по границе кадра): обрыв внутри сообщения — ошибка.
class GrpcMessageReader implements ChunkByteReader {
  final ByteFeeder _feeder;
  int _msgRemain = 0;

  GrpcMessageReader(this._feeder);

  Future<void> _nextMessage() async {
    if (_feeder.isEof) {
      throw const ChunkEofException(); // чистая граница
    }
    final before = _feeder.consumed;
    Uint8List hdr;
    try {
      hdr = await _feeder.readExact(grpcHdrLen);
    } on ChunkEofException {
      if (_feeder.consumed == before && _feeder.isEof) {
        // END_STREAM пришел ровно на границе сообщения (ротация)
        throw const ChunkEofException();
      }
      throw const StreamException_('grpc: обрыв внутри префикса сообщения');
    }
    if (hdr[0] != 0) {
      throw const StreamException_('grpc: флаг сжатия не поддерживается');
    }
    final len = (hdr[1] << 24) | (hdr[2] << 16) | (hdr[3] << 8) | hdr[4];
    if (len > grpcMaxFrame) {
      throw StreamException_(
        'grpc: сообщение $len байт превышает лимит $grpcMaxFrame',
      );
    }
    if (len == 0) {
      return _nextMessage(); // пустые сообщения пропускаем (как в Go)
    }
    _msgRemain = len;
  }

  @override
  Future<Uint8List> readExact(int n) async {
    if (n <= 0) return Uint8List(0);
    final acc = BytesBuilder(copy: false);
    var need = n;
    while (need > 0) {
      if (_msgRemain == 0) {
        await _nextMessage();
      }
      final take = need < _msgRemain ? need : _msgRemain;
      Uint8List piece;
      try {
        piece = await _feeder.readExact(take);
      } on ChunkEofException {
        throw const StreamException_('grpc: обрыв внутри сообщения');
      }
      acc.add(piece);
      need -= piece.length;
      _msgRemain -= piece.length;
    }
    return acc.toBytes();
  }

  @override
  Future<void> skip(int n) async {
    var need = n;
    while (need > 0) {
      if (_msgRemain == 0) {
        await _nextMessage();
      }
      final take = need < _msgRemain ? need : _msgRemain;
      try {
        await _feeder.skip(take);
      } on ChunkEofException {
        throw const StreamException_('grpc: обрыв внутри сообщения');
      }
      need -= take;
      _msgRemain -= take;
    }
  }
}
