// Микробенчмарк слоёв: (1) голый TLS-сокет, (2) http2 package.
// Запускается: dart run tool/layer_bench.dart --mode tls|h2 --mib 256
library;

import 'dart:async';
import 'dart:io';


import 'package:http2/transport.dart';

Future<void> main(List<String> args) async {
  var mode = 'tls';
  var mib = 256;
  var port = 18601;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--mode':
        mode = args[++i];
      case '--mib':
        mib = int.parse(args[++i]);
      case '--port':
        port = int.parse(args[++i]);
    }
  }
  final n = mib * 1024 * 1024;
  final sw = Stopwatch()..start();
  int got = 0;
  if (mode == 'plain') {
    final sock = await Socket.connect('127.0.0.1', port);
    final completer = Completer<void>();
    late final StreamSubscription sub;
    sub = sock.listen((data) {
      got += data.length;
      if (got >= n && !completer.isCompleted) completer.complete();
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    await sub.cancel();
    await sock.close();
  } else if (mode == 'tls') {
    final sock = await SecureSocket.connect(
      '127.0.0.1',
      port,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (_) => true,
      supportedProtocols: const ['h2'],
    );
    final sub = sock.listen(null);
    final completer = Completer<void>();
    sub.onData((data) {
      got += data.length;
      if (got >= n && !completer.isCompleted) completer.complete();
    });
    sub.onError((Object e) => completer.completeError(e));
    sub.onDone(() => completer.complete());
    await completer.future;
    await sock.close();
  } else {
    // h2: POST, читаем DATA-фреймы ответа
    final raw = await Socket.connect('127.0.0.1', port);
    final secure = await SecureSocket.secure(
      raw,
      host: 'localhost',
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (_) => true,
      supportedProtocols: const ['h2'],
    );
    final conn = ClientTransportConnection.viaStreams(
      secure,
      _LoggingSink(secure),
      settings: const ClientSettings(streamWindowSize: 1 << 20),
    );
    await conn.onInitialPeerSettingsReceived;
    final stream = conn.makeRequest([
      Header.ascii(':method', 'POST'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':path', '/data?n=$n'),
      Header.ascii(':authority', 'localhost'),
      Header.ascii('content-type', 'application/grpc'),
    ], endStream: true);
    final completer = Completer<void>();
    stream.incomingMessages.listen((msg) {
      if (msg is DataStreamMessage) {
        got += msg.bytes.length;
        if (got >= n && !completer.isCompleted) completer.complete();
      }
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    }, onError: (Object e) => completer.completeError(e));
    await completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException('h2 bench timeout'),
    );
    await conn.finish();
    await secure.close();
  }
  sw.stop();
  final sec = sw.elapsedMilliseconds / 1000;
  print(
    '$mode: $mib MiB за ${sec.toStringAsFixed(2)}с = '
    '${(mib / sec).toStringAsFixed(1)} MiB/s',
  );
  exit(0);
}

/// Диагностический sink: первые 3 записи с hex-префиксом.
class _LoggingSink implements StreamSink<List<int>> {
  final SecureSocket _socket;
  int _n = 0;
  _LoggingSink(this._socket);
  @override
  void add(List<int> data) {
    if (_n < 3) {
      final head = data
          .take(24)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      print('out[$_n] ${data.length}B: $head');
      _n++;
    }
    _socket.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => stream.pipe(_socket);
  @override
  Future get done => _socket.done;
  @override
  Future close() => _socket.close();
}
