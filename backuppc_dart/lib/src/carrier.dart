/// Несущий канал протокола: один «чанк» = выделенное TCP+TLS(ALPN h2)
/// соединение + один HTTP/2 POST-стрим с gRPC-фреймингом тела
/// (Dart-порт `client.go`/`tlsutil.go` из Go-библиотеки).
///
/// Заголовки каждого чанка (метаданные «бекапа»):
///   :method POST, :scheme https, :path <endpoint из пула>,
///   :authority <домен-донор>, content-type: application/grpc,
///   te: trailers, grpc-accept-encoding: identity,
///   user-agent: <пул BackupPC>, X-Backup-Session-ID / Chunk-Index / Auth.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http2/transport.dart';

import 'backuppc_profile.dart';
import 'config.dart';
import 'frame.dart';
import 'grpc.dart';

const Duration chunkDialTimeout = Duration(seconds: 10);
const Duration responseHeaderTimeout = Duration(seconds: 20);

/// X-Backup-Auth: hex(HMAC-SHA256(key=UUID 16B, msg="sid|index")).
String backupAuthHeader(Uint8List key, String sid, int index) {
  final mac = Hmac(sha256, key)
      .convert(utf8.encode('$sid|$index'))
      .toString();
  return mac;
}

/// Обёртка исходящего сокета: считает DATA-payload, фактически ушедший в
/// сеть (парсит h2-фреймы, пропуская префикс соединения). Дает писателю
/// сигнал реальной доставки для барьера ротации: сервер завершает старый
/// чанк при регистрации преемника и невостребованное тело отбрасывается
class WireCounterSink implements StreamSink<List<int>> {
  final Socket _socket;
  int dataBytes = 0; // сумма длин DATA-фреймов (payload)
  Uint8List _pending = Uint8List(0);
  bool _prefaceSkipped = false;

  WireCounterSink(this._socket);

  void _parse(List<int> data) {
    var buf = data is Uint8List ? data : Uint8List.fromList(data);
    if (_pending.isNotEmpty) {
      final merged = Uint8List(_pending.length + buf.length);
      merged.setAll(0, _pending);
      merged.setAll(_pending.length, buf);
      buf = merged;
      _pending = Uint8List(0);
    }
    var off = 0;
    if (!_prefaceSkipped) {
      const preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';
      if (buf.length >= 24) {
        final head = String.fromCharCodes(buf.sublist(0, 24));
        if (head == preface) {
          off = 24;
        }
        _prefaceSkipped = true;
      } else {
        // короче префикса — накопим
        _pending = Uint8List.fromList(buf);
        return;
      }
    }
    while (off + 9 <= buf.length) {
      final len = (buf[off] << 16) | (buf[off + 1] << 8) | buf[off + 2];
      final type = buf[off + 3];
      final total = 9 + len;
      if (off + total > buf.length) {
        _pending = Uint8List.sublistView(
          Uint8List.fromList(buf.sublist(off)),
        );
        return;
      }
      if (type == 0x0) {
        dataBytes += len; // DATA-фрейм (на соединении один стрим)
      }
      off += total;
    }
    if (off < buf.length) {
      _pending = Uint8List.fromList(buf.sublist(off));
    }
  }

  @override
  void add(List<int> data) {
    _socket.add(data);
    _parse(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _socket.addError(error, stackTrace);
  }

  @override
  Future addStream(Stream<List<int>> stream) => stream
      .map((data) {
        _parse(data);
        return data;
      })
      .pipe(_socket);

  @override
  Future get done => _socket.done;

  @override
  Future close() => _socket.close();
}

/// Прозрачная обертка входящего стрима: считает WINDOW_UPDATE нашего
/// стрима и изменения INITIAL_WINDOW_SIZE из SETTINGS — это потоковое
// подтверждение «сервер потребил N байт», на нем держится барьер записи.
class IncomingTee extends Stream<List<int>> {
  final Stream<List<int>> _source;
  final void Function(int delta, bool settings) _onWindow;
  StreamSubscription<List<int>>? _sub;
  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(
        sync: true,
        onPause: () => _sub?.pause(),
        onResume: () => _sub?.resume(),
        onCancel: () => _sub?.cancel(),
      );
  bool _started = false;
  Uint8List _pending = Uint8List(0);

  IncomingTee(this._source, this._onWindow);

  void _parse(List<int> data) {
    var buf = data is Uint8List ? data : Uint8List.fromList(data);
    if (_pending.isNotEmpty) {
      final merged = Uint8List(_pending.length + buf.length);
      merged.setAll(0, _pending);
      merged.setAll(_pending.length, buf);
      buf = merged;
      _pending = Uint8List(0);
    }
    var off = 0;
    while (off + 9 <= buf.length) {
      final len = (buf[off] << 16) | (buf[off + 1] << 8) | buf[off + 2];
      final type = buf[off + 3];
      final flags = buf[off + 4];
      final id = (buf[off + 5] & 0x7F) << 24 |
          (buf[off + 6] << 16) |
          (buf[off + 7] << 8) |
          buf[off + 8];
      final total = 9 + len;
      if (off + total > buf.length) {
        _pending = Uint8List.fromList(buf.sublist(off));
        return;
      }
      if (type == 0x8 && len == 4 && id != 0) {
        // WINDOW_UPDATE нашего стрима: дельта потребления
        var delta = (buf[off + 9] << 24) |
            (buf[off + 10] << 16) |
            (buf[off + 11] << 8) |
            buf[off + 12];
        delta &= 0x7FFFFFFF;
        _onWindow(delta, false);
      } else if (type == 0x4 && (flags & 0x1) == 0) {
        // SETTINGS (не ACK): INITIAL_WINDOW_SIZE меняет базу окна
        var p = off + 9;
        while (p + 6 <= off + total) {
          final settingId = (buf[p] << 8) | buf[p + 1];
          final value = (buf[p + 2] << 24) |
              (buf[p + 3] << 16) |
              (buf[p + 4] << 8) |
              buf[p + 5];
          if (settingId == 0x4) {
            _onWindow(value, true);
          }
          p += 6;
        }
      }
      off += total;
    }
    if (off < buf.length) {
      _pending = Uint8List.fromList(buf.sublist(off));
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (!_started) {
      _started = true;
      _sub = _source.listen(
        (data) {
          _parse(data);
          _controller.add(data);
        },
        onError: (Object e, StackTrace s) => _controller.addError(e, s),
        onDone: () => _controller.close(),
      );
    }
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// Настройки TLS-клиента (пиннинг > insecure > обычная верификация).
class CarrierTls {
  final String certFingerprint; // hex sha256 листа (пиннинг)
  final bool insecure;

  const CarrierTls({this.certFingerprint = '', this.insecure = false});

  /// Настройки из [ClientConfig] (пиннинг приоритетнее insecure).
  factory CarrierTls.fromConfig(ClientConfig cfg) => CarrierTls(
        certFingerprint: cfg.certFingerprint,
        insecure: cfg.insecure,
      );
}

/// Установленное соединение чанка: писать в тело запроса, читать ответ.
class ChunkConnection {
  final ClientTransportConnection connection;
  final ClientTransportStream stream;
  final SecureSocket socket;
  final ByteFeeder feeder;
  final GrpcMessageWriter writer;
  final GrpcMessageReader reader;
  final Future<void> responseHeaders; // завершается после валидации :status

  bool _retired = false;
  bool writeClosed = false;
  ChunkConnection? next; // цепочка ротации читателя
  final int index;
  final void Function(String line)? log;
  int _unflushed = 0;
  final WireCounterSink _wire;

  ChunkConnection._({
    required this.connection,
    required this.stream,
    required this.socket,
    required this.feeder,
    required this.writer,
    required this.reader,
    required this.responseHeaders,
    required this.index,
    required WireCounterSink wire,
    this.log,
  }) : _wire = wire;

  /// Учет байт, отданных в сокет с последнего flush (backpressure писателя).
  int accountPending(int n) => _unflushed += n;

  /// Дождаться, пока буферы записи отданы ОС (синхронизация с доставкой).
  Future<void> flushSocket() async {
    _unflushed = 0;
    try {
      await socket.flush();
    } catch (_) {
      // сокет мог закрыться — ошибка всплывет при следующей записи
    }
  }

  /// END_STREAM тела запроса (закрыть upload-плечо без EOF-маркера).
  Future<void> endStream() async {
    if (writeClosed) return;
    writeClosed = true;
    writer.close();
    try {
      await stream.outgoingMessages.close();
    } catch (_) {}
  }

  /// Диагностика (только для отладки инструментария).
  void debugTeardown(String reason) {
    log?.call('chunk $index teardown: $reason');
  }

  /// Байты gRPC-сообщений, поставленные в очередь исходящего стрима.
  int appBytes = 0;

  /// Подтвержденное сервером окно потребления (base + WINDOW_UPDATE).
  int _windowBase = 65535;
  int _windowExtra = 0;
  Completer<void>? _windowSignal;

  /// Подтвержденное сервером потребление (Σ WINDOW_UPDATE).
  int get confirmedBytes => _windowExtra;

  /// Отправлено, но не подтверждено потреблением (в полете/в очереди).
  int get inflightBytes => appBytes - _windowExtra;

  /// Вызывается из [IncomingTee] при WINDOW_UPDATE / SETTINGS.
  void onWindowUpdate(int deltaOrBase, bool settings) {
    if (settings) {
      // SETTINGS_INITIAL_WINDOW_SIZE меняет БАЗУ окна потока;
      // дельта уже отражена в новом значении — extra не трогаем
      // (иначе двойной счет: окно завышается и барьер ротации
      // отпускает непотребленный хвост).
      _windowBase = deltaOrBase;
    } else {
      _windowExtra += deltaOrBase;
    }
    final s = _windowSignal;
    if (s != null && !s.isCompleted) {
      s.complete();
    }
  }

  /// Сколько байт сервер ещё не подтвердил потреблением (legacy-вид,
  /// семантика: остаток ёмкости окна с обратным знаком).
  int get unackedBytes => appBytes - (_windowBase + _windowExtra);

  /// Клентский флоу-контроль как в Go: не отправлять больше
  /// [_windowBudget] неподтвержденных байт — тогда хвост ротации
  /// гарантированно мал (сервер добивает его до регистрации преемника).
  Future<void> awaitWindow({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    await _waitInflightBelow(_windowBudget, timeout, soft: false);
  }

  /// Барьер ротации: дождаться, пока сервер ПОДТВЕРДИТ потребление
  /// upload-плеча (inflight → 0: Σ WINDOW_UPDATE = отправленному).
  /// Сервер при регистрации преемника RST-ит недочитанное тело старого
  /// запроса — хвост обязан быть потреблен ДО диала.
  /// Чистое скачивание: upload пуст → мгновенно.
  /// Таймаут мягкий и короткий: батчинг WINDOW_UPDATE у Go-сервера
  /// оставляет хвост без подтверждения — долгое ожидание бессмысленно.
  Future<void> awaitQuiesced({
    Duration timeout = const Duration(milliseconds: 250),
  }) async {
    await _waitInflightBelow(0, timeout, soft: true);
  }

  Future<void> _waitInflightBelow(
    int budget,
    Duration timeout, {
    required bool soft,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (inflightBytes > budget) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) {
        if (soft) return;
        throw const StreamException_('окно записи исчерпано (сервер молчит)');
      }
      final s = _windowSignal ??= Completer<void>();
      try {
        await s.future.timeout(left);
      } on TimeoutException {
        _windowSignal = null;
        if (soft) return;
        if (DateTime.now().isAfter(deadline)) {
          throw const StreamException_('окно записи исчерпано (сервер молчит)');
        }
        continue;
      }
      _windowSignal = null;
    }
  }

  /// Допустимый неподтвержденный задел записи (скорость): барьер
  /// ротации — [awaitQuiesced] перед диалом преемника.
  static const int _windowBudget = 2 << 20; // 2 МиБ

  /// Дождаться, пока все поставленные байты ушли в сокет (DATA-фреймы).
  /// Инвариант ротации: тело старого чанка должно быть доставлено ДО
  /// регистрации преемника на сервере (иначе хвост отбрасывается RST).
  Future<void> drainWire({Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_wire.dataBytes < appBytes) {
      if (DateTime.now().isAfter(deadline)) {
        return; // мягкий выход: сервер сам обработает хвост через handoff
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await flushSocket();
  }

  /// Жесткое закрытие всего соединения чанка (RST/GOAWAY).
  void destroy() {
    if (_retired) return;
    _retired = true;
    debugTeardown('destroy');
    feeder.close(StateError('chunk destroyed'));
    try {
      stream.terminate();
    } catch (_) {}
    unawaited(connection.terminate().catchError((_) {}));
    socket.destroy();
  }

  /// Отставка чанка: соединение закрывается через задержку (дать
  /// END_STREAM покинуть буферы — как retireTransportDelay в Go).
  void retire([Duration delay = const Duration(seconds: 3)]) {
    if (_retired) return;
    _retired = true;
    debugTeardown('retire(+${delay.inSeconds}s)');
    Timer(delay, () {
      try {
        unawaited(connection.finish().catchError((_) {}));
      } catch (_) {}
      socket.destroy();
    });
  }

  bool get retired => _retired;

  /// Диагностика (только для отладки инструментария).
  Map<String, dynamic> debugState() => {
        'index': index,
        'appBytes': appBytes,
        'wireBytes': _wire.dataBytes,
        'unacked': unackedBytes,
        'windowBase': _windowBase,
        'windowExtra': _windowExtra,
        'writeClosed': writeClosed,
        'retired': _retired,
      };

  /// Диал нового чанка: TCP → TLS (ALPN h2) → HTTP/2 → POST-стрим.
  /// Первый gRPC-запрос (VLESS для чанка 0) можно писать сразу —
  /// ответные заголовки ждутся отдельно через [ChunkConnection.responseHeaders].
  static Future<ChunkConnection> dial({
    required ClientConfig cfg,
    required Uint8List uuid,
    required String sessionID,
    required int index,
    CarrierTls tls = const CarrierTls(),
    void Function(String)? log,
  }) async {
    final (host, port) = cfg.splitServerAddr();
    if (host.isEmpty || port <= 0) {
      throw const StreamException_('carrier: некорректный serverAddr');
    }
    final transport = cfg.transport;
    final path = transport.randomEndpoint();
    final authorityHost = transport.host.trim().isNotEmpty
        ? transport.host.trim()
        : host;
    final ua = transport.userAgent.trim().isNotEmpty
        ? transport.userAgent.trim()
        : pickBackupPCUserAgent();

    final headers = [
      Header.ascii(':method', 'POST'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':path', path),
      Header.ascii(':authority', authorityHost),
      Header.ascii('content-type', 'application/grpc'),
      Header.ascii('te', 'trailers'),
      Header.ascii('grpc-accept-encoding', 'identity'),
      Header.ascii('user-agent', ua),
      Header.ascii('x-backup-session-id', sessionID),
      Header.ascii('x-backup-chunk-index', '$index'),
      Header.ascii(
        'x-backup-auth',
        backupAuthHeader(uuid, sessionID, index),
      ),
    ];

    // --- TCP ---
    final raw = await Socket.connect(
      host,
      port,
      timeout: chunkDialTimeout,
    );
    // tcpNoDelay намеренно НЕ включаем: A/B-замеры показали, что Nagle
    // улучшает цикл WINDOW_UPDATE/TLS-записей (6.6 против 0.8 МиБ/с)
    // --- TLS: предлагаем только h2 — либо ALPN согласует h2, либо отказ ---
    SecureSocket secure;
    try {
      secure = await SecureSocket.secure(
        raw,
        host: authorityHost,
        context: _tlsContext(tls),
        onBadCertificate: _onBadCertificate(tls),
        supportedProtocols: const ['h2'],
      );
    } catch (error) {
      raw.destroy();
      rethrow;
    }
    if (secure.selectedProtocol case final alpn? when alpn != 'h2') {
      secure.destroy();
      throw StreamException_(
        'carrier: сервер согласовал ALPN "$alpn" вместо h2',
      );
    }
    // selectedProtocol == null → prior-knowledge h2 (строгий ALPN
    // согласуется настоящим Go-сервером; Dart-фальшивый сервер его
    // не рекламирует, но говорит по h2)

    // --- HTTP/2 ---
    late final ChunkConnection conn;
    final wire = WireCounterSink(secure);
    final incoming = IncomingTee(secure, (delta, settings) {
      conn.onWindowUpdate(delta, settings);
    });
    final connection = ClientTransportConnection.viaStreams(
      incoming,
      wire,
      settings: const ClientSettings(streamWindowSize: 1 << 20),
    );
    final stream = connection.makeRequest(headers, endStream: false);

    final feeder = ByteFeeder();
    final headersCompleter = Completer<void>();
    var gotHeaders = false;
    StreamSubscription<StreamMessage>? incomingSub;
    String? headerError;

    String headerValue(List<Header> list, String name) {
      for (final h in list) {
        if (utf8.decode(h.name) == name) {
          return utf8.decode(h.value);
        }
      }
      return '';
    }

    incomingSub = stream.incomingMessages.listen(
      (msg) {
        if (msg is HeadersStreamMessage) {
          if (!gotHeaders) {
            gotHeaders = true;
            final status = headerValue(msg.headers, ':status');
            if (status != '200') {
              headerError = 'carrier: HTTP $status от чанка $index';
              feeder.close(StreamException_(headerError!));
              headersCompleter.completeError(
                StreamException_(headerError!),
              );
              return;
            }
            final ct = headerValue(msg.headers, 'content-type');
            if (ct.isNotEmpty &&
                !ct.toLowerCase().startsWith('application/grpc')) {
              headerError = 'carrier: неожиданный content-type "$ct"';
              feeder.close(StreamException_(headerError!));
              headersCompleter.completeError(
                StreamException_(headerError!),
              );
              return;
            }
            if (!headersCompleter.isCompleted) {
              headersCompleter.complete();
            }
          }
          // трейлеры (grpc-status, X-Backup-Status) не разбираем —
          // читаем тело до END_STREAM, как Go-клиент
        } else if (msg is DataStreamMessage) {
          feeder.add(msg.bytes);
          if (feeder.backlogBytes > _pauseBacklog) {
            incomingSub?.pause();
          }
        }
      },
      onError: (Object error) {
        log?.call('chunk $index: incoming error: $error');
        feeder.close(error);
        if (!headersCompleter.isCompleted) {
          headersCompleter.completeError(error);
        }
      },
      onDone: () {
        feeder.close();
        if (!headersCompleter.isCompleted) {
          headersCompleter.completeError(
            const ChunkEofException(),
          );
        }
      },
    );
    stream.onTerminated = (code) {
      log?.call('chunk $index: stream terminated (code=$code)');
    };
    feeder.onDrained = () {
      if (feeder.backlogBytes < _resumeBacklog) {
        incomingSub?.resume();
      }
    };

    final responseHeaders = headersCompleter.future.timeout(
      responseHeaderTimeout,
      onTimeout: () {
        throw StreamException_(
          'carrier: нет заголовков ответа за '
          '${responseHeaderTimeout.inSeconds}s (чанк $index)',
        );
      },
    );

    log?.call('chunk $index: POST $path ($ua)');

    conn = ChunkConnection._(
      connection: connection,
      stream: stream,
      socket: secure,
      feeder: feeder,
      writer: GrpcMessageWriter((bytes) async {
        // Возвращает OK когда сообщение поставлено в очередь HTTP/2;
        // фактическая отправка ограничена окном флоу-контроля сервера,
        // барьер ротации — [ChunkConnection.drainWire].
        conn.appBytes += bytes.length;
        stream.sendData(bytes);
      }),
      reader: GrpcMessageReader(feeder),
      responseHeaders: responseHeaders,
      index: index,
      wire: wire,
      log: log,
    );
    return conn;
  }

  static const int _pauseBacklog = 8 << 20; // 8 МиБ
  static const int _resumeBacklog = 2 << 20; // 2 МиБ

  static SecurityContext? _tlsContext(CarrierTls tls) {
    if (tls.certFingerprint.isNotEmpty) {
      // Пустое хранилище корней: верификация всегда «падает» и решение
      // принимает пиннинг в onBadCertificate — как VerifyPeerCertificate в Go.
      return SecurityContext(withTrustedRoots: false);
    }
    return null;
  }

  static bool Function(X509Certificate)? _onBadCertificate(CarrierTls tls) {
    if (tls.certFingerprint.isNotEmpty) {
      final expected = tls.certFingerprint.toLowerCase();
      return (cert) {
        final actual = sha256.convert(cert.der).toString();
        return actual == expected;
      };
    }
    if (tls.insecure) {
      return (_) => true;
    }
    return null;
  }
}
