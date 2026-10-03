/// «Ещё»: TLS-карточка (режим/сроки/отпечаток/горячая замена),
/// несущие пути сервера, журнал (последние события), выход/забыть.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../ui.dart';
import '../util/format.dart';
import '../api/models.dart';

class MorePage extends StatefulWidget {
  final AppState state;
  const MorePage(this.state, {super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  CertInfo? _cert;
  List<String> _paths = [];
  List<LogEntry> _logs = [];
  String? _err;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final api = state.api!;
    final futures = await Future.wait([
      api.tls().catchError(
        (_) => CertInfo(
          mode: '',
          subject: '',
          issuer: '',
          notAfter: 0,
          daysLeft: 0,
          fingerprint: '',
        ),
      ),
      api.endpointPaths().catchError((_) => const <String>[]),
      api.logs().catchError((_) => <LogEntry>[]),
    ]);
    if (mounted) {
      setState(() {
        _cert = futures[0] as CertInfo;
        _paths = (futures[1] as List).cast<String>();
        _logs = (futures[2] as List).cast<LogEntry>();
      });
    }
  }

  Future<void> _reloadCert() async {
    try {
      await state.api!.tlsReload();
      await _refresh();
      if (mounted) showSnack(context, 'Сертификат перечитан');
    } catch (e) {
      if (mounted) showSnack(context, 'Ошибка: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _cert;
    return Scaffold(
      appBar: AppBar(title: const Text('Ещё')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            const SectionTitle('Сертификат (несущий канал)'),
            PaddedCard(
              c == null
                  ? const Text('…')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              c.isReal
                                  ? Icons.verified_outlined
                                  : Icons.warning_amber_outlined,
                              size: 18,
                              color: c.isReal ? kUp : kWarn,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              c.isReal
                                  ? 'реальный (Let\'s Encrypt и т.п.)'
                                  : 'самоподписанный',
                              style: TextStyle(
                                color: c.isReal ? kUp : kWarn,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'subject: ${c.subject}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          'issuer: ${c.issuer}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          'истекает: ${fmtTime(c.notAfter)} (${c.daysLeft.toStringAsFixed(0)} дн.)',
                          style: TextStyle(
                            fontSize: 12,
                            color: c.daysLeft < 14 ? kWarn : null,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'SHA-256: ${c.fingerprint.substring(0, c.fingerprint.length > 24 ? 24 : c.fingerprint.length)}…',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: kDim,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 16),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: c.fingerprint),
                                );
                                showSnack(context, 'Отпечаток скопирован');
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Перечитать файлы (certbot)'),
                          onPressed: _reloadCert,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Реальный сертификат домена-донора делает узел '
                          'неотличимым от обычного сайта для наблюдателя '
                          '(§10 PROTOCOL). Перевыпуск certbot подхватывается '
                          'автоматом раз в час.',
                          style: TextStyle(fontSize: 11, color: kDim),
                        ),
                      ],
                    ),
            ),
            SectionTitle('Несущие методы сервера (${_paths.length})'),
            if (_paths.isEmpty)
              const Text('—', style: TextStyle(color: kDim))
            else
              Text(
                _paths.join('\n'),
                style: const TextStyle(fontSize: 11, color: kDim),
              ),
            const SectionTitle('Журнал (последние события)'),
            if (_logs.isEmpty)
              const Text('Журнал пуст', style: TextStyle(color: kDim))
            else
              for (final l in _logs.reversed.take(30))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.msg, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    '${l.level} · ${fmtTime(l.ts)}',
                    style: const TextStyle(fontSize: 10, color: kDim),
                  ),
                ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.logout),
              label: const Text('Выйти'),
              onPressed: () => state.logout(),
            ),
            const SizedBox(height: 8),
            if (state.saved != null)
              TextButton(
                onPressed: () async {
                  await state.forget();
                  state.logout();
                },
                child: const Text('Забыть сохраненный профиль'),
              ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
