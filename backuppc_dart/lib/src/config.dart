/// Конфигурация транспорта — контракт совместим с Go-библиотекой сервера
/// (`internal/backupemulator/config.go`): одинаковые имена полей JSON,
/// длительности принимаются строками ("20s", "15m") и секундами (float).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'random.dart';

/// Длительность с человекочитаемым JSON: `"20s"`, `"1.5h"` или `90` (секунды).
class Duration_ {
  final Duration value;
  const Duration_(this.value);
  static const zero = Duration_(Duration.zero);

  factory Duration_.parse(Object? raw) {
    if (raw == null) return zero;
    if (raw is num) return Duration_(
      Duration(microseconds: (raw * 1e6).round()),
    );
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return zero;
      final v = parseDuration(s);
      if (v == null) {
        throw FormatException('config: некорректная длительность "$s"');
      }
      return Duration_(v);
    }
    throw const FormatException('config: длительность должна быть строкой или числом');
  }

  static Duration? parseDuration(String s) {
    // принимает Go-стиль: 20s, 15m, 1.5h, 250ms, 1h30m; "0" — ноль
    if (s == '0') return Duration.zero;
    var rest = s;
    var micros = 0;
    final re = RegExp(r'^(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)');
    while (rest.isNotEmpty) {
      final m = re.firstMatch(rest);
      if (m == null) return null;
      final n = double.parse(m.group(1)!);
      final unit = m.group(2)!;
      switch (unit) {
        case 'ns': micros += (n / 1000).round();
        case 'us' || 'µs': micros += n.round();
        case 'ms': micros += (n * 1000).round();
        case 's': micros += (n * 1e6).round();
        case 'm': micros += (n * 60e6).round();
        case 'h': micros += (n * 3600e6).round();
      }
      rest = rest.substring(m.end);
    }
    return Duration(microseconds: micros);
  }

  Object toJson() => value.inMicroseconds == 0
      ? '0s'
      : _pretty();
  String _pretty() {
    var us = value.inMicroseconds;
    if (us == 0) return '0s';
    if (us < 1000) return '${us}us';
    if (us < 1000000) {
      return us % 1000 == 0 ? '${us ~/ 1000}ms' : '${us}us';
    }
    final h = us ~/ 3600000000;
    us %= 3600000000;
    final m = us ~/ 60000000;
    us %= 60000000;
    final s = us ~/ 1000000;
    final remUs = us % 1000000;
    final sb = StringBuffer();
    if (h > 0) sb.write('${h}h');
    if (m > 0) sb.write('${m}m');
    // Go-стиль: при наличии крупных единиц секунды пишутся всегда ("1h30m0s")
    if (s > 0 || h > 0 || m > 0 || remUs > 0) {
      var frac = '';
      if (remUs > 0) {
        frac = (remUs / 1e6)
            .toStringAsFixed(6)
            .replaceFirst(RegExp(r'^0'), '')
            .replaceAll(RegExp(r'0+$'), '');
        if (frac == '.') frac = '';
      }
      sb.write('${s}${frac}s');
    }
    return sb.toString();
  }

  @override
  String toString() => value.toString();
}

/// Профиль эмуляции периодических бекапов BackupPC.
class BackupPCConfig {
  bool? enabled; // null → включено
  bool idleOnly; // псевдо-бэкапы только при простое
  Duration_ incrementalEvery;
  int incrementalMinBytes;
  int incrementalMaxBytes;
  Duration_ fullEvery;
  int fullMinBytes;
  int fullMaxBytes;
  int nightStartHour;
  int nightEndHour;

  BackupPCConfig({
    this.enabled,
    this.idleOnly = true,
    this.incrementalEvery = const Duration_(Duration(minutes: 25)),
    this.incrementalMinBytes = 2 * 1024 * 1024,
    this.incrementalMaxBytes = 8 * 1024 * 1024,
    this.fullEvery = const Duration_(Duration(hours: 8)),
    this.fullMinBytes = 32 * 1024 * 1024,
    this.fullMaxBytes = 128 * 1024 * 1024,
    this.nightStartHour = 22,
    this.nightEndHour = 6,
  });

  bool get enabledOn => enabled ?? true;

  factory BackupPCConfig.fromJson(Map<String, dynamic> json) {
    final c = BackupPCConfig();
    c.enabled = json['enabled'] as bool?;
    c.idleOnly = json['idleOnly'] as bool? ?? true;
    c.incrementalEvery = Duration_.parse(json['incrementalEvery']);
    c.incrementalMinBytes = json['incrementalMinBytes'] as int? ?? c.incrementalMinBytes;
    c.incrementalMaxBytes = json['incrementalMaxBytes'] as int? ?? c.incrementalMaxBytes;
    c.fullEvery = Duration_.parse(json['fullEvery']);
    c.fullMinBytes = json['fullMinBytes'] as int? ?? c.fullMinBytes;
    c.fullMaxBytes = json['fullMaxBytes'] as int? ?? c.fullMaxBytes;
    c.nightStartHour = json['nightStartHour'] as int? ?? 22;
    c.nightEndHour = json['nightEndHour'] as int? ?? 6;
    return c;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'idleOnly': idleOnly,
    'incrementalEvery': incrementalEvery.toJson(),
    'incrementalMinBytes': incrementalMinBytes,
    'incrementalMaxBytes': incrementalMaxBytes,
    'fullEvery': fullEvery.toJson(),
    'fullMinBytes': fullMinBytes,
    'fullMaxBytes': fullMaxBytes,
    'nightStartHour': nightStartHour,
    'nightEndHour': nightEndHour,
  };
}

/// Общая конфигурация транспорта (клиент и сервер), ТЗ раздел 2.
class TransportConfig {
  // Мимикрия
  List<String> endpointPaths;
  String host; // домен-донор (SNI/Host)
  String userAgent; // пусто → пул агентов BackupPC

  // Паддинг (ТЗ 3.1)
  int minPaddingSize;
  int maxPaddingSize;

  // Джиттер пингов (ТЗ 3.2)
  Duration_ pingBaseInterval;
  Duration_ pingJitterMax;

  // Балансировка асимметрии (ТЗ 3.3)
  Duration_ balancingInterval;
  int minTxThreshold;

  // Дробление сессий (ТЗ 3.4)
  Duration_ maxSessionDuration;
  int maxSessionBytes;

  // Эмуляция BackupPC (раздел 4)
  BackupPCConfig backuppc;

  // Расширения
  int maxWriteChunk;
  int fakeUploadChunk;
  Duration_ idleTimeout;
  int dialRetries;
  Duration_ rotationGrace;
  Duration_ rotationHandoff;

  TransportConfig({
    List<String>? endpointPaths,
    this.host = '',
    this.userAgent = '',
    this.minPaddingSize = 32,
    this.maxPaddingSize = 1400,
    Duration? pingBaseInterval,
    Duration? pingJitterMax,
    Duration? balancingInterval,
    this.minTxThreshold = 16384,
    Duration? maxSessionDuration,
    this.maxSessionBytes = 2 * 1024 * 1024 * 1024,
    BackupPCConfig? backuppc,
    this.maxWriteChunk = 16384,
    this.fakeUploadChunk = 512 * 1024,
    Duration? idleTimeout,
    this.dialRetries = 3,
    Duration? rotationGrace,
    Duration? rotationHandoff,
  }) : endpointPaths = endpointPaths ?? defaultEndpointPaths,
       pingBaseInterval = Duration_(pingBaseInterval ?? const Duration(seconds: 20)),
       pingJitterMax = Duration_(pingJitterMax ?? const Duration(seconds: 15)),
       balancingInterval = Duration_(balancingInterval ?? const Duration(seconds: 5)),
       maxSessionDuration = Duration_(maxSessionDuration ?? const Duration(minutes: 30)),
       backuppc = backuppc ?? BackupPCConfig(),
       idleTimeout = Duration_(idleTimeout ?? const Duration(seconds: 90)),
       rotationGrace = Duration_(rotationGrace ?? const Duration(milliseconds: 250)),
       rotationHandoff = Duration_(rotationHandoff ?? const Duration(seconds: 3));

  static const defaultEndpointPaths = [
    '/backuppc.BackupService/BackupStream',
    '/backuppc.ChunkService/PutChunk',
    '/backuppc.StorageService/UploadStream',
  ];

  /// Случайный несущий gRPC-метод из пула (каждая ротация — новый метод).
  String randomEndpoint() {
    if (endpointPaths.isEmpty) return defaultEndpointPaths.first;
    return endpointPaths[randIntRange(0, endpointPaths.length - 1)];
  }

  int randPadding() =>
      minPaddingSize + randIntRange(0, maxPaddingSize - minPaddingSize);

  factory TransportConfig.fromJson(Map<String, dynamic> json) {
    final c = TransportConfig();
    final eps = json['endpointPaths'];
    if (eps is List && eps.isNotEmpty) {
      c.endpointPaths = [for (final e in eps) e.toString()];
    }
    c.host = json['host'] as String? ?? '';
    c.userAgent = json['userAgent'] as String? ?? '';
    c.minPaddingSize = json['minPaddingSize'] as int? ?? 32;
    c.maxPaddingSize = json['maxPaddingSize'] as int? ?? 1400;
    c.pingBaseInterval = Duration_.parse(json['pingBaseInterval'] ?? '20s');
    c.pingJitterMax = Duration_.parse(json['pingJitterMax'] ?? '15s');
    c.balancingInterval = Duration_.parse(json['balancingInterval'] ?? '5s');
    c.minTxThreshold = json['minTxThreshold'] as int? ?? 16384;
    c.maxSessionDuration = Duration_.parse(json['maxSessionDuration'] ?? '30m');
    c.maxSessionBytes = json['maxSessionBytes'] as int? ?? 2 * 1024 * 1024 * 1024;
    final bc = json['backuppc'];
    c.backuppc = bc is Map<String, dynamic> ? BackupPCConfig.fromJson(bc) : BackupPCConfig();
    c.maxWriteChunk = json['maxWriteChunk'] as int? ?? 16384;
    c.fakeUploadChunk = json['fakeUploadChunk'] as int? ?? 512 * 1024;
    c.idleTimeout = Duration_.parse(json['idleTimeout'] ?? '90s');
    c.dialRetries = json['dialRetries'] as int? ?? 3;
    c.rotationGrace = Duration_.parse(json['rotationGrace'] ?? '250ms');
    c.rotationHandoff = Duration_.parse(json['rotationHandoff'] ?? '3s');
    return c;
  }

  Map<String, dynamic> toJson() => {
    'endpointPaths': endpointPaths,
    'host': host,
    'userAgent': userAgent,
    'minPaddingSize': minPaddingSize,
    'maxPaddingSize': maxPaddingSize,
    'pingBaseInterval': pingBaseInterval.toJson(),
    'pingJitterMax': pingJitterMax.toJson(),
    'balancingInterval': balancingInterval.toJson(),
    'minTxThreshold': minTxThreshold,
    'maxSessionDuration': maxSessionDuration.toJson(),
    'maxSessionBytes': maxSessionBytes,
    'backuppc': backuppc.toJson(),
    'maxWriteChunk': maxWriteChunk,
    'fakeUploadChunk': fakeUploadChunk,
    'idleTimeout': idleTimeout.toJson(),
    'dialRetries': dialRetries,
    'rotationGrace': rotationGrace.toJson(),
    'rotationHandoff': rotationHandoff.toJson(),
  };

  void applyDefaults() {
    if (endpointPaths.isEmpty) endpointPaths = List.of(defaultEndpointPaths);
    if (minPaddingSize == 0) minPaddingSize = 32;
    if (maxPaddingSize == 0) maxPaddingSize = 1400;
    if (pingBaseInterval.value == Duration.zero) {
      pingBaseInterval = const Duration_(Duration(seconds: 20));
    }
    if (pingJitterMax.value == Duration.zero && pingJitterMax.value.isNegative == false) {
      pingJitterMax = const Duration_(Duration(seconds: 15));
    }
    if (balancingInterval.value == Duration.zero) {
      balancingInterval = const Duration_(Duration(seconds: 5));
    }
    if (minTxThreshold == 0) minTxThreshold = 16384;
    if (maxSessionDuration.value == Duration.zero) {
      maxSessionDuration = const Duration_(Duration(minutes: 30));
    }
    if (maxSessionBytes == 0) maxSessionBytes = 2 * 1024 * 1024 * 1024;
    if (maxWriteChunk == 0) maxWriteChunk = 16384;
    if (fakeUploadChunk == 0) fakeUploadChunk = 512 * 1024;
    if (idleTimeout.value == Duration.zero) {
      idleTimeout = const Duration_(Duration(seconds: 90));
    }
    if (dialRetries == 0) dialRetries = 3;
    if (rotationGrace.value == Duration.zero) {
      rotationGrace = const Duration_(Duration(milliseconds: 250));
    }
    if (rotationHandoff.value == Duration.zero) {
      rotationHandoff = const Duration_(Duration(seconds: 3));
    }
  }

  String? validate() {
    if (endpointPaths.isEmpty) return 'config: endpointPaths пуст';
    for (var i = 0; i < endpointPaths.length; i++) {
      if (!endpointPaths[i].startsWith('/')) {
        return 'config: endpointPaths[$i] должен начинаться с "/": ${endpointPaths[i]}';
      }
    }
    if (minPaddingSize < 0 ||
        maxPaddingSize > 0xFFFF ||
        minPaddingSize > maxPaddingSize) {
      return 'config: некорректные границы паддинга [$minPaddingSize..$maxPaddingSize]';
    }
    if (maxWriteChunk < 64 || maxWriteChunk > 0xFFFF) {
      return 'config: maxWriteChunk должен быть в [64..65535]: $maxWriteChunk';
    }
    if (pingBaseInterval.value <= Duration.zero) {
      return 'config: pingBaseInterval должен быть > 0';
    }
    if (maxSessionDuration.value <= Duration.zero) {
      return 'config: maxSessionDuration должен быть > 0';
    }
    if (maxSessionBytes <= 0) return 'config: maxSessionBytes > 0 обязателен';
    final bc = backuppc;
    if (bc.nightStartHour < 0 || bc.nightStartHour > 23 ||
        bc.nightEndHour < 0 || bc.nightEndHour > 23) {
      return 'config: ночное окно backuppc — часы 0..23';
    }
    if (bc.incrementalMinBytes < 0 ||
        bc.incrementalMaxBytes < bc.incrementalMinBytes ||
        bc.fullMinBytes < 0 ||
        bc.fullMaxBytes < bc.fullMinBytes) {
      return 'config: некорректные границы объемов backuppc';
    }
    return null;
  }
}

/// Конфигурация outbound-клиента (SOCKS5-туннель).
class ClientConfig {
  TransportConfig transport;
  String serverAddr; // host:port сервера xray-backuppc
  String uuid; // UUID пользователя VLESS
  String socksListen; // локальный SOCKS5, дефолт 127.0.0.1:1080
  bool insecure; // пропуск TLS-верификации (только тесты)
  String certFingerprint; // SHA-256 hex сервера — пиннинг

  ClientConfig({
    TransportConfig? transport,
    required this.serverAddr,
    required this.uuid,
    this.socksListen = '127.0.0.1:1080',
    this.insecure = false,
    this.certFingerprint = '',
  }) : transport = transport ?? TransportConfig();

  factory ClientConfig.fromJson(Map<String, dynamic> json) {
    final tc = json['transport'] is Map<String, dynamic>
        ? TransportConfig.fromJson(json['transport'] as Map<String, dynamic>)
        : TransportConfig.fromJson(json);
    final c = ClientConfig(
      transport: tc,
      serverAddr: json['serverAddr'] as String? ?? '',
      uuid: json['uuid'] as String? ?? '',
      socksListen: json['socksListen'] as String? ?? '127.0.0.1:1080',
      insecure: json['insecure'] as bool? ?? false,
      certFingerprint: (json['certFingerprint'] as String? ?? '').toLowerCase(),
    );
    return c;
  }

  Map<String, dynamic> toJson() => {
    ...transport.toJson(),
    'serverAddr': serverAddr,
    'uuid': uuid,
    'socksListen': socksListen,
    'insecure': insecure,
    'certFingerprint': certFingerprint,
  };

  String? validate() {
    if (serverAddr.isEmpty) return 'config: serverAddr обязателен';
    if (parseUUID(uuid) == null) return 'config: некорректный uuid';
    if (certFingerprint.isNotEmpty && insecure) {
      return 'config: указан и insecure, и certFingerprint — выберите одно';
    }
    return transport.validate();
  }

  /// host:port сервера → (host, port).
  (String, int) splitServerAddr() {
    final i = serverAddr.lastIndexOf(':');
    if (i < 0) return (serverAddr, 443);
    final port = int.tryParse(serverAddr.substring(i + 1));
    if (port == null || port <= 0) return (serverAddr, 443);
    var host = serverAddr.substring(0, i);
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    return (host, port);
  }
}

/// Разбор UUID (с дефисами и без) в 16 байт; null при ошибке.
Uint8List? parseUUID(String s) {
  final clean = s.replaceAll('-', '').trim();
  if (clean.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final byte = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

/// Загрузка ClientConfig из JSON-файла (как Go-клиент: -config config.json).
ClientConfig loadClientConfigFromJson(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('config: ожидается JSON-объект');
  }
  final cfg = ClientConfig.fromJson(json);
  final err = cfg.validate();
  if (err != null) throw FormatException(err);
  return cfg;
}
