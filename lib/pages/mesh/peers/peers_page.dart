/// MeshPeersPage — UI для управления mesh peers во Flutter-приложении.
///
/// Privacy (PROTOCOL.md §11.9): показывает только peers текущего узла.
/// Соседи не знают с кем связаны другие узлы.
///
/// См. docs/mesh/MESH_PLAN-v2.1.md §1.8 (Admin UI — multi-node selector)
/// и lib/service/connect/backuppc/mesh_session.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:backuppc_mesh/backuppc_mesh.dart';

/// MeshPeersPage — CRUD страница для mesh peers.
class MeshPeersPage extends StatefulWidget {
  final MeshConfig meshConfig;
  final String? meshAdminUrl;
  final String? meshAdminToken;

  const MeshPeersPage({
    super.key,
    required this.meshConfig,
    this.meshAdminUrl,
    this.meshAdminToken,
  });

  @override
  State<MeshPeersPage> createState() => _MeshPeersPageState();
}

class _MeshPeersPageState extends State<MeshPeersPage> {
  List<HopConfig> _peers = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPeers();
  }

  Future<void> _loadPeers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Если есть admin URL — fetch через REST API локального meshd
      if (widget.meshAdminUrl != null && widget.meshAdminUrl!.isNotEmpty) {
        final peers = await _fetchPeersFromMeshd();
        setState(() {
          _peers = peers;
          _loading = false;
        });
      } else {
        // Иначе — берём из MeshConfig.chain (локальное хранилище)
        setState(() {
          _peers = widget.meshConfig.chain;
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<List<HopConfig>> _fetchPeersFromMeshd() async {
    final url = '${widget.meshAdminUrl}/api/mesh/peers';
    final req = await HttpClient().getUrl(Uri.parse(url));
    if (widget.meshAdminToken != null && widget.meshAdminToken!.isNotEmpty) {
      req.headers.add('Authorization', 'Bearer ${widget.meshAdminToken}');
    }
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw Exception('Failed to load peers: HTTP ${resp.statusCode}');
    }
    final body = await resp.transform(utf8.decoder).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final peersJson = data['peers'] as List? ?? [];
    return peersJson
        .map((p) => HopConfig.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> _addPeer(HopConfig peer) async {
    setState(() => _loading = true);
    try {
      if (widget.meshAdminUrl != null && widget.meshAdminUrl!.isNotEmpty) {
        // POST to local meshd
        final url = '${widget.meshAdminUrl}/api/mesh/peers';
        final req = await HttpClient().postUrl(Uri.parse(url));
        req.headers.add('Authorization', 'Bearer ${widget.meshAdminToken}');
        req.headers.add('Content-Type', 'application/json');
        req.write(jsonEncode(peer.toJson()));
        final resp = await req.close();
        if (resp.statusCode != 201) {
          throw Exception('Failed to add peer: HTTP ${resp.statusCode}');
        }
      } else {
        // Local-only: добавить в chain (in-memory)
        // Production: persist в mesh-config.json
        setState(() {
          _peers = [..._peers, peer];
        });
      }
      await _loadPeers();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _removePeer(String peerUUID) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить peer?'),
        content: Text('Peer ${peerUUID.substring(0, 8)}… будет удалён из registry.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      if (widget.meshAdminUrl != null && widget.meshAdminUrl!.isNotEmpty) {
        final url = '${widget.meshAdminUrl}/api/mesh/peers/${Uri.encodeComponent(peerUUID)}';
        final req = await HttpClient().openUrl('DELETE', Uri.parse(url));
        req.headers.add('Authorization', 'Bearer ${widget.meshAdminToken}');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw Exception('Failed to remove peer: HTTP ${resp.statusCode}');
        }
      } else {
        setState(() {
          _peers = _peers.where((p) => p.peerUUID != peerUUID).toList();
        });
      }
      await _loadPeers();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mesh Peers'),
        actions: [
          IconButton(onPressed: _loadPeers, icon: const Icon(Icons.refresh)),
          IconButton(
            onPressed: () => _showAddPeerDialog(),
            icon: const Icon(Icons.add),
            tooltip: 'Добавить peer',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Ошибка: $_error', style: theme.textTheme.bodyMedium),
                  ),
                )
              : _peers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.hub, size: 64, color: theme.disabledColor),
                          const SizedBox(height: 16),
                          Text('Peers не настроены',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          const Text('Добавьте peer для mesh-соединения'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _peers.length,
                      itemBuilder: (ctx, i) {
                        final p = _peers[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.router)),
                            title: Text(p.peerUUID.substring(0, 16) + '…'),
                            subtitle: Text('${p.serverAddr}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => _removePeer(p.peerUUID),
                            ),
                          ),
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddPeerDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showAddPeerDialog() async {
    final formKey = GlobalKey<FormState>();
    String peerUUID = '';
    String serverAddr = '';
    String uuid = '';
    String publicKey = '';
    String certFingerprint = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый peer'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Peer UUID *'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Обязательно' : null,
                    onSaved: (v) => peerUUID = v ?? '',
                  ),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Server addr (host:port) *'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Обязательно' : null,
                    onSaved: (v) => serverAddr = v ?? '',
                  ),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'VLESS UUID *'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Обязательно' : null,
                    onSaved: (v) => uuid = v ?? '',
                  ),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Public key (base64)'),
                    onSaved: (v) => publicKey = v ?? '',
                  ),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Cert fingerprint (SHA-256 hex)'),
                    onSaved: (v) => certFingerprint = v ?? '',
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              formKey.currentState!.save();
              Navigator.pop(ctx);
              _addPeer(HopConfig(
                peerUUID: peerUUID,
                serverAddr: serverAddr,
                uuid: uuid,
                publicKey: publicKey,
                certFingerprint: certFingerprint,
              ));
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
  }
}
