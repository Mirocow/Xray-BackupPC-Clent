/// Share-ссылки `backuppc://` (совместимы с Go-реализацией `core/link`).
///
///     backuppc://<uuid>@<server-host>:<port>/?host=<домен-донор>&fp=<sha256>&insecure=0#My%20Server
///
/// Разворачивается в JSON outbound-а Xray с `protocol == "backuppc"`;
/// settings совпадают со схемой транспортной библиотеки.
library;

import 'package:crypto/crypto.dart';

const String backuppcScheme = 'backuppc';

/// Модель outbound-а для генерации/разбора ссылки.
class BackupPcLink {
  String tag;
  String serverAddr; // host:port
  String uuid;
  String host; // домен-донор (SNI/:authority)
  String certFingerprint; // sha256 hex
  bool insecure;
  String userAgent;
  List<String> endpointPaths;
  int minPadding;
  int maxPadding;
  // V2 auth + uTLS support (audit 2026-10-12, Marvia-inspired).
  bool useV2Auth; // ?useV2Auth=1 → V2 auth (sid|idx|tsMin)
  String utlsTunnelPath; // ?utlsTunnelPath=/path → spawn utls-tunnel sidecar
  String utFingerprint; // ?utFingerprint=chrome|firefox|safari|ios|random
  String serverNoisePubKey; // ?noisePubKey=<hex> or /v2/full/noise path

  BackupPcLink({
    this.tag = '',
    required this.serverAddr,
    required this.uuid,
    this.host = '',
    this.certFingerprint = '',
    this.insecure = false,
    this.userAgent = '',
    List<String>? endpointPaths,
    this.minPadding = 0,
    this.maxPadding = 0,
    this.useV2Auth = false,
    this.utlsTunnelPath = '',
    this.utFingerprint = '',
    this.serverNoisePubKey = '',
  }) : endpointPaths =
           endpointPaths == null ? const [] : List.unmodifiable(endpointPaths);

  static String _netJoinHostPort(String host, int port) {
    final needsBrackets = host.contains(':') && !host.startsWith('[');
    return '${needsBrackets ? '[$host]' : host}:$port';
  }

  static (String, int) _splitServerAddr(String addr) {
    final i = addr.lastIndexOf(':');
    if (i < 0) return (addr, 443);
    final port = int.tryParse(addr.substring(i + 1));
    if (port == null || port <= 0 || port >= 65536) return (addr, 443);
    var host = addr.substring(0, i);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    return (host, port);
  }

  /// Разбор `backuppc://`-ссылки. Порт опускается → 443.
  static BackupPcLink? tryParse(String link) {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;
    final Uri? uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      return null;
    }
    if (uri.scheme.toLowerCase() != backuppcScheme) return null;
    final uuid = uri.userInfo;
    if (uuid.isEmpty) return null;
    var host = uri.host;
    if (host.isEmpty) return null;
    var port = 443;
    if (uri.hasPort) {
      final p = uri.port;
      if (p <= 0 || p >= 65536) return null;
      port = p;
    }
    final out = BackupPcLink(
      serverAddr: _netJoinHostPort(host, port),
      uuid: uuid,
    );
    // V2 path encoding (audit 2026-10-12): /v2 = ALL features ON.
    // V2 = V2 auth (SHA256(uuid) HMAC key) + uTLS (Chrome) + adaptivePadding.
    // Noise layer enabled if serverNoisePubKey is set via ?noisePubKey=.
    // User info in V2 URL = hash(uuid) (SHA256 hex), NOT raw UUID.
    //
    //   /v2?host=...           → V2 everything ON
    //   (no /v2)               → V1 legacy (raw UUID, V1 auth, no uTLS)
    if (uri.path.isNotEmpty) {
      final segs = uri.path.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty && segs.first.toLowerCase() == 'v2') {
        out.useV2Auth = true;
        // V2 = uTLS always ON.
        if (out.utlsTunnelPath.isEmpty) {
          out.utlsTunnelPath = '/usr/local/bin/utls-tunnel';
        }
        // V2 = adaptivePadding ON (wider range for stealth).
        out.minPadding = 32;
        out.maxPadding = 4096;
        // Noise: query param only (?noisePubKey=<hex> or ?npk=<hex>).
        // Not a path segment — V2 path is just /v2, nothing more.
      }
    }
    final q = uri.queryParameters;
    out.host = (q['host'] ?? q['sni'] ?? '').trim();
    var fp = (q['fp'] ?? q['fingerprint'] ?? '').trim().toLowerCase();
    if (fp.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp)) {
      return null;
    }
    out.certFingerprint = fp;
    switch (q['insecure']?.toLowerCase() ?? '') {
      case '1' || 'true' || 'yes':
        out.insecure = true;
      case '' || '0' || 'false' || 'no':
        break;
      default:
        return null;
    }
    out.userAgent = q['ua'] ?? '';
    // V2 auth + uTLS opt-in flags (audit 2026-10-12, Marvia-inspired).
    // ?useV2Auth=1 → V2 auth (sid|idx|tsMin + X-Backup-Timestamp header)
    switch (q['useV2Auth']?.toLowerCase() ?? '') {
      case '1' || 'true' || 'yes':
        out.useV2Auth = true;
      case '' || '0' || 'false' || 'no':
        break;
      default:
        return null;
    }
    // ?utlsTunnelPath=/usr/local/bin/utls-tunnel → spawn sidecar subprocess
    // for uTLS Chrome ClientHello fingerprint spoofing.
    out.utlsTunnelPath = (q['utlsTunnelPath'] ?? q['utls'] ?? '').trim();
    // ?utFingerprint=chrome|firefox|safari|ios|random
    // (only used when utlsTunnelPath is non-empty)
    out.utFingerprint = (q['utFingerprint'] ?? q['utfp'] ?? '').trim();
    // ?noisePubKey=<hex> or ?npk=<hex> → server's Noise public key.
    // Overrides 'auto' marker from /v2/full/noise path.
    final noiseKey = (q['noisePubKey'] ?? q['npk'] ?? '').trim();
    if (noiseKey.isNotEmpty) {
      out.serverNoisePubKey = noiseKey;
    }
    final eps = q['endpoints'];
    if (eps != null && eps.trim().isNotEmpty) {
      final list = [
        for (final e in eps.split(','))
          if (e.trim().isNotEmpty) e.trim(),
      ];
      if (list.isEmpty) return null;
      if (list.any((e) => !e.startsWith('/'))) return null;
      out.endpointPaths = List.unmodifiable(list);
    }
    final pad = q['pad'];
    if (pad != null && pad.trim().isNotEmpty) {
      final parts = pad.split('-');
      if (parts.length != 2) return null;
      final lo = int.tryParse(parts[0].trim());
      final hi = int.tryParse(parts[1].trim());
      if (lo == null || hi == null || lo <= 0 || hi < lo || hi > 0xFFFF) {
        return null;
      }
      out.minPadding = lo;
      out.maxPadding = hi;
    }
    out.tag = _decodeFragment(uri.fragment);
    return out;
  }

  /// Go декодирует фрагмент (u.Fragment — decoded); Dart хранит сырым.
  static String _decodeFragment(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    try {
      return Uri.decodeComponent(t).trim();
    } on FormatException {
      return t; // невалидные побегы — оставляем как есть (мягкий режим)
    }
  }

  /// _hashUuid — SHA256(uuid) → hex (64 chars). V2 URL user info.
  static String _hashUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    final bytes = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return sha256.convert(bytes).toString();
  }

  /// JSON outbound-а Xray (один элемент outbounds), совместим с Go.
  Map<String, dynamic> toOutboundJson() {
    final settings = <String, dynamic>{
      'serverAddr': serverAddr,
      'uuid': uuid,
    };
    if (host.isNotEmpty) settings['host'] = host;
    if (certFingerprint.isNotEmpty) settings['certFingerprint'] = certFingerprint;
    if (insecure) settings['insecure'] = true;
    if (userAgent.isNotEmpty) settings['userAgent'] = userAgent;
    if (endpointPaths.isNotEmpty) settings['endpointPaths'] = endpointPaths;
    if (minPadding != 0 && maxPadding != 0) {
      settings['minPaddingSize'] = minPadding;
      settings['maxPaddingSize'] = maxPadding;
    }
    // V2 auth + uTLS opt-in (audit 2026-10-12, Marvia-inspired).
    if (useV2Auth) settings['useV2Auth'] = true;
    if (utlsTunnelPath.isNotEmpty) settings['utlsTunnelPath'] = utlsTunnelPath;
    if (utFingerprint.isNotEmpty) settings['utFingerprint'] = utFingerprint;
    final outbound = <String, dynamic>{
      'protocol': backuppcScheme,
      'settings': settings,
    };
    final t = tag.trim();
    if (t.isNotEmpty) outbound['tag'] = t;
    return outbound;
  }

  /// Обратное преобразование outbound-а Xray → ссылка.
  static BackupPcLink? fromOutboundJson(Map<String, dynamic> outbound) {
    if (outbound['protocol'] != backuppcScheme) return null;
    final settings = outbound['settings'];
    if (settings is! Map<String, dynamic>) return null;
    final serverAddr = settings['serverAddr'];
    final uuid = settings['uuid'];
    if (serverAddr is! String || serverAddr.isEmpty || uuid is! String) {
      return null;
    }
    List<String>? eps;
    final rawEps = settings['endpointPaths'];
    if (rawEps is List && rawEps.isNotEmpty) {
      eps = [for (final e in rawEps) e.toString()];
    }
    return BackupPcLink(
      tag: outbound['tag'] is String ? outbound['tag'] as String : '',
      serverAddr: serverAddr,
      uuid: uuid,
      host: settings['host'] is String ? settings['host'] as String : '',
      certFingerprint: settings['certFingerprint'] is String
          ? (settings['certFingerprint'] as String).toLowerCase()
          : '',
      insecure: settings['insecure'] == true,
      userAgent: settings['userAgent'] is String
          ? settings['userAgent'] as String
          : '',
      endpointPaths: eps,
      minPadding: settings['minPaddingSize'] is int
          ? settings['minPaddingSize'] as int
          : 0,
      maxPadding: settings['maxPaddingSize'] is int
          ? settings['maxPaddingSize'] as int
          : 0,
    );
  }

  /// Сборка share-ссылки (обратный [tryParse]).
  String build() {
    final (host, port) = _splitServerAddr(serverAddr);
    final params = <String, String>{};
    if (this.host.isNotEmpty) params['host'] = this.host;
    if (certFingerprint.isNotEmpty) params['fp'] = certFingerprint;
    if (insecure) params['insecure'] = '1';
    if (userAgent.isNotEmpty) params['ua'] = userAgent;
    if (endpointPaths.isNotEmpty) {
      params['endpoints'] = endpointPaths.join(',');
    }
    if (minPadding != 0 && maxPadding != 0) {
      params['pad'] = '$minPadding-$maxPadding';
    }
    // V2 auth + uTLS opt-in (audit 2026-10-12, Marvia-inspired).
    if (useV2Auth) params['useV2Auth'] = '1';
    if (utlsTunnelPath.isNotEmpty) params['utlsTunnelPath'] = utlsTunnelPath;
    if (utFingerprint.isNotEmpty) params['utFingerprint'] = utFingerprint;
    if (serverNoisePubKey.isNotEmpty) params['noisePubKey'] = serverNoisePubKey;
    final b = StringBuffer()
      ..write(backuppcScheme)
      ..write('://')
      // V2: user info = hash(uuid) (SHA256 hex), NOT raw UUID.
      // V1: user info = raw UUID.
      ..write(Uri.encodeComponent(
          useV2Auth ? _hashUuid(uuid) : uuid))
      ..write('@')
      ..write(_netJoinHostPort(host, port));
    // V2 path = just /v2 (ALL features ON, no sub-paths).
    if (useV2Auth) {
      b.write('/v2');
    }
    if (params.isNotEmpty) {
      final query = params.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}='
                '${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');
      b.write('?');
      b.write(query);
    }
    final t = tag.trim();
    if (t.isNotEmpty) {
      b.write('#');
      b.write(Uri.encodeComponent(t));
    }
    return b.toString();
  }
}
