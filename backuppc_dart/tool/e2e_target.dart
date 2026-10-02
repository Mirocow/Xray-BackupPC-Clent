/// E2E-таргет: детерминированный HTTP-источник/приемник для проверки
/// целостности и скорости туннеля (аналог режима target из backuppc-bench).
///
///   GET /data?n=BYTES&seed=S  — поток xorshift(S), заголовок X-Data-SHA256
///   POST /sink (тело)         — принимает тело, возвращает sha256 hex
///   GET /healthz              — "ok"
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import 'det_stream.dart';

const int chunkSize = 64 * 1024;

String expectedSha(int seed, int n) => detSha256(seed, n);

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args[0]) ?? 8901 : 8901;
  final server = await ServerSocket.bind('127.0.0.1', port);
  print('target listening on 127.0.0.1:$port');
  server.listen((socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    unawaited(_serve(socket));
  });
}

Future<void> _serve(Socket socket) async {
  try {
    final it = StreamIterator<Uint8List>(socket);
    final (head, leftover) = await _readHeaders(it);
    final firstLine = head.split('\r\n').first;
    final parts = firstLine.split(' ');
    if (parts.length < 2) {
      socket.destroy();
      return;
    }
    final method = parts[0];
    final uri = Uri.parse(parts[1]);
    final params = uri.queryParameters;
    switch (uri.path) {
      case '/healthz':
        _reply(socket, 200, 'ok');
      case '/data':
        final n = int.tryParse(params['n'] ?? '0') ?? 0;
        final seed = int.tryParse(params['seed'] ?? '1') ?? 1;
        final sha = expectedSha(seed, n);
        socket.add(utf8.encode(
          'HTTP/1.1 200 OK\r\nContent-Length: $n\r\n'
          'X-Data-SHA256: $sha\r\nConnection: close\r\n\r\n',
        ));
        final gen = DetStream(seed);
        var sent = 0;
        while (sent < n) {
          final take = (n - sent) < chunkSize ? (n - sent) : chunkSize;
          socket.add(gen.nextChunk(take));
          sent += take;
          if (sent % (chunkSize * 4) == 0) {
            await socket.flush(); // backpressure через буфер ОС
          }
        }
        await socket.flush();
        await socket.close();
      case '/sink':
        if (method != 'POST') {
          _reply(socket, 405, 'method');
          return;
        }
        // Content-Length обязателен
        var length = -1;
        for (final line in head.split('\r\n')) {
          final l = line.toLowerCase();
          if (l.startsWith('content-length:')) {
            length = int.tryParse(line.substring(15).trim()) ?? -1;
          }
        }
        if (length < 0) {
          _reply(socket, 411, 'length required');
          return;
        }
        final out = AccumulatorSink<Digest>();
        final sink = sha256.startChunkedConversion(out);
        var got = 0;
        if (leftover != null && leftover.isNotEmpty) {
          sink.add(leftover);
          got += leftover.length;
        }
        while (got < length) {
          final has = await it.moveNext();
          if (!has) break;
          sink.add(it.current);
          got += it.current.length;
        }
        sink.close();
        await it.cancel();
        _reply(
          socket,
          got == length ? 200 : 400,
          got == length ? out.events.single.toString() : 'short body $got/$length',
        );
      default:
        _reply(socket, 404, 'not found');
    }
  } on Exception {
    socket.destroy();
  }
}

Future<(String, Uint8List?)> _readHeaders(StreamIterator<Uint8List> it) async {
  final acc = BytesBuilder();
  while (true) {
    final has = await it.moveNext().timeout(const Duration(seconds: 20));
    if (!has) {
      throw const SocketException('no request');
    }
    acc.add(it.current);
    final bytes = acc.toBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    final idx = text.indexOf('\r\n\r\n');
    if (idx >= 0) {
      // байты после заголовков (начало тела) — локально для этого соединения
      var headerBytes = 0;
      for (var i = 0; i <= idx; i++) {
        if (text.startsWith('\r\n\r\n', i)) {
          headerBytes = i + 4;
          break;
        }
      }
      final rest = bytes.length > headerBytes
          ? Uint8List.sublistView(bytes, headerBytes)
          : null;
      return (text.substring(0, idx), rest);
    }
  }
}

void _reply(Socket socket, int code, String body) {
  socket.add(utf8.encode(
    'HTTP/1.1 $code X\r\nContent-Type: text/plain\r\n'
    'Content-Length: ${utf8.encode(body).length}\r\n'
    'Connection: close\r\n\r\n$body',
  ));
  socket.close();
}
