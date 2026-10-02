import 'package:test/test.dart';

import 'package:backuppc_dart/backuppc_dart.dart';

void main() {
  group('BackupPC profile', () {
    test('session ID соответствует регексу сервера', () {
      final re = RegExp(
        r'^[a-z0-9][a-z0-9-]{2,31}\.[0-9]{1,6}\.[0-9a-f]{8}$',
      );
      for (var i = 0; i < 50; i++) {
        final sid = newBackupPCSessionID();
        expect(sid, matches(re));
        expect(validBackupPCSessionID(sid), isTrue);
        expect(backuppcHosts, contains(backuppcSessionHost(sid)));
      }
    });

    test('пул UA и хостов фиксирован (wire-контракт)', () {
      expect(backuppcUserAgents, hasLength(4));
      expect(backuppcUserAgents.first,
          'BackupPC-Agent/4.2.1 (rsync 3.2.7; linux x86_64)');
      expect(backuppcHosts, hasLength(20));
      expect(backuppcHosts.contains('ws-support-04'), isTrue);
    });

    test('ночное окно через полночь', () {
      final cfg = BackupPCConfig(nightStartHour: 22, nightEndHour: 6);
      // 23:00 — ночь; 03:00 — ночь; 12:00 — день; 06:00 — уже утро (конец)
      final night = backuppcNextJob(cfg, DateTime(2026, 1, 1, 23));
      expect(night.kind, BackupJobKind.full);
      final earlyMorning = backuppcNextJob(cfg, DateTime(2026, 1, 1, 3));
      expect(earlyMorning.kind, BackupJobKind.full);
      final day = backuppcNextJob(cfg, DateTime(2026, 1, 1, 12));
      expect(day.kind, BackupJobKind.incremental);
      final morning = backuppcNextJob(cfg, DateTime(2026, 1, 1, 6));
      expect(morning.kind, BackupJobKind.incremental);
    });

    test('дневное окно (22–06 наоборот)', () {
      final cfg = BackupPCConfig(nightStartHour: 6, nightEndHour: 22);
      final day = backuppcNextJob(cfg, DateTime(2026, 1, 1, 12));
      expect(day.kind, BackupJobKind.full);
      final night = backuppcNextJob(cfg, DateTime(2026, 1, 1, 23));
      expect(night.kind, BackupJobKind.incremental);
    });

    test('объемы инкрементов в границах', () {
      final cfg = BackupPCConfig();
      for (var i = 0; i < 30; i++) {
        final plan = backuppcNextJob(cfg, DateTime(2026, 1, 1, 12));
        expect(
          plan.bytes,
          inInclusiveRange(cfg.incrementalMinBytes, cfg.incrementalMaxBytes),
        );
        // задержка 25м ± 40%
        final base = const Duration(minutes: 25);
        expect(
          plan.delay.inMicroseconds,
          inInclusiveRange(
            (base.inMicroseconds * 0.6).round(),
            (base.inMicroseconds * 1.4).round(),
          ),
        );
      }
    });

    test('всплески rsync: 16–120 КиБ, сумма равна total', () {
      final bursts = planBackupBursts(5 * 1024 * 1024);
      var sum = 0;
      for (final b in bursts) {
        expect(b.size, lessThanOrEqualTo(120 * 1024));
        sum += b.size;
        expect(b.gap.inMilliseconds, inInclusiveRange(30, 300));
      }
      expect(sum, 5 * 1024 * 1024);
      // маленький total — один усеченный всплеск
      expect(planBackupBursts(100).single.size, 100);
      expect(planBackupBursts(0), isEmpty);
    });

    test('formatBackupBytes', () {
      expect(formatBackupBytes(32 << 20), '32MiB');
      expect(formatBackupBytes(16 << 10), '16KiB');
      expect(formatBackupBytes(500), '500B');
    });
  });

  group('random', () {
    test('randIntRange инклюзивен и в границах', () {
      final seen = <int>{};
      for (var i = 0; i < 500; i++) {
        final v = randIntRange(3, 7);
        expect(v, inInclusiveRange(3, 7));
        seen.add(v);
      }
      expect(seen, {3, 4, 5, 6, 7});
    });

    test('randBytes уникальны между вызовами (пул не застрял)', () {
      final a = randBytes(256);
      final b = randBytes(256);
      expect(a, isNot(equals(b)));
    });

    test('randHex 8 символов', () {
      expect(randHex(4), matches(RegExp(r'^[0-9a-f]{8}$')));
    });
  });
}
