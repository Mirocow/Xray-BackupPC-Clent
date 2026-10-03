/// Состояние приложения: профиль подключения (адрес/токен/сертификат),
/// логин/логаут, единый экземпляр AdminApi. Профиль хранится в
/// SharedPreferences устройства (токен не покидает телефон).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api.dart';
import '../api/models.dart';

class ConnProfile {
  final String address; // http://host:8444 или https://host
  final String token;
  final bool acceptSelfSigned;
  const ConnProfile({
    required this.address,
    required this.token,
    this.acceptSelfSigned = false,
  });

  Map<String, dynamic> toJson() => {
    'address': address,
    'token': token,
    'acceptSelfSigned': acceptSelfSigned,
  };

  factory ConnProfile.fromJson(Map<String, dynamic> j) => ConnProfile(
    address: (j['address'] ?? '').toString(),
    token: (j['token'] ?? '').toString(),
    acceptSelfSigned: j['acceptSelfSigned'] == true,
  );
}

class AppState extends ChangeNotifier {
  AdminApi? api;
  LoginInfo? loginInfo;
  String? error;
  bool busy = false;

  ConnProfile? _saved;
  ConnProfile? get saved => _saved;

  Future<void> loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('backuppc_admin.profile');
      if (raw != null && raw.isNotEmpty) {
        _saved = ConnProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('backuppc_admin.profile');
    _saved = null;
    notifyListeners();
  }

  Future<bool> connect({
    required String address,
    required String token,
    required bool acceptSelfSigned,
    bool remember = true,
  }) async {
    error = null;
    busy = true;
    notifyListeners();
    final candidate = AdminApi(
      baseUrl: address,
      token: token,
      acceptSelfSigned: acceptSelfSigned,
    );
    try {
      final info = await candidate.login(token);
      if (!info.ok) {
        error = 'Сервер отклонил токен';
        busy = false;
        notifyListeners();
        return false;
      }
      api?.dispose();
      api = candidate;
      loginInfo = info;
      if (remember) {
        _saved = ConnProfile(
          address: address,
          token: token,
          acceptSelfSigned: acceptSelfSigned,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'backuppc_admin.profile',
          jsonEncode(_saved!.toJson()),
        );
      }
      busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      candidate.dispose();
      error = _describe(e);
      busy = false;
      notifyListeners();
      return false;
    }
  }

  String _describe(Object e) {
    if (e is ApiException) {
      if (e.status == 401) return 'Неверный токен администратора (401)';
      return 'Сервер: ${e.message}';
    }
    if (e is FormatException) return 'Некорректный адрес панели';
    final s = e.toString();
    if (s.contains('Connection refused') || s.contains('SocketException')) {
      return 'Нет соединения: проверьте адрес и порт панели (по умолчанию 8444)';
    }
    if (s.contains('HandshakeException') || s.contains('CERTIFICATE')) {
      return 'TLS: сертификат не принят — включите «Самоподписанный сертификат» или проверьте домен';
    }
    if (s.contains('TimeoutException') || s.contains('timeout')) {
      return 'Таймаут соединения';
    }
    return s;
  }

  void logout() {
    api?.dispose();
    api = null;
    loginInfo = null;
    error = null;
    notifyListeners();
  }
}
