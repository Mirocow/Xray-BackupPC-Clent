import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

void main() {
  group('BackupPcLink', () {
    test('parse: полный набор параметров', () {
      final link = BackupPcLink.tryParse(
        'backuppc://0123456789abcdef0123456789abcdef@198.51.100.7:8443/'
        '?host=lampa-tv.ru&fp='
        '7fbda8efec2e37418266b14e48e513bbce4e7868901f99318859ce65a4b6c72d'
        '&ua=BackupPC-Agent/4.2.1%20(rsync%203.2.7%3B%20linux%20x86_64)'
        '&endpoints=/a.BackupService/BackupStream,/b.ChunkService/PutChunk'
        '&pad=64-512#office',
      );
      expect(link, isNotNull);
      expect(link!.serverAddr, '198.51.100.7:8443');
      expect(link.uuid, '0123456789abcdef0123456789abcdef');
      expect(link.host, 'lampa-tv.ru');
      expect(link.insecure, isFalse);
      expect(link.endpointPaths, hasLength(2));
      expect(link.minPadding, 64);
      expect(link.maxPadding, 512);
      expect(link.tag, 'office');
    });

    test('parse: дефолты (порт 443, без параметров)', () {
      final link = BackupPcLink.tryParse(
        'backuppc://uuid-0@srv.example.net#node',
      );
      expect(link!.serverAddr, 'srv.example.net:443');
      expect(link.host, isEmpty);
      expect(link.endpointPaths, isEmpty);
      expect(link.tag, 'node');
    });

    test('parse: sni-алиас и insecure=1', () {
      final link = BackupPcLink.tryParse(
        'backuppc://u@h:9443/?sni=donor.example&insecure=1',
      );
      expect(link!.host, 'donor.example');
      expect(link.insecure, isTrue);
    });

    test('parse: ошибки — null', () {
      expect(BackupPcLink.tryParse('vless://u@h'), isNull);
      expect(BackupPcLink.tryParse('backuppc://h:443'), isNull); // нет uuid
      expect(BackupPcLink.tryParse('backuppc://u@h:?insecure=maybe'), isNull);
      expect(
        BackupPcLink.tryParse('backuppc://u@h:?pad=abc'),
        isNull,
      );
      expect(BackupPcLink.tryParse(''), isNull);
    });

    test('roundtrip: ссылка → outbound → ссылка', () {
      // каноническая форма Go (QueryEscape кодирует '/' в %2F, фрагмент — %20)
      final src =
          'backuppc://0123456789abcdef0123456789abcdef@203.0.113.9:8443'
          '?host=cdn.example&fp='
          '7fbda8efec2e37418266b14e48e513bbce4e7868901f99318859ce65a4b6c72d'
          '&endpoints=%2Fbackuppc.BackupService%2FBackupStream&pad=32-1400'
          '#My%20Server';
      final link = BackupPcLink.tryParse(src)!;
      expect(link.tag, 'My Server'); // фрагмент декодирован (семантика Go)
      expect(link.endpointPaths.single, '/backuppc.BackupService/BackupStream');
      final outbound = link.toOutboundJson();
      expect(outbound['protocol'], 'backuppc');
      final restored = BackupPcLink.fromOutboundJson(outbound)!;
      expect(restored.build(), src);
    });

    test('outbound JSON: только обязательные поля (совместимо с Go)', () {
      final outbound = BackupPcLink(
        serverAddr: '1.2.3.4:443',
        uuid: '0123456789abcdef0123456789abcdef',
      ).toOutboundJson();
      expect(outbound['settings'], {
        'serverAddr': '1.2.3.4:443',
        'uuid': '0123456789abcdef0123456789abcdef',
      });
      expect(outbound.containsKey('tag'), isFalse);
    });

    test('fromOutboundJson: не-backuppc протокол → null', () {
      expect(
        BackupPcLink.fromOutboundJson({'protocol': 'vless'}),
        isNull,
      );
    });

    test('build: UUID кодируется, IPv6 адрес сервера', () {
      final link = BackupPcLink(
        serverAddr: '[2001:db8::1]:8443',
        uuid: '0123456789abcdef0123456789abcdef',
        host: 'donor.example',
      );
      final built = link.build();
      expect(
        built,
        'backuppc://0123456789abcdef0123456789abcdef@'
        '[2001:db8::1]:8443?host=donor.example',
      );
      expect(
        BackupPcLink.tryParse(built)!.serverAddr,
        '[2001:db8::1]:8443',
      );
    });
  });
}
