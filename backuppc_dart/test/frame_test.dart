import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

void main() {
  group('FrameCodec', () {
    test('roundtrip: payload с паддингом читается целиком', () async {
      final feeder = ByteFeeder();
      final writerCodec = FrameCodec.forWriting((frame) async {
        // эмуляция gRPC-канала: кадр → сообщение → фидер
        feeder.add(grpcWrap(frame));
      }, TransportConfig());
      final readerCodec = FrameCodec.forReading(
        GrpcMessageReader(feeder),
        TransportConfig(),
      );
      final payload = Uint8List.fromList(List.generate(5000, (i) => i & 0xFF));
      await writerCodec.write(payload);
      feeder.close();
      final out = BytesBuilder();
      final buf = Uint8List(999);
      try {
        for (;;) {
          final n = await readerCodec.read(buf);
          if (n <= 0) break;
          out.add(Uint8List.sublistView(buf, 0, n));
        }
      } on ChunkEofException {
        // фидер закрыт — штатный конец потока
      }
      expect(out.toBytes(), equals(payload));
      expect(writerCodec.txPayload, payload.length);
      expect(readerCodec.rxPayload, payload.length);
    });

    test('roundtrip: нарезка больших записей по maxWriteChunk', () async {
      final feeder = ByteFeeder();
      final cfg = TransportConfig();
      cfg.minPaddingSize = 32;
      cfg.maxPaddingSize = 64;
      final writerCodec = FrameCodec.forWriting((frame) async {
        feeder.add(grpcWrap(frame));
      }, cfg);
      final readerCodec = FrameCodec.forReading(GrpcMessageReader(feeder), cfg);
      final payload = Uint8List.fromList(
        List.generate(cfg.maxWriteChunk * 3 + 1234, (i) => i & 0xFF),
      );
      await writerCodec.write(payload);
      feeder.close();
      final out = BytesBuilder();
      final buf = Uint8List(4096);
      try {
        for (;;) {
          final n = await readerCodec.read(buf);
          if (n <= 0) break;
          out.add(Uint8List.sublistView(buf, 0, n));
        }
      } on ChunkEofException {
        // конец потока
      }
      expect(out.toBytes(), equals(payload));
    });

    test('padding-only кадры прозрачны для полезной нагрузки', () async {
      final feeder = ByteFeeder();
      final cfg = TransportConfig();
      final writerCodec = FrameCodec.forWriting((frame) async {
        feeder.add(grpcWrap(frame));
      }, cfg);
      final readerCodec = FrameCodec.forReading(GrpcMessageReader(feeder), cfg);
      await writerCodec.write([1, 2, 3]);
      await writerCodec.writePadding(100 * 1024); // > 65535 → два кадра
      await writerCodec.write([4, 5, 6]);
      await writerCodec.writeEof();
      feeder.close();
      final out = BytesBuilder();
      final buf = Uint8List(16);
      try {
        for (;;) {
          final n = await readerCodec.read(buf);
          if (n <= 0) break;
          out.add(Uint8List.sublistView(buf, 0, n));
        }
      } on ChunkEofException {
        // маркер (0,0) — штатный конец
      }
      expect(out.toBytes(), equals([1, 2, 3, 4, 5, 6]));
    });

    test('EOF-маркер (0,0) читается как ChunkEofException', () async {
      final feeder = ByteFeeder();
      final writerCodec = FrameCodec.forWriting((frame) async {
        feeder.add(grpcWrap(frame));
      }, TransportConfig());
      final readerCodec = FrameCodec.forReading(GrpcMessageReader(feeder), TransportConfig());
      await writerCodec.writeEof();
      feeder.close();
      final buf = Uint8List(4);
      await expectLater(readerCodec.read(buf), throwsA(isA<ChunkEofException>()));
    });

    test('writePadding считает wire, но не payload', () async {
      final wrote = <Uint8List>[];
      final codec = FrameCodec.forWriting((frame) async {
        wrote.add(frame as Uint8List);
      }, TransportConfig());
      await codec.writePadding(1000);
      expect(codec.txPayload, 0);
      expect(codec.txWire, 1000 + 4);
      expect(wrote.single.length, 1004);
      // заголовок: payload=0, padding=1000
      expect(wrote.single[0], 0);
      expect(wrote.single[1], 0);
      expect((wrote.single[2] << 8) | wrote.single[3], 1000);
    });

    test('письмо после закрытия кодека — ошибка', () async {
      final codec = FrameCodec.forWriting((frame) async {}, TransportConfig());
      codec.closedFlag = true;
      await expectLater(codec.write([1]), throwsA(isA<StreamException_>()));
    });
  });

  group('GrpcMessageReader', () {
    test('обрыв внутри сообщения — ошибка, не EOF', () async {
      final feeder = ByteFeeder();
      final full = grpcWrap(Uint8List.fromList([1, 2, 3, 4, 5]));
      feeder.add(Uint8List.sublistView(full, 0, full.length - 2)); // обрубок
      feeder.close();
      final reader = GrpcMessageReader(feeder);
      expect(
        () => reader.readExact(5),
        throwsA(isA<StreamException_>()),
      );
    });

    test('пустые gRPC-сообщения пропускаются', () async {
      final feeder = ByteFeeder();
      feeder.add(Uint8List.fromList([0, 0, 0, 0, 0])); // len=0
      feeder.add(grpcWrap(Uint8List.fromList([9, 9])));
      feeder.close();
      final reader = GrpcMessageReader(feeder);
      expect(await reader.readExact(2), equals([9, 9]));
    });

    test('чтение пересекает границы сообщений', () async {
      final feeder = ByteFeeder();
      feeder.add(grpcWrap(Uint8List.fromList([1, 2])));
      feeder.add(grpcWrap(Uint8List.fromList([3, 4])));
      feeder.close();
      final reader = GrpcMessageReader(feeder);
      expect(await reader.readExact(4), equals([1, 2, 3, 4]));
    });

    test('флаг сжатия отклоняется', () async {
      final feeder = ByteFeeder();
      feeder.add(Uint8List.fromList([1, 0, 0, 0, 2, 9, 9]));
      feeder.close();
      final reader = GrpcMessageReader(feeder);
      expect(() => reader.readExact(2), throwsA(isA<StreamException_>()));
    });
  });

  group('ByteFeeder', () {
    test('skip не аллоцирует и корректен через границы', () async {
      final feeder = ByteFeeder();
      feeder.add(Uint8List.fromList(List.generate(300, (i) => i & 0xFF)));
      feeder.add(
        Uint8List.fromList(
          List.generate(300, (i) => (i + 300) & 0xFF),
        ),
      );
      feeder.close();
      await feeder.skip(500);
      expect(
        await feeder.readExact(100),
        equals(List.generate(100, (i) => (500 + i) & 0xFF)),
      );
    });

    test('backlogBytes отражает буфер', () async {
      final feeder = ByteFeeder();
      feeder.add(Uint8List.fromList(List.filled(1000, 1)));
      expect(feeder.backlogBytes, 1000);
      await feeder.skip(400);
      expect(feeder.backlogBytes, 600);
    });
  });
}

Uint8List grpcWrap(List<int> frame) {
  final msg = Uint8List(5 + frame.length);
  msg[0] = 0;
  msg[1] = (frame.length >> 24) & 0xFF;
  msg[2] = (frame.length >> 16) & 0xFF;
  msg[3] = (frame.length >> 8) & 0xFF;
  msg[4] = frame.length & 0xFF;
  msg.setRange(5, msg.length, frame);
  return msg;
}
