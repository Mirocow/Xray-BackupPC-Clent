/// Dart-пинг узлов backuppc: TCP-хендшейк до serverAddr (latency) —
/// нативный testXray не знает протокола. Полный путь (TLS+VLESS+SOCKS)
/// не нужен для измерения: сетевая стоимость совпадает до TLS-рукопожатия.
library;

import 'dart:async';
import 'dart:io';

import 'package:onexray/service/connect/backuppc/outbound.dart';

const Duration _pingTimeout = Duration(seconds: 5);

/// TCP-латентность до VPN-сервера узла; null — узел не backuppc.
Future<int?> backuppcPingOutbound(Map<String, dynamic> outbound) async {
  if (!isBackupPcOutbound(outbound)) {
    return null;
  }
  final settings = outbound['settings'];
  if (settings is! Map<String, dynamic>) {
    throw const SocketException('backuppc: нет settings');
  }
  final serverAddr = settings['serverAddr'];
  if (serverAddr is! String || serverAddr.isEmpty) {
    throw const SocketException('backuppc: нет serverAddr');
  }
  final i = serverAddr.lastIndexOf(':');
  final host = i < 0
      ? serverAddr
      : serverAddr.substring(0, i).replaceAll('[', '').replaceAll(']', '');
  final port = i < 0 ? 443 : int.tryParse(serverAddr.substring(i + 1)) ?? 443;
  final sw = Stopwatch()..start();
  final socket = await Socket.connect(
    host,
    port,
    timeout: _pingTimeout,
  );
  sw.stop();
  socket.destroy();
  return sw.elapsedMilliseconds;
}
