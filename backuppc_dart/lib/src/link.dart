/// Share-ссылки `backuppc://` (совместимы с Go-реализацией `core/link`).
///
///     backuppc://<uuid>@<server-host>:<port>/?host=<домен-донор>&fp=<sha256>&insecure=0#My%20Server
///
/// Разворачивается в JSON outbound-а Xray с `protocol == "backuppc"`;
/// settings совпадают со схемой транспортной библиотеки.
library;

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
    final b = StringBuffer()
      ..write(backuppcScheme)
      ..write('://')
      ..write(Uri.encodeComponent(uuid))
      ..write('@')
      ..write(_netJoinHostPort(host, port));
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
