import 'dart:io';
import 'dart:typed_data';
import 'det_stream.dart';

Future<void> main() async {
  // сохранённое эхо из debug_upload — прочитаем из /tmp/echo.bin если есть
  final f = File('/tmp/echo.bin');
  if (!f.existsSync()) {
    print('нет /tmp/echo.bin — сначала сохрани');
    return;
  }
  final received = f.readAsBytesSync();
  final n = received.length;
  final expect = Uint8List(n);
  DetStream(48879).readInto(expect);
  var first = -1;
  var last = -1;
  var diffs = 0;
  for (var i = 0; i < n; i++) {
    if (received[i] != expect[i]) {
      if (first < 0) first = i;
      last = i;
      diffs++;
    }
  }
  print('n=$n first=$first last=$last diffs=$diffs');
  // проверка гипотезы сдвига: received[i+k] == expect[i]?
  for (var k = -700; k <= 700; k += 1) {
    if (k == 0) continue;
    var ok = true;
    for (var i = first; i < first + 2000 && i < n; i++) {
      final j = i + k;
      if (j < 0 || j >= n || received[j] != expect[i]) {
        ok = false;
        break;
      }
    }
    if (ok) {
      print('SHIFT k=$k: received[i+k]==expect[i] от $first');
      break;
    }
  }
}
