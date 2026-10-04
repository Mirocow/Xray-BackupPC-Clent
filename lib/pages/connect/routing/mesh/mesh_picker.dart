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
