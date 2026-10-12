/// «Фильтр и DNS»: тумблеры фильтра (реклама/торренты), источники списков
/// со статусами, свои домены, статистика и последние блокировки;
/// DNS: апстримы (редактирование), статистика, топ доменов.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui.dart';
import '../util/format.dart';

class FilterPage extends StatefulWidget {
  final AppState state;
  const FilterPage(this.state, {super.key});

  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  FilterInfo? _filter;
  DnsInfo? _dns;
  String? _err;
  bool _busy = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final f = await state.api!.filter();
      var d = _dns;
      try {
        d = await state.api!.dns();
      } catch (_) {} // до 1.3.0 секции нет
      if (mounted) {
        setState(() {
          _filter = f;
          _dns = d;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    }
  }

  Future<void> _toggleFilter(bool v) async {
    final f = _filter;
    if (f == null) return;
    setState(() => _busy = true);
    try {
      await state.api!.filterSave(
        FilterConfigView(
          enabled: v,
          blockTorrents: f.config.blockTorrents,
          sources: f.config.sources,
          customDomains: f.config.customDomains,
        ),
      );
      await _refresh();
      if (mounted) showSnack(context, v ? 'Фильтр включен' : 'Фильтр выключен');
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleTorrents(bool v) async {
    final f = _filter;
    if (f == null) return;
    setState(() => _busy = true);
    try {
      await state.api!.filterSave(
        FilterConfigView(
          enabled: f.config.enabled,
          blockTorrents: v,
          sources: f.config.sources,
          customDomains: f.config.customDomains,
        ),
      );
      await _refresh();
      if (mounted) {
        showSnack(
          context,
          v
              ? 'Блокировка торрентов включена'
              : 'Блокировка торрентов выключена',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshLists() async {
    setState(() => _busy = true);
    try {
      await state.api!.filterRefresh();
      await _refresh();
      if (mounted) showSnack(context, 'Списки обновлены');
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDomain() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Заблокировать домен'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(
            hintText: 'ads.example.com',
            labelText: 'Домен',
          ),
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
    if (ok != true) return;
    final d = ctl.text.trim().toLowerCase();
    final f = _filter;
    if (d.isEmpty || f == null || f.config.customDomains.contains(d)) return;
    try {
      await state.api!.filterSave(
        FilterConfigView(
          enabled: f.config.enabled,
          blockTorrents: f.config.blockTorrents,
          sources: f.config.sources,
          customDomains: [...f.config.customDomains, d],
        ),
      );
      await _refresh();
      if (mounted) showSnack(context, 'Домен $d заблокирован');
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _removeDomain(String d) async {
    final f = _filter;
    if (f == null) return;
    try {
      await state.api!.filterSave(
        FilterConfigView(
          enabled: f.config.enabled,
          blockTorrents: f.config.blockTorrents,
          sources: f.config.sources,
          customDomains: f.config.customDomains.where((x) => x != d).toList(),
        ),
      );
      await _refresh();
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  Future<void> _editDns() async {
    final d = _dns;
    if (d == null) return;
    final ctl = TextEditingController(text: d.config.servers.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('DNS-апстримы сервера'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              decoration: const InputDecoration(
                labelText: 'Серверы через запятую',
                hintText: '1.1.1.1, 8.8.8.8',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Пусто — системный резолвер ОС. Заблокированные домены '
              'не резолвятся вовсе.',
              style: TextStyle(color: kDim, fontSize: 11),
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
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final servers = ctl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    try {
      await state.api!.dnsSave(servers);
      await _refresh();
      if (mounted) showSnack(context, 'DNS обновлены');
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _filter;
    final d = _dns;
    return Scaffold(
      appBar: AppBar(title: const Text('Фильтр и DNS')),
      body: _busy || f == null
          ? ListView(
              children: [
                if (_err != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Нет связи: $_err',
                      style: const TextStyle(color: kWarn, fontSize: 12),
                    ),
                  ),
                if (_err == null)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  PaddedCard(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          value: f.config.enabled,
                          onChanged: _toggleFilter,
                          title: const Text('Фильтр таргетов'),
                          subtitle: const Text(
                            'бан-листы · торренты · свои списки; проверка до DNS и диала',
                            style: TextStyle(fontSize: 11),
                          ),
                          dense: true,
                        ),
                        SwitchListTile(
                          value: f.config.blockTorrents,
                          onChanged: f.config.enabled ? _toggleTorrents : null,
                          title: const Text('Блокировка BitTorrent'),
                          subtitle: const Text(
                            'трекеры · порты · сниф рукопожатия',
                            style: TextStyle(fontSize: 11),
                          ),
                          dense: true,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Обновить списки'),
                              onPressed: _refreshLists,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SectionTitle(
                    'Заблокировано: ${f.stats.total} (реклама ${f.stats.blocked.ads} · трекеры ${f.stats.blocked.trackers} · малварь ${f.stats.blocked.malware} · торренты ${f.stats.blocked.torrents + f.stats.ports + f.stats.handshake})',
                  ),
                  if (f.recent.isEmpty)
                    const Text(
                      'Блокировок пока не было',
                      style: TextStyle(color: kDim, fontSize: 12),
                    )
                  else
                    for (final b in f.recent.take(15))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.block_outlined,
                          size: 18,
                          color: kWarn,
                        ),
                        title: Text(
                          b.target,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${b.category} · ${b.user} · ${fmtTime(b.ts)}',
                          style: const TextStyle(fontSize: 11, color: kDim),
                        ),
                      ),
                  SectionTitle(
                    'Свои домены (${f.config.customDomains.length})',
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final dom in f.config.customDomains)
                        InputChip(
                          label: Text(
                            dom,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onDeleted: () => _removeDomain(dom),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 16),
                        label: const Text(
                          'домен',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: _addDomain,
                      ),
                    ],
                  ),
                  SectionTitle(
                    'Источники списков (${f.config.sources.length})',
                  ),
                  for (final s in f.config.sources)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${s.name} · ${s.category}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        _sourceStatus(s, f),
                        style: const TextStyle(fontSize: 11, color: kDim),
                      ),
                      trailing: Switch(
                        value: s.enabled,
                        onChanged: (v) async {
                          final sources = f.config.sources
                              .map(
                                (x) => x == s
                                    ? ListSourceView(
                                        name: x.name,
                                        url: x.url,
                                        category: x.category,
                                        enabled: v,
                                      )
                                    : x,
                              )
                              .toList();
                          try {
                            await state.api!.filterSave(
                              FilterConfigView(
                                enabled: f.config.enabled,
                                blockTorrents: f.config.blockTorrents,
                                sources: sources,
                                customDomains: f.config.customDomains,
                              ),
                            );
                            _refresh();
                          } catch (e) {
                            if (mounted) {
                              showSnack(context, 'Ошибка: $e', error: true);
                            }
                          }
                        },
                      ),
                    ),
                  if (d != null) ...[
                    SectionTitle('DNS сервера (резолвы таргетов)'),
                    PaddedCard(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.config.servers.isEmpty
                                      ? 'системный резолвер ОС'
                                      : d.config.servers.join(', '),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              TextButton(
                                onPressed: _editDns,
                                child: const Text('Изменить'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'запросов ${d.stats.queries} · из кэша ${d.stats.cacheHits} · '
                            'ошибок ${d.stats.failures} · отклонено фильтром ${d.stats.blocked} · в кэше ${d.stats.cached}',
                            style: const TextStyle(fontSize: 11, color: kDim),
                          ),
                          if (d.top.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'Топ доменов:',
                              style: TextStyle(fontSize: 11, color: kDim),
                            ),
                            for (final t in d.top.take(8))
                              Text(
                                '${t.domain} — ${t.count}',
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 60),
                ],
              ),
            ),
    );
  }

  String _sourceStatus(ListSourceView s, FilterInfo f) {
    final st = f.sources.where((x) => x.name == s.name).toList();
    if (st.isEmpty) return s.url;
    final e = st.first;
    final when = e.lastUpdate > 0 ? fmtTime(e.lastUpdate) : 'никогда';
    final err = e.lastError.isEmpty ? '' : ' · ⚠ ${e.lastError}';
    return '${e.entries} правил · обновлен $when$err';
  }
}
