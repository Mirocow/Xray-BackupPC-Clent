import 'package:flutter/foundation.dart';
import 'package:backuppc_dart/backuppc_dart.dart' show BackupPcLink;
import 'package:onexray/core/db/database/database.dart';
import 'package:onexray/core/pigeon/host_api.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/servers/outbound/map.dart';
import 'package:onexray/service/servers/outbound/state_db.dart';

class XrayShareReader {
  Future<List<CoreConfigCompanion>> parseShareText(
    String text, {
    String? ageSecretKey,
  }) async {
    // backuppc:// парсится чистым Dart (нативный конвертер его не знает).
    final (backuppcOutbounds, nativeText) = splitBackupPcLinks(text);
    final outbounds = <Map<String, dynamic>>[...backuppcOutbounds];
    if (nativeText.trim().isNotEmpty) {
      outbounds.addAll(
        await AppHostApi().convertShareLinksToXrayJson(
          nativeText,
          ageSecretKey: ageSecretKey,
        ),
      );
    }
    return readXrayJsonOutbounds({'outbounds': outbounds});
  }

  /// Разделяет ввод: строки `backuppc://` → outbound-ы, остальное —
  /// нативному конвертеру. Некорректная backuppc-ссылка — ошибка ввода
  /// (нативный конвертер так же поступает с битыми vless/vmess).
  @visibleForTesting
  (List<Map<String, dynamic>>, String) splitBackupPcLinks(String text) {
    final backuppcOutbounds = <Map<String, dynamic>>[];
    final other = <String>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final scheme = trimmed.isEmpty
          ? ''
          : Uri.tryParse(trimmed)?.scheme.toLowerCase() ?? '';
      if (scheme == 'backuppc') {
        final link = BackupPcLink.tryParse(trimmed);
        if (link == null) {
          throw const FormatException('Invalid backuppc link');
        }
        backuppcOutbounds.add(link.toOutboundJson());
      } else {
        other.add(line);
      }
    }
    return (backuppcOutbounds, other.join('\n'));
  }

  @visibleForTesting
  Future<List<CoreConfigCompanion>> readXrayJsonOutbounds(
    Map<String, dynamic> xrayJson,
  ) async {
    final res = <CoreConfigCompanion>[];
    final outbounds = xrayJson['outbounds'];
    if (outbounds is! List<dynamic>) {
      return res;
    }

    for (var index = 0; index < outbounds.length; index++) {
      if (index > 0 && index % 64 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final value = outbounds[index];
      if (value is! Map<String, dynamic>) {
        continue;
      }
      final outbound = copyOutboundMap(value);
      try {
        res.add(outboundCompanion(outbound));
      } catch (error, stackTrace) {
        ygLogger(
          "Failed to read imported outbound (${error.runtimeType})\n$stackTrace",
        );
      }
    }
    return res;
  }
}
