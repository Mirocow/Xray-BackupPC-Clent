/// Логическое соединение поверх цепочки чанков (Dart-порт `hub.go`).
///
/// Одно соединение = одна VLESS-сессия = идентификатор «задания бекапа».
/// Данные льются через чанки; чанк меняется при превышении лимита
/// байт/времени (ТЗ 3.4), при этом:
///   * END_STREAM старого чанка отправляется ДО диала нового;
///   * читатель переходит на преемника по цепочке `next`, переживая
///     состояние частично прочитанного кадра (EOF сервера всегда
///     на границе кадра);
///   * WritePadding после HalfClose — no-op до следующей ротации.
library;

import 'dart:async';
import 'dart:typed_data';

import 'backuppc_profile.dart';
import 'carrier.dart';
import 'config.dart';
import 'frame.dart';
import 'random.dart';
import 'vless.dart';

const Duration nextChunkWait = Duration(seconds: 2);
const Duration rotationCooldown = Duration(seconds: 2);

/// Метрики одной логической сессии (агрегируются клиентом на закрытии).
class SessionMetrics {
  int chunks = 0;
  int rotations = 0;
  int txPayload = 0;
  int rxPayload = 0;
  int txFake = 0;
  int fakeJobs = 0;
  int fakeJobBytes = 0;
  SessionMetrics();
}

/// Логическое соединение: VLESS поверх эмулируемого потока бекапов.
class BackupPcLogicalConn implements ChunkByteReader {
  final ClientConfig cfg;
  final Uint8List uuid;
  final String sessionID;
  final CarrierTls tls;
  final void Function(String line)? log;

  /// Mesh-extension (v1.4-mesh): HTTP/2 headers для peer-to-peer routing.
  /// Применяются ко всем чанкам logical session (включая ротации).
  /// См. docs/PROTOCOL.md §11.1.
  final List<(String, String)>? meshHeaders;

  final SessionMetrics metrics = SessionMetrics();

  final List<ChunkConnection> _chunks = [];
  ChunkConnection? _writeCur;
  ChunkConnection? _readCur;
  int _chunkBytes = 0; // payload обоих направлений текущего чанка
  DateTime _deadline = DateTime.now();
  int _index = 0;

  bool _uploadClosed = false;
  bool _writeDone = false;
  bool _closed = false;
  DateTime? _rotFailAt;
  Future<void>? _rotating; // single-flight ВНУТРЕННЕЙ ротации (без гейта)
  DateTime _lastPayloadAt = DateTime.now();

  /// FIFO-сериализация всего пути записи (как write-мьютекс в Go):
  /// проверка лимитов → ротация → кадры — атомарно относительно
  /// пингов, балансировщика, релея и читательской ротации.
  Future<void> _writeGate = Future<void>.value();

  late final FrameCodec _wcodec;
  late final FrameCodec _rcodec;

  final List<Future<void>> _tasks = [];
  bool _tasksRunning = false;

  BackupPcLogicalConn._({
    required this.cfg,
    required this.uuid,
    required this.sessionID,
    required this.tls,
    required ChunkConnection first,
    this.log,
    this.meshHeaders,
  }) {
    _chunks.add(first);
    _writeCur = first;
    _readCur = first;
    _index = 0;
    _deadline = _freshDeadline();
    metrics.chunks = 1;
    _wcodec = FrameCodec.forWriting(_writeRawFrame, cfg.transport);
    _rcodec = FrameCodec.forReading(this, cfg.transport);
  }

  /// Устанавливает логическую сессию: чанк 0 + VLESS-запрос + ответ.
  static Future<BackupPcLogicalConn> dial({
    required ClientConfig cfg,
    required Uint8List uuid,
    required String address,
    required int port,
    CarrierTls? tls,
    void Function(String line)? log,
    /// Mesh-extension (v1.4-mesh, additive): optional extra HTTP/2 headers
    /// для peer-to-peer routing. Прокидывается в ChunkConnection.dial.
    /// См. docs/PROTOCOL.md §11.1.
    List<(String, String)>? meshHeaders,
  }) async {
    final sessionID = newBackupPCSessionID();
    final effectiveTls = tls ?? CarrierTls.fromConfig(cfg);
    log?.call('dial: session $sessionID → ${cfg.serverAddr}');
    ChunkConnection? first;
    Object? lastError;
    for (var attempt = 1; attempt <= cfg.transport.dialRetries; attempt++) {
      try {
        // Только транспорт (TCP+TLS+h2+HEADERS). Сервер читает VLESS
        // ДО записи ответа 200 (валидный хендшейк = 200), поэтому тело
        // запроса отправляется немедленно — как io.Pipe в Go-клиенте.
        first = await ChunkConnection.dial(
          cfg: cfg,
          uuid: uuid,
          sessionID: sessionID,
          index: 0,
          tls: effectiveTls,
          log: log,
          extraHeaders: meshHeaders,
        );
        break;
      } catch (error) {
        lastError = error;
        first?.destroy();
        first = null;
        if (attempt < cfg.transport.dialRetries) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * attempt),
          );
        }
      }
    }
    if (first == null) {
      throw StreamException_('dial: чанк 0 не установлен: $lastError');
    }
    final conn = BackupPcLogicalConn._(
      cfg: cfg,
      uuid: uuid,
      sessionID: sessionID,
      tls: effectiveTls,
      first: first,
      log: log,
      meshHeaders: meshHeaders,
    );
    try {
      // первый payload чанка 0 — запрос VLESS: уходит ДО ожидания
      // заголовков ответа (HTTP/2 разрешает тело запроса раньше ответа;
      // сервер валидирует VLESS и только потом пишет 200)
      final vless = buildVlessRequest(uuid, address, port);
      await conn._wcodec.write(vless);
      conn.metrics.txPayload += vless.length;
      conn._chunkBytes += vless.length;
      await first.responseHeaders;
      // ответ VLESS: [version=0][addons len] через кадровый кодек
      final hdr = Uint8List(2);
      var got = 0;
      while (got < 2) {
        final n = await conn._rcodec.read(Uint8List.sublistView(hdr, got));
        if (n <= 0) {
          throw const StreamException_(
            'vless: пустый ответ сервера (сессия отклонена?)',
          );
        }
        got += n;
      }
      if (hdr[0] != vlessVersion) {
        throw StreamException_('vless: неожиданная версия ${hdr[0]}');
      }
    } catch (error) {
      await conn.close();
      rethrow;
    }
    conn._spawnTasks();
    return conn;
  }

  Future<T> _withWritePath<T>(Future<T> Function() fn) {
    final task = _writeGate.then((_) => fn());
    _writeGate = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  // ================= запись =================

  /// Запись полезной нагрузки (кадрирование + случайный паддинг).
  /// Большие буферы режутся на кадры до maxWriteChunk байт.
  Future<int> write(List<int> b) => _withWritePath(() async {
        _throwIfClosed();
        if (_uploadClosed) {
          throw const StreamException_('upload-плечо уже закрыто');
        }
        await _ensureWritable();
        final n = await _wcodec.write(b);
        metrics.txPayload += n;
        _chunkBytes += n;
        _lastPayloadAt = DateTime.now();
        return n;
      });

  /// Padding-only кадры: пинги (ТЗ 3.2), фейковый аплоад (ТЗ 4.2),
  /// псевдо-бэкапы (раздел 4). После HalfClose — no-op до ротации.
  Future<int> writePadding(int n) => _withWritePath(() async {
        if (_closed) return 0;
        if (_uploadClosed || _writeCur == null) return 0;
        try {
          await _ensureWritable();
        } on Exception {
          return 0; // ротация не удалась — пинг не должен рвать сессию
        }
        final w = await _wcodec.writePadding(n).catchError((_) => 0);
        metrics.txFake += w;
        return w;
      });

  /// Graceful-конец upload-плеча: кадр (0,0) + END_STREAM тела запроса.
  /// Download продолжает работать до EOF сервера. Если сервер уже закрыл
  /// стрим (RST после завершения сессии) — тихо завершаем локальную запись.
  Future<void> halfClose() => _withWritePath(() async {
        if (_closed || _writeDone) return;
        _writeDone = true;
        try {
          await _wcodec.writeEof();
        } catch (_) {
          // канал уже закрыт — маркер доставлять некуда, это не ошибка сессии
        } finally {
          _uploadClosed = true;
          await _writeCur?.endStream();
        }
      });

  Future<void> _writeRawFrame(List<int> frame) async {
    final cur = _writeCur;
    if (cur == null || cur.writeClosed) {
      throw const StreamException_('чанк закрыт для записи');
    }
    await cur.writer.writeFrame(frame);
    await cur.awaitWindow();
    // Писатель не должен забегать вперёд доставки: сервер завершает
    // старый чанк при регистрации преемника и невостребованное тело
    // отбрасывается (RST NO_ERROR). Периодический flush синхронизирует
    // очередь с фактической доставкой — как окно флоу-контроля в Go.
    if (cur.accountPending(frame.length) > _flushBatch) {
      await cur.flushSocket();
    }
  }

  static const int _flushBatch = 128 * 1024;

  // ================= чтение (переключающийся читатель) =================

  /// Читает payload в буфер b (до b.length). Возвращает 0 при EOF
  /// логической сессии (как io.EOF в Go-эталоне).
  Future<int> read(Uint8List b) async {
    _throwIfClosed();
    int n;
    try {
      n = await _rcodec.read(b);
    } on ChunkEofException {
      return 0;
    }
    if (n > 0) {
      metrics.rxPayload += n;
      _chunkBytes += n;
      _lastPayloadAt = DateTime.now();
      _maybeRotateFromReader();
    }
    return n;
  }

  @override
  Future<Uint8List> readExact(int n) async {
    for (;;) {
      final cur = _readCur;
      if (cur == null || _closed) {
        throw const ChunkEofException();
      }
      try {
        return await cur.reader.readExact(n);
      } on ChunkEofException {
        final next = await _waitForSuccessor(cur);
        if (next == null) {
          _readCur = null;
          throw const ChunkEofException();
        }
        _readCur = next;
        cur.retire(); // соединение старого чанка закроется через 3 с
      }
    }
  }

  @override
  Future<void> skip(int n) async {
    for (;;) {
      final cur = _readCur;
      if (cur == null || _closed) {
        throw const ChunkEofException();
      }
      try {
        return await cur.reader.skip(n);
      } on ChunkEofException {
        final next = await _waitForSuccessor(cur);
        if (next == null) {
          _readCur = null;
          throw const ChunkEofException();
        }
        _readCur = next;
        cur.retire();
      }
    }
  }

  /// Ожидание преемника до [nextChunkWait] (ротация может опоздать).
  Future<ChunkConnection?> _waitForSuccessor(ChunkConnection cur) async {
    final next = cur.next;
    if (next != null) return next;
    final until = DateTime.now().add(nextChunkWait);
    while (!_closed && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final n2 = cur.next;
      if (n2 != null) return n2;
    }
    return cur.next;
  }

  // ================= ротация (ТЗ 3.4) =================

  /// Проверка лимитов чанка перед записью. Вызывается ТОЛЬКО при
  /// удержании write-gate; ротация регистрируется как внутренняя
  /// (без взятия гейта повторно).
  Future<void> _ensureWritable() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final inflight = _rotating;
      if (inflight != null) {
        await inflight.catchError((_) {});
        continue;
      }
      final cur = _writeCur;
      if (cur == null) {
        throw const StreamException_('нет активного чанка (ротация провалилась)');
      }
      if (_chunkBytes >= cfg.transport.maxSessionBytes ||
          DateTime.now().isAfter(_deadline)) {
        await _rotateInner();
        continue;
      }
      return;
    }
    throw const StreamException_('ротация не завершилась за отведенные попытки');
  }

  /// Ротация читателем (чистое скачивание после HalfClose): в фоне через
  /// write-gate, ошибка не рвет сессию, cooldown [rotationCooldown].
  void _maybeRotateFromReader() {
    if (_closed) return;
    if (_chunkBytes < cfg.transport.maxSessionBytes &&
        DateTime.now().isBefore(_deadline)) {
      return;
    }
    if (_rotating != null) return;
    final fail = _rotFailAt;
    if (fail != null && DateTime.now().difference(fail) < rotationCooldown) {
      return;
    }
    unawaited(
      _rotate().catchError((Object error) {
        _rotFailAt = DateTime.now();
        log?.call('rotation(reader): $error');
      }),
    );
  }

  /// Внешний вход ротации (фон/читатель): берет write-gate.
  Future<void> _rotate() => _withWritePath(_rotateInner);

  /// Single-flight внутренняя ротация — вызывается ТОЛЬКО под write-gate.
  Future<void> _rotateInner() {
    final existing = _rotating;
    if (existing != null) return existing;
    final task = _rotateNow().whenComplete(() => _rotating = null);
    _rotating = task;
    return task;
  }

  Future<void> _rotateNow() async {
    _throwIfClosed();
    // Порядок строго как в Go-эталоне (hub.go rotate()):
    //  1. END_STREAM старого чанка — серверный pump переходит в режим
    //     эстафеты (RotationHandoff) и продолжает отдавать download-очередь;
    //  2. НЕМЕДЛЕННЫЙ диал преемника (никаких ожиданий — задержка здесь
    //     означает рост чанка за лимитом и потерю хвоста при teardown);
    //  3. писатель переключается немедленно, читатель — по EOF старого.
    // Хвост upload-плеча ограничен окном записи (awaitWindow 2 МиБ) —
    // сервер добивает его в течение retire-задержки 3 с.
    final old = _writeCur;
    if (old != null && !old.writeClosed) {
      await old.endStream();
      // Барьер: сервер подтверждает потребление upload-хвоста
      // (WINDOW_UPDATE) ДО диала преемника — иначе http2 сервера RST-ят
      // недочитанное тело при регистрации преемника (потеря хвоста).
      // Чистое скачивание: unacked = 0 → мгновенно.
      await old.awaitQuiesced();
    }
    // 2. диал преемника с ретраями (0.3с × попытка)
    Object? lastError;
    for (var attempt = 1; attempt <= cfg.transport.dialRetries; attempt++) {
      if (_closed) {
        throw const StreamException_('сессия закрыта');
      }
      ChunkConnection? fresh;
      try {
        fresh = await ChunkConnection.dial(
          cfg: cfg,
          uuid: uuid,
          sessionID: sessionID,
          index: _index + 1,
          tls: tls,
          log: log,
          extraHeaders: meshHeaders,
        );
        await fresh.responseHeaders;
        metrics.chunks += 1;
        metrics.rotations += 1;
        final tail = _chunks.isEmpty ? null : _chunks.last;
        if (tail != null && tail.next == null) {
          tail.next = fresh; // цепочка читателя
        }
        _chunks.add(fresh);
        _readCur ??= fresh;
        _index += 1;
        _writeCur = fresh;
        _uploadClosed = false;
        _chunkBytes = 0;
        _deadline = _freshDeadline();
        log?.call('rotated to chunk $_index (${metrics.rotations})');
        return;
      } catch (error) {
        lastError = error;
        fresh?.destroy();
        if (attempt < cfg.transport.dialRetries) {
          await Future<void>.delayed(
            Duration(milliseconds: 300 * attempt),
          );
        }
      }
    }
    _writeCur = null;
    throw StreamException_('ротация не удалась: $lastError');
  }

  DateTime _freshDeadline() {
    final base = cfg.transport.maxSessionDuration.value;
    final min = base * 0.5;
    return DateTime.now().add(randDurationRange(min, base * 1.5));
  }

  // ================= фоновые задачи (ТЗ 3.2/4.1/4.2, раздел 4) =================

  void _spawnTasks() {
    if (_tasksRunning) return;
    _tasksRunning = true;
    _tasks.add(_jitterPingLoop());
    _tasks.add(_trafficBalancerLoop());
    _tasks.add(_fakeBackupJobsLoop());
  }

  /// Джиттер-пинги: base 20с + равномерный джиттер ±15с (клэмп ≥ 0),
  /// размер паддинга 16–64 байта.
  Future<void> _jitterPingLoop() async {
    while (!_closed) {
      final jitter = randDurationRange(
        -cfg.transport.pingJitterMax.value,
        cfg.transport.pingJitterMax.value,
      );
      var delay = cfg.transport.pingBaseInterval.value + jitter;
      if (delay < Duration.zero) delay = Duration.zero;
      await Future<void>.delayed(delay);
      if (_closed) break;
      final size = randIntRange(16, 64);
      final w = await writePadding(size);
      if (w == 0 && _closed) return; // сессия закрыта — выходим
    }
  }

  /// Балансировка асимметрии (ТЗ 4.2): каждые 5с; если скачивание идет,
  /// а аплоад ниже порога — инжект фейкового аплоада (512 КиБ по умолчанию).
  Future<void> _trafficBalancerLoop() async {
    final interval = cfg.transport.balancingInterval.value;
    final inject = cfg.transport.fakeUploadChunk;
    if (interval <= Duration.zero || inject <= 0) return;
    var lastRx = metrics.rxPayload;
    var lastTx = metrics.txPayload;
    while (!_closed) {
      await Future<void>.delayed(interval);
      if (_closed) break;
      final dRx = metrics.rxPayload - lastRx;
      final dTx = metrics.txPayload - lastTx;
      lastRx = metrics.rxPayload;
      lastTx = metrics.txPayload;
      if (dRx > 0 && dTx < cfg.transport.minTxThreshold) {
        await writePadding(inject); // уже учитывает txFake
      }
    }
  }

  /// Псевдо-задания бекапов (раздел 4): инкременты 25м±40% на 2–8 МиБ,
  /// ночью (22–06) полные 8ч±40% на 32–128 МиБ, всплески 16–120 КиБ
  /// с паузами 30–300 мс; idleOnly — не мешать пользовательскому трафику.
  Future<void> _fakeBackupJobsLoop() async {
    final bc = cfg.transport.backuppc;
    if (!bc.enabledOn) return;
    while (!_closed) {
      final plan = backuppcNextJob(bc, DateTime.now());
      await Future<void>.delayed(plan.delay);
      if (_closed) break;
      if (bc.idleOnly &&
          DateTime.now().difference(_lastPayloadAt) <
              const Duration(seconds: 10)) {
        continue; // пользовательский трафик — откладываем
      }
      await _runFakeBackup(plan.kind, plan.bytes);
      if (_closed) break;
    }
  }

  Future<void> _runFakeBackup(BackupJobKind kind, int total) async {
    final bursts = planBackupBursts(total);
    log?.call(
      'fake ${jobKindName(kind)} ${formatBackupBytes(total)} '
      '(${bursts.length} всплесков)',
    );
    for (final burst in bursts) {
      if (_closed) return;
      await Future<void>.delayed(burst.gap);
      if (_closed) return;
      final w = await writePadding(burst.size);
      if (w > 0) {
        metrics.fakeJobBytes += w;
      }
    }
    metrics.fakeJobs += 1;
  }

  // ================= закрытие =================

  /// Полное закрытие: EOF-маркер (если upload открыт), END_STREAM,
  /// разрушение всех чанков, остановка фоновых задач, метрики.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_writeDone) {
      _writeDone = true;
      try {
        await _wcodec.writeEof();
      } catch (_) {}
      try {
        await _writeCur?.endStream();
      } catch (_) {}
    }
    _uploadClosed = true;
    for (final chunk in _chunks) {
      chunk.destroy();
    }
    log?.call(
      'closed $sessionID: chunks=${metrics.chunks} '
      'rotations=${metrics.rotations} tx=${metrics.txPayload} '
      'rx=${metrics.rxPayload} fake=${metrics.txFake}',
    );
  }

  void _throwIfClosed() {
    if (_closed) {
      throw const StreamException_('сессия закрыта');
    }
  }

  bool get closed => _closed;

  /// Диагностика ротации/потока (только для отладки инструментария).
  Map<String, dynamic> debugState() => {
        'closed': _closed,
        'chunkBytes': _chunkBytes,
        'index': _index,
        'chunks': metrics.chunks,
        'rotations': metrics.rotations,
        'writeCur': _writeCur?.debugState(),
        'readCur': _readCur?.debugState(),
        'rotating': _rotating != null,
      };
}
