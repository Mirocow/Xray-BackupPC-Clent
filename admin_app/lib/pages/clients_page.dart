/// Клиенты: список с live-скоростями/объемами, добавление, изменение
/// (квота/срок/level/disable), удаление, share-ссылка (копирование).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui.dart';
import '../util/format.dart';

class ClientsPage extends StatefulWidget {
  final AppState state;
  const ClientsPage(this.state, {super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  List<UserView> _users = [];
  String? _err;
  Timer? _timer;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final u = await state.api!.users();
      if (mounted) setState(() => _users = u);
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  Future<void> _addUser() async {
    final email = TextEditingController();
    final quotaGb = TextEditingController();
    final days = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новый клиент'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              decoration: const InputDecoration(
                labelText: 'Имя (email)',
                hintText: 'office',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: quotaGb,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Квота, ГиБ (0 — без лимита)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: days,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Срок, дней (0 — бессрочно)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final name = email.text.trim();
    if (name.isEmpty) return;
    try {
      await state.api!.userAdd(
        email: name,
        quotaBytes: ((double.tryParse(quotaGb.text) ?? 0) * 1024 * 1024 * 1024)
            .round(),
        expiryUnix: (double.tryParse(days.text) ?? 0) > 0
            ? DateTime.now()
                      .add(Duration(days: int.tryParse(days.text) ?? 0))
                      .millisecondsSinceEpoch ~/
                  1000
            : 0,
      );
      if (mounted)
        showSnack(context, 'Клиент $name добавлен (UUID сгенерирован)');
      _refresh();
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _openUser(UserView u) async {
    final quotaGb = TextEditingController(
      text: u.quotaBytes > 0
          ? (u.quotaBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)
          : '',
    );
    final days = TextEditingController(
      text: u.expiryUnix > 0
          ? ((u.expiryUnix - DateTime.now().millisecondsSinceEpoch ~/ 1000) /
                    86400)
                .round()
                .toString()
          : '',
    );
    bool disabled = u.disabled;
    ClientConfigView? cfg;
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(u.email),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'UUID: ${u.uuid}',
                  style: const TextStyle(color: kDim, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(
                  'Отдано ↑ ${fmtBytes(u.upBytes)} · Скачано ↓ ${fmtBytes(u.downBytes)}'
                  '\nВ эфире: ↑ ${fmtBytes(u.liveUp)} ↓ ${fmtBytes(u.liveDown)}'
                  ' (${u.liveSessions} сесс.)',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: quotaGb,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Квота, ГиБ (0/пусто — без лимита)',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Срок, дней (0/пусто — бессрочно)',
                  ),
                ),
                SwitchListTile(
                  value: disabled,
                  onChanged: (v) => setDialog(() => disabled = v),
                  title: const Text('Отключен'),
                  dense: true,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.link_outlined, size: 18),
                  label: const Text('Конфиг / share-ссылка'),
                  onPressed: () async {
                    try {
                      cfg = await state.api!.clientConfig(u.email);
                      if (cfg != null && context.mounted) {
                        await showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Конфиг клиента'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Ссылка для импорта:',
                                  style: TextStyle(fontSize: 12, color: kDim),
                                ),
                                Text(
                                  cfg!.shareLink,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Несущие пути (${cfg!.endpointPaths.length}):',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: kDim,
                                  ),
                                ),
                                Text(
                                  cfg!.endpointPaths
                                          .take(4)
                                          .map((e) => e)
                                          .join('\n') +
                                      (cfg!.endpointPaths.length > 4
                                          ? '\n…'
                                          : ''),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: cfg!.shareLink),
                                  );
                                  showSnack(context, 'Ссылка скопирована');
                                },
                                child: const Text('Копировать ссылку'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Закрыть'),
                              ),
                            ],
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        showSnack(context, 'Ошибка: $e', error: true);
                      }
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  await state.api!.userRemove(u.email);
                  if (context.mounted) Navigator.pop(context, 'removed');
                } catch (e) {
                  if (context.mounted) {
                    showSnack(context, 'Ошибка: $e', error: true);
                  }
                }
              },
              child: const Text('Удалить', style: TextStyle(color: kWarn)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'saved'),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (changed == 'saved') {
      try {
        await state.api!.userUpdate(
          email: u.email,
          quotaBytes: (double.tryParse(quotaGb.text) ?? 0) > 0
              ? ((double.tryParse(quotaGb.text) ?? 0) * 1024 * 1024 * 1024)
                    .round()
              : 0,
          expiryUnix: (int.tryParse(days.text) ?? 0) > 0
              ? DateTime.now()
                        .add(Duration(days: int.tryParse(days.text) ?? 0))
                        .millisecondsSinceEpoch ~/
                    1000
              : 0,
          disabled: disabled,
        );
        if (mounted) showSnack(context, 'Сохранено');
      } catch (e) {
        if (mounted) showSnack(context, 'Ошибка: $e', error: true);
      }
    } else if (changed == 'removed') {
      if (mounted) showSnack(context, 'Клиент удален, сессии погашены');
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _addUser,
        child: const Icon(Icons.person_add_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (_err != null && users.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Нет связи: $_err',
                  style: const TextStyle(color: kWarn, fontSize: 12),
                ),
              ),
            for (final u in users)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PaddedCard(
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openUser(u),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                u.email,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (u.disabled)
                              const _Tag('выключен', kWarn)
                            else if (u.live)
                              const _Tag('в эфире', kUp)
                            else
                              const _Tag('офлайн', kDim),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '↑ ${fmtBps(u.rateUp)} · ↓ ${fmtBps(u.rateDown)}'
                          '   |   отдано ${fmtBytes(u.upBytes)} · скачано ${fmtBytes(u.downBytes)}',
                          style: const TextStyle(fontSize: 12, color: kDim),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          u.quotaBytes > 0
                              ? 'квота ${fmtBytes(u.quotaBytes)} · использовано ${fmtBytes(u.usedBytes)}'
                              : 'без квоты · использовано ${fmtBytes(u.usedBytes)}',
                          style: const TextStyle(fontSize: 11, color: kDim),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (users.isEmpty && _err == null)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(
                  child: Text(
                    'Клиентов нет — добавьте первым',
                    style: TextStyle(color: kDim),
                  ),
                ),
              ),
            const SizedBox(height: 70),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 11)),
  );
}
