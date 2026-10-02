/// Протокол backuppc в приложении: связь outbound-модели Xray с
/// Dart-транспортом [backuppc_dart].
///
/// Профиль сервера хранится как обычный outbound с
/// `protocol == "backuppc"` (требование: «клиент написан под разные
/// платформы и все они должны поддерживаться, те приложение должно
/// собирать и в его интерфейсе должен быть протокол //backuppc» —
/// реализация протокола на чистом Dart без нативных артефактов,
/// приложение собирается на всех платформах OneXray).
library;

import 'dart:io';

import 'package:backuppc_dart/backuppc_dart.dart';

const String backuppcProtocol = 'backuppc';

/// Это outbound протокола backuppc?
bool isBackupPcOutbound(Map<String, dynamic> outbound) =>
    outbound['protocol'] == backuppcProtocol;

/// Настройки outbound → [ClientConfig] Dart-транспорта.
/// Схема settings совпадает с Go-библиотекой (serverAddr, uuid, host,
/// certFingerprint, insecure, userAgent, endpointPaths, паддинг,
/// тюнинг ротации).
ClientConfig? backuppcClientConfig(Map<String, dynamic> outbound) {
  final settings = outbound['settings'];
  if (settings is! Map<String, dynamic>) {
    return null;
  }
  final serverAddr = settings['serverAddr'];
  final uuid = settings['uuid'];
  if (serverAddr is! String || serverAddr.isEmpty || uuid is! String) {
    return null;
  }
  final transport = <String, dynamic>{};
  const passthrough = [
    'host',
    'userAgent',
    'endpointPaths',
    'minPaddingSize',
    'maxPaddingSize',
    'pingBaseInterval',
    'pingJitterMax',
    'balancingInterval',
    'minTxThreshold',
    'maxSessionDuration',
    'maxSessionBytes',
    'maxWriteChunk',
    'fakeUploadChunk',
    'idleTimeout',
    'dialRetries',
  ];
  for (final key in passthrough) {
    if (settings.containsKey(key) && settings[key] != null) {
      transport[key] = settings[key];
    }
  }
  final backuppc = settings['backuppc'];
  if (backuppc is Map<String, dynamic>) {
    transport['backuppc'] = backuppc;
  }
  return ClientConfig.fromJson({
    'serverAddr': serverAddr,
    'uuid': uuid,
    'insecure': settings['insecure'] == true,
    'certFingerprint': settings['certFingerprint'],
    'transport': transport,
  });
}

/// Кандидаты адресов сервера для анти-петлевого правила маршрутизации
/// «адрес VPN-сервера → direct»: туннель сам ходит к серверу, а TUN
/// заворачивает его трафик обратно в прокси (Android/iOS/macOS), поэтому
/// соединения туннеля обязаны уходить напрямую.
(List<String> ips, List<String> domains) backuppcServerRoutes(
  Map<String, dynamic> outbound,
) {
  final settings = outbound['settings'];
  if (settings is! Map<String, dynamic>) {
    return (const [], const []);
  }
  final serverAddr = settings['serverAddr'];
  if (serverAddr is! String || serverAddr.isEmpty) {
    return (const [], const []);
  }
  final i = serverAddr.lastIndexOf(':');
  var host = i < 0 ? serverAddr : serverAddr.substring(0, i);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  final ips = <String>[];
  final domains = <String>[];
  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    ips.add(host);
  } else if (host.isNotEmpty) {
    domains.add(host);
  }
  final donor = settings['host'];
  if (donor is String && donor.trim().isNotEmpty) {
    domains.add(donor.trim());
  }
  return (ips, domains);
}

/// Адрес (домен) сервера для пинга.
(String, int)? backuppcPingTarget(Map<String, dynamic> outbound) {
  final cfg = backuppcClientConfig(outbound);
  if (cfg == null) {
    return null;
  }
  final (host, port) = cfg.splitServerAddr();
  if (host.isEmpty) {
    return null;
  }
  return (host, port);
}

/// Dart-валидация outbound (замена нативному testXray, который не знает
/// протокола). Возвращает ошибку или null.
String? validateBackupPcOutbound(Map<String, dynamic> outbound) {
  final link = BackupPcLink.fromOutboundJson(outbound);
  if (link == null) {
    return 'backuppc: ожидается settings.serverAddr и settings.uuid';
  }
  final cfg = backuppcClientConfig(outbound);
  if (cfg == null) {
    return 'backuppc: некорректные настройки';
  }
  return cfg.validate();
}

/// Outbound → share-ссылка backuppc:// (экспорт).
String? backuppcShareLink(Map<String, dynamic> outbound) {
  final link = BackupPcLink.fromOutboundJson(outbound);
  if (link == null) {
    return null;
  }
  // endpoints обязателен: без него клиент ротирует чанки по дефолтному
  // пулу путей, который сервер отвергает как проб-активность
  var result = link.build();
  if (link.endpointPaths.isEmpty && !result.contains('endpoints=')) {
    final eps = TransportConfig.defaultEndpointPaths.join(',');
    result = result.replaceFirst(
      '?',
      '?endpoints=${Uri.encodeQueryComponent(eps)}&',
    );
  }
  return result;
}
