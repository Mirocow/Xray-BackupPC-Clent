/// VLESS data-plane заголовок запроса (протокол слоя 2).
///
///     +---------+------+-------------+---------+--------+--------+---------+
///     | Version | UUID | Addons Len  | Addons  | Command| Port   | Address |
///     |  1B     | 16B  | 1B          | X B     |  1B     | 2B BE  | type+val|
///     +---------+------+-------------+---------+--------+--------+---------+
///
/// Address: 0x01 = IPv4 (4B), 0x02 = домен (1B длина + байты), 0x03 = IPv6 (16B).
/// Ответ сервера: [Version (1B)][Addons Length (1B)] — 2 байта, затем поток.
library;

import 'dart:io';
import 'dart:typed_data';

const int vlessVersion = 0x00;
const int vlessCmdTCP = 0x01;
const int vlessAtypIPv4 = 0x01;
const int vlessAtypDomain = 0x02;
const int vlessAtypIPv6 = 0x03;

/// Кодирование клиентского запроса VLESS (TCP).
Uint8List buildVlessRequest(Uint8List id, String address, int port) {
  Uint8List addr;
  int atyp;
  final ip = InternetAddress.tryParse(address);
  if (ip != null && ip.type == InternetAddressType.IPv4) {
    atyp = vlessAtypIPv4;
    addr = ip.rawAddress;
  } else if (ip != null && ip.type == InternetAddressType.IPv6) {
    atyp = vlessAtypIPv6;
    addr = ip.rawAddress;
  } else {
    atyp = vlessAtypDomain;
    final nameBytes = address.codeUnits;
    addr = Uint8List(1 + nameBytes.length);
    addr[0] = nameBytes.length;
    addr.setAll(1, nameBytes);
  }
  final buf = BytesBuilder();
  buf.addByte(vlessVersion);
  buf.add(id);
  buf.addByte(0); // addons length = 0
  buf.addByte(vlessCmdTCP);
  buf.addByte((port >> 8) & 0xFF);
  buf.addByte(port & 0xFF);
  buf.addByte(atyp);
  buf.add(addr);
  return buf.toBytes();
}

/// Ожидаемый заголовок ответа сервера: [version][addons len=0].
const List<int> vlessResponseHeader = [vlessVersion, 0x00];
