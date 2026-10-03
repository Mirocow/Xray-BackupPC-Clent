/// Сессии: активные (live-скорости/объемы, kill) и «Недавно завершенные»
/// (история с причинами завершения).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui.dart';
import '../util/format.dart';

class SessionsPage extends StatefulWidget {
  final AppState state;
  const SessionsPage(this.state, {super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<SessionInfo> _active = [];
  List<SessionInfo> _history = [];
  String? _err;
  Timer? _timer;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final j = await state.api!.sessions();
      final h = await state.api!.sessionsHistory();
      if (mounted) {
        setState(() {
          _active = j;
          _history = h.reversed.toList(); // новее сверху
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  Future<void> _kill(SessionInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить сессию?'),
        content: Text('${s.user} → ${s.target}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.api!.sessionKill(s.id);
      if (mounted) showSnack(context, 'Сессия завершена');
      _refresh();
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сессии'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Активные'),
            Tab(text: 'Недавно завершенные'),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: TabBarView(
          controller: _tabs,
          children: [
            _list(_active, active: true),
            _list(_history, active: false),
          ],
        ),
      ),
    );
  }

  Widget _list(List<SessionInfo> items, {required bool active}) {
    if (_err != null && items.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Нет связи: $_err',
              style: const TextStyle(color: kWarn, fontSize: 12),
            ),
          ),
        ],
      );
    }
    if (items.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                active
                    ? 'Нет активных сессий'
                    : 'История пуста: сессии попадают сюда при закрытии '
                          'прокси-соединения. Появилось в сервере 1.3.0 — на '
                          'более старых версиях раздел всегда пуст.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kDim, fontSize: 13),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = items[i];
        return PaddedCard(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${s.user} → ${s.target}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (active)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: kWarn),
                      tooltip: 'Завершить',
                      onPressed: () => _kill(s),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'задание ${s.id}',
                style: const TextStyle(fontSize: 11, color: kDim),
              ),
              const SizedBox(height: 4),
              Text(
                active
                    ? '↑ ${fmtBps(s.rateUp)} · ↓ ${fmtBps(s.rateDown)}   |   '
                          '↑ ${fmtBytes(s.up)} · ↓ ${fmtBytes(s.down)} · ${fmtDur(s.duration.inMilliseconds)} · чанков ${s.chunks}'
                    : '↑ ${fmtBytes(s.up)} · ↓ ${fmtBytes(s.down)} · '
                          '${fmtDur(s.duration.inMilliseconds)} · ${fmtTime(s.finishedAt)}',
                style: const TextStyle(fontSize: 12, color: kDim),
              ),
              if (!active) ...[const SizedBox(height: 4), _ReasonTag(s.state)],
            ],
          ),
        );
      },
    );
  }
}

class _ReasonTag extends StatelessWidget {
  final String reason;
  const _ReasonTag(this.reason);

  Color get color {
    if (reason.startsWith('blocked')) return kWarn;
    if (reason == 'quota-exceeded') return kWarn;
    if (reason == 'killed') return kDown;
    return kDim;
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      'причина: $reason',
      style: TextStyle(color: color, fontSize: 11),
    ),
  );
}
