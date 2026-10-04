/// MeshPicker — UI для выбора mesh-выхода при подключении.
///
/// Используется в ConnectController.apply() когда SelectionKind.mesh.
/// Показывает список доступных peers + позволяет выбрать exit-peer.
///
/// См. docs/mesh/MESH_PLAN-v2.1.md §1.8 (multi-node selector) и
/// lib/service/connect/settings.dart (SelectionKind).
library;

import 'package:flutter/material.dart';
import 'package:backuppc_mesh/backuppc_mesh.dart';

/// MeshPicker — диалог выбора mesh-exit peer.
class MeshPicker extends StatefulWidget {
  final MeshConfig meshConfig;
  final String? initialSelection;

  const MeshPicker({
    super.key,
    required this.meshConfig,
    this.initialSelection,
  });

  @override
  State<MeshPicker> createState() => _MeshPickerState();
}

class _MeshPickerState extends State<MeshPicker> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelection ??
        (widget.meshConfig.chain.isNotEmpty
            ? widget.meshConfig.chain.first.peerUUID
            : null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Mesh exit'),
      content: SizedBox(
        width: 400,
        child: widget.meshConfig.chain.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Mesh не настроен.\nДобавьте peers в Mesh → Peers management.',
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Выберите exit-peer:',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.meshConfig.chain.length,
                      itemBuilder: (ctx, i) {
                        final hop = widget.meshConfig.chain[i];
                        final selected = hop.peerUUID == _selected;
                        return RadioListTile<String>(
                          value: hop.peerUUID,
                          groupValue: _selected,
                          onChanged: (v) => setState(() => _selected = v),
                          title: Text(hop.peerUUID.substring(0, 16) + '…'),
                          subtitle: Text('${hop.serverAddr}'),
                          secondary: Icon(
                            selected ? Icons.check_circle : Icons.circle_outlined,
                            color: selected ? theme.colorScheme.primary : null,
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  Text(
                    'Privacy: каждый peer знает только своих directly-configured peers',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: theme.disabledColor,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('Выбрать'),
        ),
      ],
    );
  }
}

/// MeshTopologyPicker — выбор топологии (full-mesh/star/chain/auto-discovery).
class MeshTopologyPicker extends StatefulWidget {
  final MeshTopology initial;
  final ValueChanged<MeshTopology> onChanged;

  const MeshTopologyPicker({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  @override
  State<MeshTopologyPicker> createState() => _MeshTopologyPickerState();
}

class _MeshTopologyPickerState extends State<MeshTopologyPicker> {
  late MeshTopology _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Topology (config hint for admin UI):'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: MeshTopology.values.map((t) {
            return ChoiceChip(
              label: Text(_topologyLabel(t)),
              selected: t == _value,
              onSelected: (selected) {
                if (selected) {
                  setState(() => _value = t);
                  widget.onChanged(t);
                }
              },
            );
          }).toList(growable: false),
        ),
      ],
    );
  }

  String _topologyLabel(MeshTopology t) {
    switch (t) {
      case MeshTopology.fullMesh:
        return 'Full mesh';
      case MeshTopology.star:
        return 'Star / hub';
      case MeshTopology.chain:
        return 'Chain / multihop';
      case MeshTopology.autoDiscovery:
        return 'Auto-discovery';
    }
  }
}

/// PerAppRulesEditor — UI для CRUD per-app routing rules.
///
/// См. lib/service/connect/backuppc/outbound.dart (extractPerAppRules,
/// updatePerAppRules, addPerAppRule, removePerAppRule).
///
/// Privacy (PROTOCOL.md §11.9): per-app routing rules — локальные на узле,
/// не распространяются по mesh. Admin UI одного узла видит только свои rules.
class PerAppRulesEditor extends StatefulWidget {
  final MeshConfig meshConfig;
  final ValueChanged<List<PerAppRule>> onChanged;

  const PerAppRulesEditor({
    super.key,
    required this.meshConfig,
    required this.onChanged,
  });

  @override
  State<PerAppRulesEditor> createState() => _PerAppRulesEditorState();
}

class _PerAppRulesEditorState extends State<PerAppRulesEditor> {
  late List<PerAppRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List.of(widget.meshConfig.perAppRules);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.apps, size: 18),
                const SizedBox(width: 8),
                Text('Per-app routing (${_rules.length} rules)',
                    style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _showAddDialog,
                  tooltip: 'Добавить правило',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'Нет per-app rules.\n'
                    'Android: com.example.app → peer\n'
                    'Windows: chrome.exe → peer',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                  ),
                ),
              )
            else
              ..._rules.map((r) => ListTile(
                    dense: true,
                    leading: Icon(
                      r.isExcluded ? Icons.block : Icons.router,
                      color: r.isExcluded ? Colors.red : theme.colorScheme.primary,
                      size: 20,
                    ),
                    title: Text(r.appPackage),
                    subtitle: Text(
                      r.isExcluded
                          ? 'bypass mesh (direct)'
                          : '→ ${r.peerUUID.substring(0, 8)}…',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () {
                        setState(() {
                          _rules = _rules
                              .where((x) => x.appPackage != r.appPackage)
                              .toList();
                          widget.onChanged(_rules);
                        });
                      },
                    ),
                  )),
            const SizedBox(height: 8),
            Text(
              'Privacy: rules — локальные, не распространяются по mesh',
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.disabledColor,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddDialog() async {
    String appPackage = '';
    String peerUUID = '';
    bool isExcluded = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('Per-app routing rule'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'App package *',
                        hintText: 'com.example.app (Android) или chrome.exe (Windows)',
                      ),
                      onChanged: (v) => appPackage = v,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Bypass mesh (direct)'),
                      subtitle: const Text('Если on — трафик приложения идёт напрямую, минуя mesh'),
                      value: isExcluded,
                      onChanged: (v) => setState(() => isExcluded = v),
                    ),
                    if (!isExcluded) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(
                          labelText: 'Peer UUID *',
                          hintText: 'Выберите peer для маршрутизации',
                        ),
                        items: widget.meshConfig.chain
                            .map((h) => DropdownMenuItem(
                                  value: h.peerUUID,
                                  child: Text('${h.peerUUID.substring(0, 8)}… '
                                      '(${h.serverAddr})'),
                                ))
                            .toList(),
                        onChanged: (v) => peerUUID = v ?? '',
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    if (appPackage.isEmpty) return;
                    if (!isExcluded && peerUUID.isEmpty) return;
                    setState(() {});
                    _rules.add(PerAppRule(
                      appPackage: appPackage,
                      peerUUID: peerUUID,
                      isExcluded: isExcluded,
                    ));
                    widget.onChanged(_rules);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
