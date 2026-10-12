/// DTO-модели Admin API сервера xray-backuppc (контракт — docs/ADMIN-API.md
/// серверного репозитория). Поля помечены `??`-дефолтами: серверы старых
/// версий не отдают часть секций (например, filter/dns до 1.3.0).
library;

class LoginInfo {
  final bool ok;
  final String version;
  final int uptimeMs;
  final String fingerprint;
  LoginInfo({
    required this.ok,
    required this.version,
    required this.uptimeMs,
    required this.fingerprint,
  });

  factory LoginInfo.fromJson(Map<String, dynamic> j) => LoginInfo(
    ok: j['ok'] == true,
    version: (j['version'] ?? '').toString(),
    uptimeMs: (j['uptimeMs'] ?? 0) is int ? j['uptimeMs'] as int : 0,
    fingerprint: (j['fingerprint'] ?? '').toString(),
  );

  /// версия в сравнимом виде: 1.4.0 → 10400
  int get versionInt {
    final parts = version.split('.');
    var v = 0;
    for (var i = 0; i < 3 && i < parts.length; i++) {
      v = v * 100 + (int.tryParse(parts[i]) ?? 0);
    }
    return v;
  }
}

class Metrics {
  final int sessions;
  final int chunks;
  final int probes;
  final int bytesUp;
  final int bytesDown;
  final int connsOpen;
  Metrics({
    required this.sessions,
    required this.chunks,
    required this.probes,
    required this.bytesUp,
    required this.bytesDown,
    required this.connsOpen,
  });

  factory Metrics.fromJson(Map<String, dynamic> j) => Metrics(
    sessions: _i(j['sessionsTotal']),
    chunks: _i(j['chunks']),
    probes: _i(j['probes']),
    bytesUp: _i(j['bytesUp']),
    bytesDown: _i(j['bytesDown']),
    connsOpen: _i(j['connsOpen']),
  );
}

class SysInfo {
  final double cpu;
  final int cpus;
  final double load1;
  final int memRssBytes;
  final int memTotalBytes;
  final int goroutines;
  final int fds;
  final int goHeapBytes;
  final int numGC;
  final double gcPauseAvgMs;
  SysInfo({
    required this.cpu,
    required this.cpus,
    required this.load1,
    required this.memRssBytes,
    required this.memTotalBytes,
    required this.goroutines,
    required this.fds,
    required this.goHeapBytes,
    required this.numGC,
    required this.gcPauseAvgMs,
  });

  factory SysInfo.fromJson(Map<String, dynamic>? j) => SysInfo(
    cpu: _d(j?['cpu']),
    cpus: _i(j?['cpus']),
    load1: _d(j?['load1']),
    memRssBytes: _i(j?['memRssBytes']),
    memTotalBytes: _i(j?['memTotalBytes']),
    goroutines: _i(j?['goroutines']),
    fds: _i(j?['fds']),
    goHeapBytes: _i(j?['goHeapBytes']),
    numGC: _i(j?['numGC']),
    gcPauseAvgMs: _d(j?['gcPauseAvgMs']),
  );
}

class FilterBlocked {
  final int ads;
  final int trackers;
  final int malware;
  final int torrents;
  final int custom;
  FilterBlocked({
    required this.ads,
    required this.trackers,
    required this.malware,
    required this.torrents,
    required this.custom,
  });

  factory FilterBlocked.fromJson(Map<String, dynamic>? j) => FilterBlocked(
    ads: _i(j?['ads']),
    trackers: _i(j?['trackers']),
    malware: _i(j?['malware']),
    torrents: _i(j?['torrents']),
    custom: _i(j?['custom']),
  );
}

class FilterStats {
  final bool enabled;
  final int total;
  final int domains;
  final int ports;
  final int handshake;
  final FilterBlocked blocked;
  FilterStats({
    required this.enabled,
    required this.total,
    required this.domains,
    required this.ports,
    required this.handshake,
    required this.blocked,
  });

  factory FilterStats.fromJson(Map<String, dynamic>? j) => FilterStats(
    enabled: j?['enabled'] == true,
    total: _i(j?['total']),
    domains: _i(j?['domains']),
    ports: _i(j?['ports']),
    handshake: _i(j?['handshake']),
    blocked: FilterBlocked.fromJson(j?['blocked']),
  );
}

class DnsStats {
  final int queries;
  final int cacheHits;
  final int failures;
  final int blocked;
  final int cached;
  DnsStats({
    required this.queries,
    required this.cacheHits,
    required this.failures,
    required this.blocked,
    required this.cached,
  });

  factory DnsStats.fromJson(Map<String, dynamic>? j) => DnsStats(
    queries: _i(j?['queries']),
    cacheHits: _i(j?['cacheHits']),
    failures: _i(j?['failures']),
    blocked: _i(j?['blocked']),
    cached: _i(j?['cached']),
  );
}

class Stats {
  final String version;
  final int uptimeMs;
  final int users;
  final int sessionsActive;
  final int rateUp;
  final int rateDown;
  final Metrics metrics;
  final SysInfo sys;
  final FilterStats filter;
  final DnsStats dns;
  Stats({
    required this.version,
    required this.uptimeMs,
    required this.users,
    required this.sessionsActive,
    required this.rateUp,
    required this.rateDown,
    required this.metrics,
    required this.sys,
    required this.filter,
    required this.dns,
  });

  factory Stats.fromJson(Map<String, dynamic> j) => Stats(
    version: (j['version'] ?? '').toString(),
    uptimeMs: _i(j['uptimeMs']),
    users: _i(j['users']),
    sessionsActive: _i(j['sessionsActive']),
    rateUp: _i(j['rateUp']),
    rateDown: _i(j['rateDown']),
    metrics: Metrics.fromJson(j['metrics'] ?? {}),
    sys: SysInfo.fromJson(j['sys']),
    filter: FilterStats.fromJson(j['filter']),
    dns: DnsStats.fromJson(j['dns']),
  );

  int get versionInt {
    final parts = version.split('.');
    var v = 0;
    for (var i = 0; i < 3 && i < parts.length; i++) {
      v = v * 100 + (int.tryParse(parts[i]) ?? 0);
    }
    return v;
  }
}

class UserView {
  final String email;
  final String uuid;
  final int level;
  final int expiryUnix;
  final int quotaBytes;
  final bool disabled;
  final int usedBytes;
  final int upBytes;
  final int downBytes;
  final int liveUp;
  final int liveDown;
  final int rateUp;
  final int rateDown;
  final int liveSessions;
  UserView({
    required this.email,
    required this.uuid,
    required this.level,
    required this.expiryUnix,
    required this.quotaBytes,
    required this.disabled,
    required this.usedBytes,
    required this.upBytes,
    required this.downBytes,
    required this.liveUp,
    required this.liveDown,
    required this.rateUp,
    required this.rateDown,
    required this.liveSessions,
  });

  bool get live => liveSessions > 0;

  factory UserView.fromJson(Map<String, dynamic> j) => UserView(
    email: (j['email'] ?? '').toString(),
    uuid: (j['uuid'] ?? '').toString(),
    level: _i(j['level']),
    expiryUnix: _i(j['expiryUnix']),
    quotaBytes: _i(j['quotaBytes']),
    disabled: j['disabled'] == true,
    usedBytes: _i(j['usedBytes']),
    upBytes: _i(j['upBytes']),
    downBytes: _i(j['downBytes']),
    liveUp: _i(j['liveUp']),
    liveDown: _i(j['liveDown']),
    rateUp: _i(j['rateUp']),
    rateDown: _i(j['rateDown']),
    liveSessions: _i(j['liveSessions']),
  );
}

class SessionInfo {
  final String id;
  final String user;
  final String host;
  final String target;
  final int chunks;
  final int up;
  final int down;
  final int sinceMs;
  final int rateUp;
  final int rateDown;
  final String state;
  final int finishedAt;
  SessionInfo({
    required this.id,
    required this.user,
    required this.host,
    required this.target,
    required this.chunks,
    required this.up,
    required this.down,
    required this.sinceMs,
    required this.rateUp,
    required this.rateDown,
    required this.state,
    required this.finishedAt,
  });

  bool get active => state == 'active';
  Duration get duration => finishedAt > 0
      ? Duration(milliseconds: sinceMs)
      : Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - sinceMs);

  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
    id: (j['id'] ?? '').toString(),
    user: (j['user'] ?? '').toString(),
    host: (j['host'] ?? '').toString(),
    target: (j['target'] ?? '').toString(),
    chunks: _i(j['chunks']),
    up: _i(j['up']),
    down: _i(j['down']),
    sinceMs: _i(j['sinceMs']),
    rateUp: _i(j['rateUp']),
    rateDown: _i(j['rateDown']),
    state: (j['state'] ?? 'active').toString(),
    finishedAt: _i(j['finishedAt']),
  );
}

class ListSourceView {
  final String name;
  final String url;
  final String category;
  final bool enabled;
  ListSourceView({
    required this.name,
    required this.url,
    required this.category,
    required this.enabled,
  });

  factory ListSourceView.fromJson(Map<String, dynamic> j) => ListSourceView(
    name: (j['name'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
    category: (j['category'] ?? '').toString(),
    enabled: j['enabled'] == true,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'category': category,
    'enabled': enabled,
  };
}

class SourceStatus {
  final String name;
  final int entries;
  final int lastUpdate;
  final String lastError;
  SourceStatus({
    required this.name,
    required this.entries,
    required this.lastUpdate,
    required this.lastError,
  });

  factory SourceStatus.fromJson(Map<String, dynamic> j) => SourceStatus(
    name: (j['name'] ?? '').toString(),
    entries: _i(j['entries']),
    lastUpdate: _i(j['lastUpdate']),
    lastError: (j['lastError'] ?? '').toString(),
  );
}

class RecentBlock {
  final int ts;
  final String user;
  final String target;
  final String category;
  RecentBlock({
    required this.ts,
    required this.user,
    required this.target,
    required this.category,
  });

  factory RecentBlock.fromJson(Map<String, dynamic> j) => RecentBlock(
    ts: _i(j['ts']),
    user: (j['user'] ?? '').toString(),
    target: (j['target'] ?? '').toString(),
    category: (j['category'] ?? '').toString(),
  );
}

class FilterConfigView {
  final bool enabled;
  final bool blockTorrents;
  final List<ListSourceView> sources;
  final List<String> customDomains;
  FilterConfigView({
    required this.enabled,
    required this.blockTorrents,
    required this.sources,
    required this.customDomains,
  });

  factory FilterConfigView.fromJson(Map<String, dynamic>? j) =>
      FilterConfigView(
        enabled: j?['enabled'] == true,
        blockTorrents: j?['blockTorrents'] == true,
        sources: ((j?['sources'] ?? []) as List)
            .whereType<Map<String, dynamic>>()
            .map(ListSourceView.fromJson)
            .toList(),
        customDomains: ((j?['customDomains'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'blockTorrents': blockTorrents,
    'sources': sources.map((s) => s.toJson()).toList(),
    'customDomains': customDomains,
  };
}

class FilterInfo {
  final FilterConfigView config;
  final FilterStats stats;
  final List<SourceStatus> sources;
  final List<RecentBlock> recent;
  FilterInfo({
    required this.config,
    required this.stats,
    required this.sources,
    required this.recent,
  });

  factory FilterInfo.fromJson(Map<String, dynamic> j) => FilterInfo(
    config: FilterConfigView.fromJson(j['config']),
    stats: FilterStats.fromJson(j['stats']),
    sources: ((j['stats'] ?? const {})['sources'] ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SourceStatus.fromJson)
        .toList(),
    recent: ((j['stats'] ?? const {})['recent'] ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RecentBlock.fromJson)
        .toList(),
  );
}

class DnsTopEntry {
  final String domain;
  final int count;
  DnsTopEntry({required this.domain, required this.count});

  factory DnsTopEntry.fromJson(Map<String, dynamic> j) => DnsTopEntry(
    domain: (j['domain'] ?? '').toString(),
    count: _i(j['count']),
  );
}

class DnsConfigView {
  final List<String> servers;
  DnsConfigView({required this.servers});

  factory DnsConfigView.fromJson(Map<String, dynamic>? j) => DnsConfigView(
    servers: ((j?['servers'] ?? []) as List).map((e) => e.toString()).toList(),
  );

  Map<String, dynamic> toJson() => {'servers': servers};
}

class DnsInfo {
  final DnsConfigView config;
  final DnsStats stats;
  final List<DnsTopEntry> top;
  DnsInfo({required this.config, required this.stats, required this.top});

  factory DnsInfo.fromJson(Map<String, dynamic> j) => DnsInfo(
    config: DnsConfigView.fromJson(j['config']),
    stats: DnsStats.fromJson(j['stats']),
    top: (((j['stats'] ?? const {})['top'] ?? const []) as List)
        .whereType<Map<String, dynamic>>()
        .map(DnsTopEntry.fromJson)
        .toList(),
  );
}

class CertInfo {
  final String mode;
  final String subject;
  final String issuer;
  final int notAfter;
  final double daysLeft;
  final String fingerprint;
  CertInfo({
    required this.mode,
    required this.subject,
    required this.issuer,
    required this.notAfter,
    required this.daysLeft,
    required this.fingerprint,
  });

  bool get isReal => mode == 'real';

  factory CertInfo.fromJson(Map<String, dynamic> j) => CertInfo(
    mode: (j['mode'] ?? '').toString(),
    subject: (j['subject'] ?? '').toString(),
    issuer: (j['issuer'] ?? '').toString(),
    notAfter: _i(j['notAfter']),
    daysLeft: _d(j['daysLeft']),
    fingerprint: (j['fingerprint'] ?? '').toString(),
  );
}

class LogEntry {
  final int ts;
  final String level;
  final String msg;
  LogEntry({required this.ts, required this.level, required this.msg});

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
    ts: _i(j['ts']),
    level: (j['level'] ?? '').toString(),
    msg: (j['msg'] ?? '').toString(),
  );
}

class ClientConfigView {
  final String serverAddr;
  final String uuid;
  final String host;
  final String shareLink;
  final List<String> endpointPaths;
  ClientConfigView({
    required this.serverAddr,
    required this.uuid,
    required this.host,
    required this.shareLink,
    required this.endpointPaths,
  });

  factory ClientConfigView.fromJson(Map<String, dynamic> j) => ClientConfigView(
    serverAddr: (j['serverAddr'] ?? '').toString(),
    uuid: (j['uuid'] ?? '').toString(),
    host: (j['host'] ?? '').toString(),
    shareLink: (j['shareLink'] ?? '').toString(),
    endpointPaths: ((j['endpointPaths'] ?? []) as List)
        .map((e) => e.toString())
        .toList(),
  );
}

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
