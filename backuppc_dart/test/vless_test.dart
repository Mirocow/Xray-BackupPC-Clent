import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

void main() {
  group('VLESS', () {
    final id = Uint8List.fromList(List.generate(16, (i) => i));

    test('доменный target: раскладка байтов', () {
      final b = buildVlessRequest(id, 'example.com', 443);
      expect(b[0], 0x00); // version
      expect(b.sublist(1, 17), equals(id));
      expect(b[17], 0x00); // addons len
      expect(b[18], 0x01); // command TCP
      expect(b[19], 0x01); // port hi
      expect(b[20], 0xBB); // port lo (443)
      expect(b[21], 0x02); // atyp domain
      expect(b[22], 11); // длина имени
      expect(String.fromCharCodes(b.sublist(23, 34)), 'example.com');
      expect(b.length, 34);
    });

    test('IPv4 target', () {
      final b = buildVlessRequest(id, '127.0.0.1', 8080);
      expect(b[21], 0x01);
      expect(b.sublist(22, 26), equals([127, 0, 0, 1]));
      expect((b[19] << 8) | b[20], 8080);
      expect(b.length, 26);
    });

    test('IPv6 target', () {
      final b = buildVlessRequest(id, '::1', 443);
      expect(b[21], 0x03);
      expect(b.length, 1 + 16 + 1 + 1 + 2 + 1 + 16);
      expect(b.sublist(22, 38).sublist(0, 15), equals(List.filled(15, 0)));
      expect(b[37], 1);
    });

    test('IPv6 target в скобках (формат xray-core) — уходит типом 0x03', () {
      // xray-core отдаёт ipv6Address.String() в скобках; раньше такой адрес
      // уезжал полем «домен» и сервер дважды оборачивал его в скобки.
      final b = buildVlessRequest(id, '[2a00:1450:4010:c0e::5e]', 443);
      expect(b[21], 0x03);
      expect(b.length, 1 + 16 + 1 + 1 + 2 + 1 + 16);
      final ip = InternetAddress.fromRawAddress(
          Uint8List.fromList(b.sublist(22, 38)));
      expect(ip.address, '2a00:1450:4010:c0e::5e');
    });

    test('parseUUID: с дефисами и без', () {
      final dashed = '01234567-89ab-cdef-0123-456789abcdef';
      final plain = dashed.replaceAll('-', '');
      expect(parseUUID(dashed), equals(parseUUID(plain)));
      expect(parseUUID(plain)!.length, 16);
      expect(parseUUID('xyz'), isNull);
      expect(parseUUID('0123456789abcdef0123456789abcdeg'), isNull);
    });
  });
}
