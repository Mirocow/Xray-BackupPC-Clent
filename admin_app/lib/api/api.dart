/// REST-клиент Admin API сервера xray-backuppc.
///
/// Транспорт — dart:io HttpClient (без внешних зависимостей): панель
/// сервера слушает plain HTTP (за TLS обычно reverse-proxy), поэтому
/// поддержаны http:// и https://. Для https с самоподписанным
/// сертификатом — переключатель [acceptSelfSigned] (с предупреждением
/// в UI). Токен передается заголовком Authorization: Bearer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);

  @override
  String toString() => 'HTTP $status: $message';
}

class AdminApi {
  String baseUrl;
  String token;
  bool acceptSelfSigned;

  HttpClient? _client;

  AdminApi({
    required this.baseUrl,
    required this.token,
    this.acceptSelfSigned = false,
  });

  HttpClient get http {
    _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        // осознанное решение пользователя (self-signed узел в LAN/VPS)
        return acceptSelfSigned;
      };
    return _client!;
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'https://$base';
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = _uri(path, query);
    final req = await http.openUrl(method, uri);
    if (token.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $token');
    }
    if (body != null) {
      final data = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.headers.contentLength = data.length;
      req.add(data);
    }
    final resp = await req.close().timeout(const Duration(seconds: 12));
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      var msg = text;
      try {
        final j = jsonDecode(text);
        if (j is Map && j['error'] is Map) {
          msg = (j['error']['message'] ?? text).toString();
        } else if (j is Map && j['error'] != null) {
          msg = j['error'].toString();
        }
      } catch (_) {}
      throw ApiException(resp.statusCode, msg);
    }
    if (text.isEmpty) return {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {};
  }

  // --- Аутентификация ---

  Future<LoginInfo> login(String token) async {
    final j = await _json('POST', '/api/login', body: {'token': token});
    return LoginInfo.fromJson(j);
  }

  // --- Метрики ---

  Future<Stats> stats() async =>
      Stats.fromJson(await _json('GET', '/api/stats'));

  // --- Пользователи ---

  Future<List<UserView>> users() async {
    final j = await _json('GET', '/api/users');
    return ((j['users'] ?? const []) as List)
        .whereType<Map<String, dynamic>>()
        .map(UserView.fromJson)
        .toList();
  }

  Future<void> userAdd({
    required String email,
    String uuid = '',
    int level = 0,
    int expiryUnix = 0,
    int quotaBytes = 0,
  }) => _json(
    'POST',
    '/api/users',
    body: {
      'email': email,
      'uuid': uuid,
      'level': level,
      'expiryUnix': expiryUnix,
      'quotaBytes': quotaBytes,
    },
  );

  Future<void> userUpdate({
    required String email,
    int? level,
    int? expiryUnix,
    int? quotaBytes,
    bool? disabled,
  }) {
    final body = <String, dynamic>{'email': email};
    if (level != null) body['level'] = level;
    if (expiryUnix != null) body['expiryUnix'] = expiryUnix;
    if (quotaBytes != null) body['quotaBytes'] = quotaBytes;
    if (disabled != null) body['disabled'] = disabled;
    return _json('POST', '/api/users/update', body: body);
  }

  Future<void> userRemove(String email) =>
      _json('POST', '/api/users/remove', body: {'email': email});

  Future<ClientConfigView> clientConfig(String email) async =>
      ClientConfigView.fromJson(
        await _json('GET', '/api/client-config', query: {'email': email}),
      );

  // --- Сессии ---

  Future<List<SessionInfo>> sessions() async {
    final j = await _json('GET', '/api/sessions');
    return ((j['sessions'] ?? const []) as List)
        .whereType<Map<String, dynamic>>()
        .map(SessionInfo.fromJson)
        .toList();
  }

  Future<List<SessionInfo>> sessionsHistory() async {
    final j = await _json('GET', '/api/sessions/history');
    return ((j['history'] ?? const []) as List)
        .whereType<Map<String, dynamic>>()
        .map(SessionInfo.fromJson)
        .toList();
  }

  Future<void> sessionKill(String id) =>
      _json('POST', '/api/sessions/kill', body: {'id': id});

  // --- Фильтр и DNS ---

  Future<FilterInfo> filter() async =>
      FilterInfo.fromJson(await _json('GET', '/api/filter'));

  Future<void> filterSave(FilterConfigView cfg) =>
      _json('POST', '/api/filter/save', body: {'config': cfg.toJson()});

  Future<void> filterRefresh() => _json('POST', '/api/filter/refresh');

  Future<DnsInfo> dns() async =>
      DnsInfo.fromJson(await _json('GET', '/api/dns'));

  Future<void> dnsSave(List<String> servers) => _json(
    'POST',
    '/api/dns/save',
    body: {
      'config': {'servers': servers},
    },
  );

  // --- TLS ---

  Future<CertInfo> tls() async {
    final j = await _json('GET', '/api/tls');
    return CertInfo.fromJson(
      j['cert'] is Map ? (j['cert'] as Map<String, dynamic>) : j,
    );
  }

  Future<void> tlsSave({required String certFile, required String keyFile}) =>
      _json(
        'POST',
        '/api/tls/save',
        body: {'certFile': certFile, 'keyFile': keyFile},
      );

  Future<void> tlsReload() => _json('POST', '/api/tls/reload');

  // --- Журнал ---

  Future<List<LogEntry>> logs() async {
    final j = await _json('GET', '/api/logs');
    return ((j['logs'] ?? const []) as List)
        .whereType<Map<String, dynamic>>()
        .map(LogEntry.fromJson)
        .toList();
  }

  // --- Транспортные настройки (список путей) ---

  Future<List<String>> endpointPaths() async {
    final j = await _json('GET', '/api/settings');
    final t = j['transport'];
    if (t is Map<String, dynamic>) {
      return ((t['endpointPaths'] ?? const []) as List)
          .map((e) => e.toString())
          .toList();
    }
    return const [];
  }

  Future<void> settingsSave(Map<String, dynamic> settings) =>
      _json('POST', '/api/settings/save', body: settings);
}
