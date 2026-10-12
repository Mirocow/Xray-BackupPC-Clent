/// VLESS-серверная часть: парсинг входящего VLESS-запроса.
///
/// ВАЖНО: v2.1 — БЕЗ mesh-routing addon 0x4D (отказались от ломки back-compat).
/// Multihop-chain реализуется через re-dial pattern в MeshClient.
///
/// См. docs/PROTOCOL.md §11.4 (без addon 0x4D) и §11.9 (hybrid node).
library;

import 'dart:io';
import 'dart:typed_data';

const int vlessVersion = 0x00;
const int vlessCmdTCP = 0x01;
const int vlessAtypIPv4 = 0x01;
const int vlessAtypDomain = 0x02;
const int vlessAtypIPv6 = 0x03;

/// VlessRequest — распарсенный VLESS-запрос.
class VlessRequest {
  final Uint8List uuid;
  final int command;
  final String address;
  final int port;
  final Uint8List addons;

  const VlessRequest({
    required this.uuid,
    required this.command,
    required this.address,
    required this.port,
    required this.addons,
  });
}

/// parseVlessRequest — парсинг VLESS-запроса.
///
/// Возвращает null если буфер неполный (нужно дочитать).
/// Бросает VlessParseException при некорректном формате.
VlessRequest? parseVlessRequest(Uint8List buf, {int offset = 0}) {
  if (buf.length - offset < 1 + 16 + 1 + 1 + 2 + 1) {
    return null;
  }
  var pos = offset;
  final version = buf[pos++];
  if (version != vlessVersion) {
    throw VlessParseException('vless: unsupported version $version');
  }
  final uuid = Uint8List.sublistView(buf, pos, pos + 16);
  pos += 16;
  final addonsLen = buf[pos++];
  if (buf.length - pos < addonsLen + 1 + 2 + 1) {
    return null;
  }
  final addons = addonsLen > 0
      ? Uint8List.sublistView(buf, pos, pos + addonsLen)
      : Uint8List(0);
  pos += addonsLen;
  final command = buf[pos++];
  if (command != vlessCmdTCP) {
    throw VlessParseException('vless: unsupported command $command (only TCP)');
  }
  final port = (buf[pos] << 8) | buf[pos + 1];
  pos += 2;
  final atyp = buf[pos++];
  String address;
  switch (atyp) {
    case vlessAtypIPv4:
      if (buf.length - pos < 4) return null;
      address = '${buf[pos]}.${buf[pos + 1]}.${buf[pos + 2]}.${buf[pos + 3]}';
      pos += 4;
    case vlessAtypDomain:
      if (buf.length - pos < 1) return null;
      final len = buf[pos++];
      if (buf.length - pos < len) return null;
      address = String.fromCharCodes(buf.sublist(pos, pos + len));
      pos += len;
    case vlessAtypIPv6:
      if (buf.length - pos < 16) return null;
      final parts = <String>[];
      for (var i = 0; i < 16; i += 2) {
        parts.add(((buf[pos + i] << 8) | buf[pos + i + 1]).toRadixString(16));
      }
      address = parts.join(':');
      pos += 16;
    default:
      throw VlessParseException('vless: unknown address type $atyp');
  }
  return VlessRequest(
    uuid: uuid,
    command: command,
    address: address,
    port: port,
    addons: addons,
  );
}

/// buildVlessResponse — заголовок ответа сервера: [version=0, addons-len=0].
Uint8List buildVlessResponse() {
  return Uint8List.fromList([vlessVersion, 0x00]);
}

/// VlessParseException — ошибка парсинга VLESS-запроса.
class VlessParseException implements Exception {
  final String message;
  const VlessParseException(this.message);
  @override
  String toString() => 'VlessParseException: $message';
}
