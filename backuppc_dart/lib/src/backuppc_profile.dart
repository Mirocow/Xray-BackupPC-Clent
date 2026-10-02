/// Профиль маскировки BackupPC: пулы хостов/агентов, идентификаторы
/// «заданий бекапа», планировщик псевдо-бэкапов (инкременты/полные,
/// ночное окно, rsync-всплески).
library;

import 'config.dart';
import 'random.dart';

/// Пул «хостов», якобы бэкапящихся на узел хранения.
const List<String> backuppcHosts = [
  'srv-dc-01', 'srv-dc-02', 'srv-fs-01', 'srv-fs-02', 'srv-mail-01',
  'srv-db-01', 'srv-web-03', 'srv-app-05', 'srv-backup-01', 'nas-arch-01',
  'nas-arch-02', 'ws-finance-03', 'ws-finance-07', 'ws-hr-12',
  'ws-dev-05', 'ws-dev-11', 'ws-sales-09', 'ws-mgmt-02', 'ws-qa-06',
  'ws-support-04',
];

/// Пул User-Agent агентов резервного копирования.
const List<String> backuppcUserAgents = [
  'BackupPC-Agent/4.2.1 (rsync 3.2.7; linux x86_64)',
  'BackupPC-Transfer/3.3.2 (rsync 3.1.3; linux)',
  'backup-worker/2.7 (Storage::Chunk; perl 5.36)',
  'rsync-backup-client/3.2.7 (linux x86_64)',
];

final RegExp _sessionRe = RegExp(
  r'^[a-z0-9][a-z0-9-]{2,31}\.[0-9]{1,6}\.[0-9a-f]{8}$',
);

bool validBackupPCSessionID(String s) => _sessionRe.hasMatch(s);

/// Идентификатор «задания» BackupPC: "ws-finance-03.1174.6f3a2b1"
/// (хост из пула . номер бекапа . nonce).
String newBackupPCSessionID() {
  final host = backuppcHosts[randIntRange(0, backuppcHosts.length - 1)];
  final job = 100 + randIntRange(0, 9900);
  return '$host.$job.${randHex(4)}';
}

/// Случайный User-Agent из пула агентов бекапа.
String pickBackupPCUserAgent() =>
    backuppcUserAgents[randIntRange(0, backuppcUserAgents.length - 1)];

/// Имя «хоста» из идентификатора сессии (для логов).
String backuppcSessionHost(String id) {
  final i = id.indexOf('.');
  return i > 0 ? id.substring(0, i) : id;
}

enum BackupJobKind { incremental, full }

String jobKindName(BackupJobKind k) =>
    k == BackupJobKind.full ? 'full' : 'incr';

/// План следующего псевдо-задания.
class BackupJobPlan {
  final BackupJobKind kind;
  final int bytes;
  final Duration delay; // пауза до запуска (джиттер ±40%)
  const BackupJobPlan(this.kind, this.bytes, this.delay);
}

/// Расписание следующего задания: ночью полные «бэкапы» по fullEvery,
/// иначе инкрементные по incrementalEvery; интервал и объем рандомизированы.
BackupJobPlan backuppcNextJob(BackupPCConfig cfg, DateTime now) {
  final night = _inNightWindow(now, cfg.nightStartHour, cfg.nightEndHour);
  if (night && cfg.fullEvery.value > Duration.zero) {
    return BackupJobPlan(
      BackupJobKind.full,
      randIntRange(cfg.fullMinBytes, cfg.fullMaxBytes),
      jitterFraction(cfg.fullEvery.value, 0.4),
    );
  }
  final base = cfg.incrementalEvery.value;
  return BackupJobPlan(
    BackupJobKind.incremental,
    randIntRange(cfg.incrementalMinBytes, cfg.incrementalMaxBytes),
    jitterFraction(base, 0.4),
  );
}

/// Попадание момента в ночное окно (может переходить через полночь).
bool _inNightWindow(DateTime now, int start, int end) {
  final h = now.hour;
  if (start == end) return false;
  if (start < end) return h >= start && h < end;
  return h >= start || h < end; // через полночь
}

/// Случайное отклонение от базовой длительности: base ± fraction*base.
Duration jitterFraction(Duration base, double fraction) {
  if (base <= Duration.zero) return Duration.zero;
  final spanMicros = (base.inMicroseconds * fraction).round();
  final span = Duration(microseconds: spanMicros);
  return base + randDurationRange(-span, span);
}

/// Один всплеск «передачи файлов» внутри псевдо-бэкапа.
class BackupBurst {
  final int size; // мусорные байты всплеска
  final Duration gap; // пауза до всплеска
  const BackupBurst(this.size, this.gap);
}

/// Раскладка total байт по всплескам 16–120 КиБ с паузами 30–300 мс:
/// имитация последовательной передачи файлов (rsync: файл → скан → файл).
List<BackupBurst> planBackupBursts(int total) {
  if (total <= 0) return const [];
  final out = <BackupBurst>[];
  var rem = total;
  while (rem > 0) {
    var size = randIntRange(16 << 10, 120 << 10);
    if (size > rem) size = rem;
    final gap = randDurationRange(
      const Duration(milliseconds: 30),
      const Duration(milliseconds: 300),
    );
    out.add(BackupBurst(size, gap));
    rem -= size;
  }
  return out;
}

/// Человекочитаемый объем для логов.
String formatBackupBytes(int n) {
  if (n >= 1 << 20 && n % (1 << 20) == 0) return '${n >> 20}MiB';
  if (n >= 1 << 10) return '${n >> 10}KiB';
  return '${n}B';
}
