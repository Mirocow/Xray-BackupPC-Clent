/// Профиль маскировки BackupPC: пулы хостов/агентов, идентификаторы
/// «заданий бекапа», планировщик псевдо-бэкапов (инкременты/полные,
/// ночное окно, rsync-всплески).
library;

import 'config.dart';
import 'random.dart';

/// Пул «хостов», якобы бэкапящихся на узел хранения. 130+ имён:
/// гипервизоры, сервисные роли, NAS-полки, гео-ветки и департаментские
/// станции — чтобы идентификаторы заданий не повторялись.
const List<String> backuppcHosts = [
  // Гипервизоры и контейнерные хосты
  'srv-esxi-01', 'srv-esxi-02', 'srv-esxi-03', 'srv-kvm-01', 'srv-kvm-02',
  'srv-kvm-03', 'srv-docker-01', 'srv-docker-02', 'srv-docker-03',
  'srv-vm-farm-01', 'srv-vm-farm-02', 'srv-proxmox-01', 'srv-proxmox-02',

  // Сервисные роли (каталоги, файловые, БД, приложения)
  'srv-dc-01', 'srv-dc-02', 'srv-dc-03', 'srv-fs-01', 'srv-fs-02', 'srv-fs-03',
  'srv-mail-01', 'srv-mail-02', 'srv-db-01', 'srv-db-02', 'srv-db-03',
  'srv-db-cluster-01', 'srv-web-01', 'srv-web-02', 'srv-web-03', 'srv-web-04',
  'srv-app-01', 'srv-app-02', 'srv-app-03', 'srv-app-04', 'srv-app-05',
  'srv-backup-01', 'srv-backup-02', 'srv-arch-01', 'srv-arch-02',
  'srv-build-01', 'srv-build-02', 'srv-ci-01', 'srv-ci-02', 'srv-mon-01',
  'srv-mon-02', 'srv-mon-03', 'srv-git-01', 'srv-git-02', 'srv-repo-01',
  'srv-wiki-01', 'srv-jira-01', 'srv-confluence-01', 'srv-print-01',
  'srv-print-02', 'srv-vpn-01', 'srv-vpn-02', 'srv-proxy-01', 'srv-proxy-02',
  'srv-dns-01', 'srv-dns-02', 'srv-ntp-01', 'srv-ldap-01', 'srv-ldap-02',
  'srv-rabbit-01', 'srv-kafka-01', 'srv-es-01', 'srv-es-02', 'srv-cache-01',
  'srv-cache-02', 'srv-object-01', 'srv-object-02', 'srv-s3-01',
  'srv-inventory-01', 'srv-zabbix-01', 'srv-grafana-01', 'srv-logs-01',

  // NAS-полки
  'nas-arch-01', 'nas-arch-02', 'nas-arch-03', 'nas-media-01',
  'nas-scratch-01', 'nas-backup-01', 'nas-backup-02', 'nas-ops-01',
  'nas-video-01', 'nas-photo-01', 'nas-scan-01', 'nas-cctv-01',

  // Гео-ветки/филиалы (серверы)
  'srv-msk-01', 'srv-msk-02', 'srv-spb-01', 'srv-spb-02', 'srv-nsk-01',
  'srv-ekb-01', 'srv-kld-01', 'srv-vlg-01', 'srv-rnd-01', 'srv-smr-01',
  'srv-ufa-01', 'srv-kzn-01', 'srv-branch-01', 'srv-branch-02',

  // Рабочие станции по департаментам
  'ws-finance-01', 'ws-finance-02', 'ws-finance-03', 'ws-finance-04',
  'ws-finance-05', 'ws-finance-06', 'ws-finance-07', 'ws-hr-01', 'ws-hr-04',
  'ws-hr-08', 'ws-hr-12', 'ws-dev-01', 'ws-dev-02', 'ws-dev-03', 'ws-dev-05',
  'ws-dev-07', 'ws-dev-09', 'ws-dev-11', 'ws-dev-13', 'ws-dev-14',
  'ws-qa-01', 'ws-qa-03', 'ws-qa-06', 'ws-qa-08', 'ws-sales-01',
  'ws-sales-05', 'ws-sales-09', 'ws-sales-11', 'ws-mgmt-01', 'ws-mgmt-02',
  'ws-mgmt-07', 'ws-support-01', 'ws-support-04', 'ws-support-06',
  'ws-legal-01', 'ws-legal-03', 'ws-marketing-02', 'ws-marketing-05',
  'ws-logistics-01', 'ws-logistics-04', 'ws-design-01', 'ws-design-02',
  'ws-design-06', 'ws-bi-01', 'ws-bi-03', 'ws-ops-02', 'ws-ops-05',
  'ws-sec-01', 'ws-sec-04', 'ws-accounting-02', 'ws-accounting-07',
  'ws-procurement-01', 'ws-procurement-05', 'ws-frontend-03', 'ws-frontend-09',
  'ws-backend-01', 'ws-backend-06', 'ws-mobile-02', 'ws-mobile-08',
  'ws-data-01', 'ws-data-04', 'ws-admin-01', 'ws-admin-02', 'ws-helpdesk-01',
  'ws-helpdesk-05', 'ws-cto-01', 'ws-coo-01', 'ws-translator-01',

  // Рабочие станции филиалов
  'ws-msk-dev-01', 'ws-msk-qa-02', 'ws-spb-fin-01', 'ws-spb-hr-02',
  'ws-nsk-eng-01', 'ws-ekb-ops-01', 'ws-kld-sales-01', 'ws-geo-srv-01',
];

/// Пул User-Agent агентов резервного копирования: perl-агенты
/// классического BackupPC, Go-агенты современных систем, rsync-обертки.
const List<String> backuppcUserAgents = [
  'BackupPC-Agent/4.2.1 (rsync 3.2.7; linux x86_64)',
  'BackupPC-Transfer/3.3.2 (rsync 3.1.3; linux)',
  'backup-worker/2.7 (Storage::Chunk; perl 5.36)',
  'rsync-backup-client/3.2.7 (linux x86_64)',
  'BackupPC-Agent/4.1.5 (rsync 3.1.4; debian 11)',
  'BackupPC-Agent/4.3.0 (rsync 3.2.7; ubuntu 22.04)',
  'rsync/3.2.7-1ubuntu3 (protocol version 30)',
  'restic/0.16.4 (linux amd64)',
  'kopia/0.15.0 (linux amd64)',
  'borgbackup/1.2.7 (linux amd64)',
  'storaged-agent/5.3 (chunk-uploader; go1.21.5 linux/amd64)',
  'pcbackupd/1.8.2 (x86_64-pc-linux-gnu)',
];

final RegExp _sessionRe = RegExp(
  r'^[a-z0-9][a-z0-9-]{2,31}\.[0-9]{1,6}\.[0-9a-f]{8}$',
);

bool validBackupPCSessionID(String s) => _sessionRe.hasMatch(s);

/// Идентификатор «задания» BackupPC: "ws-finance-03.1174.6f3a2b1"
/// (хост из пула 130+ . номер бекапа . nonce).
String newBackupPCSessionID() {
  final host = backuppcHosts[randIntRange(0, backuppcHosts.length - 1)];
  final job = 9 + randIntRange(0, 4191); // 9..4200
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
