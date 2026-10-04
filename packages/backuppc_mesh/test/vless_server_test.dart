import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:backuppc_mesh/backuppc_mesh.dart';

void main() {
  group('parseVlessRequest', () {
    test('IPv4 address type', () {
      // Build a VLESS request with IPv4 target
      final buf = Uint8List.fromList([
        0x00, // version
        ..._uuidBytes(),
        0x00, // addons len = 0
        0x01, // command = TCP
        0x00, 0x50, // port = 80
        0x01, // atyp = IPv4
        192, 168, 1, 1, // IPv4 address
      ]);
      final req = parseVlessRequest(buf);
      expect(req, isNotNull);
      expect(req!.command, equals(0x01)); // TCP
      expect(req.port, equals(80));
      expect(req.address, equals('192.168.1.1'));
      expect(req.addons.length, equals(0));
    });

    test('domain address type', () {
      final domain = 'example.com';
      final domainBytes = domain.codeUnits;
      final buf = Uint8List.fromList([
        0x00, // version
        ..._uuidBytes(),
        0x00, // addons len
        0x01, // command TCP
        0x00, 0x50, // port 80
        0x02, // atyp = domain
        domainBytes.length, // domain length
        ...domainBytes,
      ]);
      final req = parseVlessRequest(buf);
      expect(req, isNotNull);
      expect(req!.address, equals('example.com'));
      expect(req.port, equals(80));
    });

    test('IPv6 address type', () {
      final buf = Uint8List.fromList([
        0x00,
        ..._uuidBytes(),
        0x00, // addons
        0x01, // TCP
        0x1f, 0x90, // port 8080
        0x03, // atyp = IPv6
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // 2001:db8::1
      ]);
      final req = parseVlessRequest(buf);
      expect(req, isNotNull);
      expect(req!.port, equals(8080));
      expect(req.address, contains('2001'));
      expect(req.address, contains('db8'));
    });

    test('incomplete buffer returns null', () {
      final buf = Uint8List.fromList([0x00]); // too short
      final req = parseVlessRequest(buf);
      expect(req, isNull);
    });

    test('unsupported version throws', () {
      final buf = Uint8List.fromList([
        0x01, // wrong version
        ..._uuidBytes(),
        0x00, 0x01, 0x00, 0x50, 0x01, 127, 0, 0, 1,
      ]);
      expect(
        () => parseVlessRequest(buf),
        throwsA(isA<VlessParseException>()),
      );
    });

    test('unsupported command throws', () {
      final buf = Uint8List.fromList([
        0x00, // version OK
        ..._uuidBytes(),
        0x00, // addons
        0x02, // command = UDP (unsupported)
        0x00, 0x50, 0x01, 127, 0, 0, 1,
      ]);
      expect(
        () => parseVlessRequest(buf),
        throwsA(isA<VlessParseException>()),
      );
    });

    test('unknown address type throws', () {
      final buf = Uint8List.fromList([
        0x00,
        ..._uuidBytes(),
        0x00, 0x01, 0x00, 0x50,
        0xFF, // unknown atyp
      ]);
      expect(
        () => parseVlessRequest(buf),
        throwsA(isA<VlessParseException>()),
      );
    });
  });

  group('buildVlessResponse', () {
    test('returns 2 bytes [0x00, 0x00]', () {
      final resp = buildVlessResponse();
      expect(resp.length, equals(2));
      expect(resp[0], equals(0x00)); // version
      expect(resp[1], equals(0x00)); // addons len = 0
    });
  });
}

List<int> _uuidBytes() {
  // 16 zero bytes as UUID placeholder
  return List.filled(16, 0x00);
}
