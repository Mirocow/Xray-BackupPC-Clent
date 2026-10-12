/// Форматирование величин (байты, скорости, время) — как в веб-панели.
library;

String fmtBytes(num n) {
  if (n < 0) return '—';
  if (n < 1024) return '${n.round()} B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var v = n / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}

String fmtBps(num n) {
  if (n <= 0) return '0 Б/с';
  if (n < 1024) return '${n.round()} Б/с';
  const units = ['КиБ/с', 'МиБ/с', 'ГиБ/с'];
  var v = n / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}

String fmtDur(int ms) {
  if (ms < 0) ms = 0;
  final d = Duration(milliseconds: ms);
  if (d.inDays > 0) return '${d.inDays}д ${d.inHours % 24}ч';
  if (d.inHours > 0) return '${d.inHours}ч ${d.inMinutes % 60}м';
  if (d.inMinutes > 0) return '${d.inMinutes}м ${d.inSeconds % 60}с';
  return '${d.inSeconds}с';
}

String fmtTime(int tsMs) {
  if (tsMs <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String fmtPct(double v) =>
    v > 0 ? '${v.toStringAsFixed(v < 10 ? 1 : 0)}%' : '0%';
