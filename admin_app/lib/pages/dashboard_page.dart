/// Дашборд: скорости, сессии, зонды, аптайм + системная нагрузка
/// (CPU/RSS/куча Go/горутины/fd) и предупреждение о старой версии.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui.dart';
import '../util/format.dart';

class DashboardPage extends StatefulWidget {
  final AppState state;
  const DashboardPage(this.state, {super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Stats? _stats;
  String? _err;
  Timer? _timer;
  bool _auto = true;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (_auto) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    try {
      final s = await state.api!.stats();
      if (mounted) {
        setState(() {
          _stats = s;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final wide = MediaQuery.of(context).size.width > 600;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (_err != null && s == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Нет связи с сервером: $_err',
                style: const TextStyle(color: kWarn, fontSize: 12),
              ),
            ),
          GridView.count(
            crossAxisCount: wide ? 3 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.55,
            children: [
              StatCard(
                '↓ Скорость: интернет → клиенты',
                fmtBps(s?.rateDown ?? 0),
                'всего ${fmtBytes(s?.metrics.bytesDown ?? 0)}',
                tone: kDown,
              ),
              StatCard(
                '↑ Скорость: клиенты → интернет',
                fmtBps(s?.rateUp ?? 0),
                'всего ${fmtBytes(s?.metrics.bytesUp ?? 0)}',
                tone: kUp,
              ),
              StatCard(
                'Активные сессии',
                '${s?.sessionsActive ?? 0}',
                'всего ${s?.metrics.sessions ?? 0} · TCP ${s?.metrics.connsOpen ?? 0}',
              ),
              StatCard('Клиенты', '${s?.users ?? 0}', 'реестр users.json'),
              StatCard(
                'Фильтр: блокировки',
                '${s?.filter.total ?? 0}',
                s?.filter.enabled == true
                    ? 'реклама ${s!.filter.blocked.ads} · торренты ${s.filter.blocked.torrents + s.filter.ports + s.filter.handshake} · правил ${s.filter.domains}'
                    : 'фильтр выключен',
                tone: (s?.filter.total ?? 0) > 0 ? kWarn : null,
              ),
              StatCard(
                'Зонды отбиты',
                '${s?.metrics.probes ?? 0}',
                'активные пробы к каналу',
                tone: (s?.metrics.probes ?? 0) > 0 ? kWarn : null,
              ),
              StatCard(
                'DNS-резолвы',
                '${s?.dns.queries ?? 0}',
                'кэш ${s?.dns.cacheHits ?? 0} · блок ${s?.dns.blocked ?? 0} · в кэше ${s?.dns.cached ?? 0}',
              ),
              StatCard(
                'Аптайм',
                fmtDur(s?.uptimeMs ?? 0),
                'сервер ${s?.version ?? '—'}',
              ),
            ],
          ),
          const SectionTitle('Нагрузка на сервер (процесс backuppc-server)'),
          GridView.count(
            crossAxisCount: wide ? 3 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.55,
            children: [
              StatCard(
                'CPU',
                fmtPct(s?.sys.cpu ?? 0),
                '${s?.sys.cpus ?? 0} ядер · load ${s?.sys.load1.toStringAsFixed(2) ?? '—'}',
                tone: (s?.sys.cpu ?? 0) > 80 ? kWarn : null,
              ),
              StatCard(
                'Память (RSS)',
                fmtBytes(s?.sys.memRssBytes ?? 0),
                (s?.sys.memTotalBytes ?? 0) > 0
                    ? 'хост ${fmtBytes(s!.sys.memTotalBytes)}'
                    : '',
              ),
              StatCard(
                'Куча Go',
                fmtBytes(s?.sys.goHeapBytes ?? 0),
                'GC ${s?.sys.numGC ?? 0} · пауза ~${(s?.sys.gcPauseAvgMs ?? 0).toStringAsFixed(2)} мс',
              ),
              StatCard(
                'Горутины',
                '${s?.sys.goroutines ?? 0}',
                'стационарно = течи нет',
              ),
              StatCard('fd', '${s?.sys.fds ?? 0}', 'сокеты + файлы'),
            ],
          ),
          if (s != null && s.versionInt > 0 && s.versionInt < 10300)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x33D29922),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '⚠ Сервер старше 1.3.0: история завершенных сессий, '
                  'live-трафик клиентов, фильтр и DNS появились в 1.3.0 — '
                  'обновите пакет на сервере.',
                  style: TextStyle(color: kWarn, fontSize: 12),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'Автообновление (2 с)',
                style: TextStyle(color: kDim, fontSize: 12),
              ),
              const Spacer(),
              Switch(
                value: _auto,
                onChanged: (v) {
                  setState(() => _auto = v);
                  _restartTimer();
                },
              ),
            ],
          ),
          const SizedBox(height: 60),
        ],
      ),
    );
  }
}
