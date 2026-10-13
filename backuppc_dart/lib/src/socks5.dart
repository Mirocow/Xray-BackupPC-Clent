/// SOCKS5-фронтенд туннеля (порт SOCKS-цикла из `client.go`).
///
/// Поддерживается только CONNECT без авторизации (как в эталоне):
/// UDP-ассоциации отклоняются — транспорт backuppc TCP-only,
/// QUIC/UDP трафик должен переключаться на TCP (браузеры делают это сами).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const Duration socksHandshakeTimeout = Duration(seconds: 15);

class Socks5Request {
  final String address;
  final int port;
  const Socks5Request(this.address, this.port);
}

/// Буферизованный читатель сокета: читает ровно столько, сколько нужно
/// для текущего шага рукопожатия; «лишние» байты события сохраняются
/// и передаются в релей (ранние данные клиента не теряются).
class SocketByteReader {
  final StreamIterator<Uint8List> _it;
  Uint8List? _pending;
  int _off = 0;

  SocketByteReader(Stream<Uint8List> stream) : _it = StreamIterator(stream);

  Future<Uint8List> readExact(int n) async {
    final acc = BytesBuilder();
    var need = n;
    while (need > 0) {
      final p = _pending;
      if (p == null || _off >= p.length) {
        final has = await _it.moveNext();
        if (!has) {
          throw const SocketException('socks: клиент закрыл соединение');
        }
        _pending = _it.current;
        _off = 0;
        continue;
      }
      final avail = p.length - _off;
      final take = avail < need ? avail : need;
      acc.add(Uint8List.sublistView(p, _off, _off + take));
      _off += take;
      need -= take;
    }
    return acc.toBytes();
  }

  Future<void> skip(int n) async {
    var need = n;
    while (need > 0) {
      final p = _pending;
      if (p == null || _off >= p.length) {
        final has = await _it.moveNext();
        if (!has) {
          throw const SocketException('socks: клиент закрыл соединение');
        }
        _pending = _it.current;
        _off = 0;
        continue;
      }
      final avail = p.length - _off;
      final take = avail < need ? avail : need;
      _off += take;
      need -= take;
    }
  }

  /// Остаток текущего события (для релея).
  Uint8List takePending() {
    final p = _pending;
    final off = _off;
    _pending = null;
    _off = 0;
    if (p == null || off >= p.length) return Uint8List(0);
    return Uint8List.sublistView(p, off);
  }

  /// Следующий кусок данных произвольного размера (для релея): остаток
  /// буфера или новое событие сокета; null при EOF.
  Future<Uint8List?> readChunk() async {
    final p = _pending;
    if (p != null && _off < p.length) {
      final view = Uint8List.sublistView(p, _off);
      _pending = null;
      _off = 0;
      return view;
    }
    final has = await _it.moveNext();
    if (!has) return null;
    return _it.current;
  }

  Future<void> cancel() => _it.cancel();
}

/// Рукопожатие SOCKS5: [VER NMETHODS METHODS] → [05 00],
/// [VER CMD RSV ATYP ADDR PORT] → [VER REP RSV BND 0.0.0.0:0].
/// Возвращает адрес назначения; чтение останавливается ровно на конце
/// запроса (байтовая позиция передается через [SocketByteReader]).
Future<Socks5Request> socks5Handshake(
  Socket client,
  SocketByteReader reader,
) async {
  final head = await reader.readExact(2).timeout(socksHandshakeTimeout);
  if (head[0] != 0x05) {
    throw const SocketException('socks: не SOCKS5');
  }
  final nmethods = head[1];
  final methods = await reader.readExact(nmethods).timeout(
    socksHandshakeTimeout,
  );
  if (!methods.contains(0x00)) {
    client.add(const [0x05, 0xFF]);
    await client.flush();
    throw const SocketException('socks: требуется авторизация');
  }
  client.add(const [0x05, 0x00]);
  await client.flush();

  final req = await reader.readExact(4).timeout(socksHandshakeTimeout);
  final ver = req[0];
  final cmd = req[1];
  if (ver != 0x05) {
    throw const SocketException('socks: не SOCKS5 в запросе');
  }
  final atyp = req[3];
  String address;
  switch (atyp) {
    case 0x01:
      final b = await reader.readExact(4);
      address = '${b[0]}.${b[1]}.${b[2]}.${b[3]}';
    case 0x03:
      final len = (await reader.readExact(1))[0];
      if (len == 0) {
        throw const SocketException('socks: пустое имя хоста');
      }
      address = String.fromCharCodes(await reader.readExact(len));
    case 0x04:
      final b = await reader.readExact(16);
      final parts = <String>[];
      for (var i = 0; i < 16; i += 2) {
        parts.add(
          ((b[i] << 8) | b[i + 1]).toRadixString(16).padLeft(4, '0'),
        );
      }
      address = parts.join(':');
    default:
      throw const SocketException('socks: неизвестный ATYP');
  }
  final portBytes = await reader.readExact(2);
  final port = (portBytes[0] << 8) | portBytes[1];

  // BND 0.0.0.0:0 (как эталонный Go-клиент)
  const okReply = [
    0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
  ];
  const cmdFailReply = [
    0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
  ];
  if (cmd != 0x01) {
    // CONNECT only; UDP ASSOCIATE/BIND не поддерживаются транспортом
    client.add(cmdFailReply);
    await client.flush();
    throw const SocketException('socks: поддерживается только CONNECT');
  }
  client.add(okReply);
  await client.flush();
  return Socks5Request(address, port);
}
