import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

void main() {
  group('Duration_', () {
    test('Go-стиль: строки', () {
      expect(Duration_.parse('20s').value, const Duration(seconds: 20));
      expect(Duration_.parse('1.5h').value, const Duration(hours: 1, minutes: 30));
      expect(Duration_.parse('250ms').value, const Duration(milliseconds: 250));
      expect(Duration_.parse('1h30m').value, const Duration(hours: 1, minutes: 30));
      expect(Duration_.parse('0').value, Duration.zero);
      expect(Duration_.parse(90).value, const Duration(seconds: 90));
    });

    test('некорректные значения', () {
      expect(() => Duration_.parse('abc'), throwsFormatException);
      expect(() => Duration_.parse('20x'), throwsFormatException);
    });

    test('сериализация обратно (Go-стиль)', () {
      expect(Duration_.parse('20s').toJson(), '20s');
      expect(Duration_.parse('1.5h').toJson(), '1h30m0s');
      expect(Duration_.parse('250ms').toJson(), '250ms');
      expect(Duration_.parse('30m').toJson(), '30m0s');
    });
  });

  group('TransportConfig', () {
    test('дефолты соответствуют ТЗ', () {
      final c = TransportConfig();
      expect(c.endpointPaths, hasLength(3));
      expect(c.endpointPaths.first, '/backuppc.BackupService/BackupStream');
      expect(c.minPaddingSize, 32);
      expect(c.maxPaddingSize, 1400);
      expect(c.maxWriteChunk, 16384);
      expect(c.maxSessionBytes, 2 * 1024 * 1024 * 1024);
      expect(c.maxSessionDuration.value, const Duration(minutes: 30));
      expect(c.pingBaseInterval.value, const Duration(seconds: 20));
      expect(c.pingJitterMax.value, const Duration(seconds: 15));
      expect(c.balancingInterval.value, const Duration(seconds: 5));
      expect(c.fakeUploadChunk, 512 * 1024);
      expect(c.dialRetries, 3);
      expect(c.backuppc.enabledOn, isTrue);
      expect(c.backuppc.incrementalMinBytes, 2 << 20);
      expect(c.backuppc.nightStartHour, 22);
      expect(c.validate(), isNull);
    });

    test('json roundtrip с настраиваемой ротацией', () {
      final json = {
        'endpointPaths': ['/x.Y/Z'],
        'host': 'donor.example',
        'maxSessionBytes': 4096,
        'maxSessionDuration': '2s',
        'minPaddingSize': 8,
        'maxPaddingSize': 16,
        'backuppc': {'enabled': false, 'idleOnly': false},
      };
      final c = TransportConfig.fromJson(json);
      expect(c.maxSessionBytes, 4096);
      expect(c.maxSessionDuration.value, const Duration(seconds: 2));
      expect(c.backuppc.enabledOn, isFalse);
      expect(c.backuppc.idleOnly, isFalse);
      final out = c.toJson();
      expect(out['maxSessionBytes'], 4096);
      final back = TransportConfig.fromJson(out);
      expect(back.maxSessionBytes, c.maxSessionBytes);
      expect(back.maxSessionDuration.value, c.maxSessionDuration.value);
    });

    test('валидация ловит ошибки', () {
      expect(
        TransportConfig(
          endpointPaths: ['no-slash'],
        ).validate(),
        isNotNull,
      );
      expect(
        TransportConfig(minPaddingSize: 100, maxPaddingSize: 10).validate(),
        isNotNull,
      );
      final bad = TransportConfig();
      bad.maxWriteChunk = 10;
      expect(bad.validate(), isNotNull);
      final badNight = TransportConfig();
      badNight.backuppc.nightStartHour = 24;
      expect(badNight.validate(), isNotNull);
    });

    test('randPadding в границах', () {
      final c = TransportConfig(minPaddingSize: 5, maxPaddingSize: 9);
      for (var i = 0; i < 100; i++) {
        final p = c.randPadding();
        expect(p, greaterThanOrEqualTo(5));
        expect(p, lessThanOrEqualTo(9));
      }
    });

    test('randomEndpoint выбирает из пула', () {
      final c = TransportConfig(endpointPaths: ['/a', '/b', '/c']);
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(c.randomEndpoint());
      }
      expect(seen, {'/a', '/b', '/c'});
    });
  });

  group('ClientConfig', () {
    test('валидация: serverAddr/uuid/insecure-конфликт', () {
      final base = {
        'serverAddr': '1.2.3.4:443',
        'uuid': '0123456789abcdef0123456789abcdef',
      };
      expect(ClientConfig.fromJson(base).validate(), isNull);
      expect(
        ClientConfig.fromJson({...base, 'serverAddr': ''}).validate(),
        isNotNull,
      );
      expect(
        ClientConfig.fromJson({...base, 'uuid': 'nope'}).validate(),
        isNotNull,
      );
      expect(
        ClientConfig.fromJson({
          ...base,
          'insecure': true,
          'certFingerprint': 'ab' * 32,
        }).validate(),
        isNotNull,
      );
    });

    test('splitServerAddr: v4/v6/без порта', () {
      expect(
        ClientConfig.fromJson({
          'serverAddr': 'h:8443',
        }).splitServerAddr(),
        ('h', 8443),
      );
      expect(
        ClientConfig.fromJson({'serverAddr': 'h'}).splitServerAddr(),
        ('h', 443),
      );
      expect(
        ClientConfig.fromJson({
          'serverAddr': '[2001:db8::2]:9443',
        }).splitServerAddr(),
        ('2001:db8::2', 9443),
      );
    });

    test('loadClientConfigFromJson', () {
      final cfg = loadClientConfigFromJson('''
        {"serverAddr":"1.2.3.4:443","uuid":"0123456789abcdef0123456789abcdef",
         "socksListen":"127.0.0.1:10808","transport":{"host":"donor.example"}}
      ''');
      expect(cfg.socksListen, '127.0.0.1:10808');
      expect(cfg.transport.host, 'donor.example');
    });
  });
}
