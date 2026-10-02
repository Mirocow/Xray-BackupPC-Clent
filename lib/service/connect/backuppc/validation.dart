/// Валидация outbound-ов при сохранении/импорте с протоколом backuppc.
///
/// Нативный `testXray` (Xray-core) не знает протокола `backuppc` и отвергает
/// такие outbound-ы. Разделяем список: backuppc проверяется чистым Dart
/// ([validateBackupPcOutbound]), остальные — нативным валидатором, и
/// склеиваем сообщения об ошибках. Все outbound-ы backuppc — полностью
/// Dart-валидация; при пустом «нативном» списке нативный вызов не выполняется.
library;

import 'package:onexray/service/connect/backuppc/outbound.dart';
import 'package:onexray/service/shared/xray/validation.dart';

/// Валидирует [outbounds] (JSON-объекты outbound-ов Xray).
///
/// [nativeValidate] — нативный валидатор конфигурации Xray
/// (`AppHostApi().testXray` с `XrayValidation.nodes`), получает конфиг
/// из всего «не-backuppc» (включая битые элементы — нативный валидатор
/// отвергает их штатно). Возвращает '' при успехе.
Future<String> validateOutboundsMixed(
  List<dynamic> outbounds,
  Future<String> Function(String config) nativeValidate,
) async {
  final backuppc = <Map<String, dynamic>>[];
  final native = <dynamic>[];
  for (final value in outbounds) {
    if (value is Map<String, dynamic> && isBackupPcOutbound(value)) {
      backuppc.add(value);
    } else {
      native.add(value);
    }
  }
  final errors = <String>[];
  for (final outbound in backuppc) {
    final error = validateBackupPcOutbound(outbound);
    if (error != null && error.trim().isNotEmpty) {
      errors.add(error.trim());
    }
  }
  if (native.isNotEmpty) {
    // Точная форма `XrayValidation.nodes` (env/log, _outbound-нормализация).
    final error = await nativeValidate(XrayValidation.nodes(native));
    if (error.trim().isNotEmpty) {
      errors.add(error.trim());
    }
  }
  return errors.join('\n');
}
