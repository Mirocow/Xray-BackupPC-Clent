// ignore_for_file: lines_longer_than_80_chars

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/connect/compiler.dart';
import 'package:onexray/service/connect/settings.dart';
import 'package:onexray/service/servers/outbound/backuppc.dart';
import 'package:onexray/service/shared/json_tool.dart';

// native_outbound_test.dart — тест что compiler.dart на Android
// генерирует native backuppc outbound вместо socks + Dart tunnel.
//
// Проверяет:
// 1. Android + nativeBackuppcOutbound=true → outbound protocol=backuppc
// 2. Android + nativeBackuppcOutbound=false → outbound protocol=socks
// 3. iOS → outbound protocol=socks (no native on iOS)
// 4. Native outbound → backuppcTunnels пустой (нет Dart tunnel)

void main() {
  // Мок backuppc сервера для компилятора.
  final backuppcOutbound = <String, dynamic>{
    'protocol': 'backuppc',
    'tag': 'test-backuppc',
    'settings': {
      'serverAddr': 'example.com:443',
      'uuid': 'ab2c3d4e-5f67-8901-abcd-ef1234567890',
      'host': 'example.com',
    },
  };

  ResolvedServer makeServer() => ResolvedServer(
    row: ServerRow(
      type: 'outbound',
      data: {'outbound': JsonTool.copyMap(backuppcOutbound)},
    ),
  );

  test('Android + nativeBackuppcOutbound=true → protocol=backuppc', () {
    final settings = ConnectionSettings(
      expert: false,
      selection: const ServerSelection.server(id: 1),
      trafficMode: TrafficMode.allVpn,
      nativeBackuppcOutbound: true,
    );

    final result = Compiler.compile(
      settings: settings,
      entries: [makeServer()],
      finalExit: null,
      regions: RegionCatalog.empty,
      options: RuntimeOptions(
        platform: ConnectionPlatform.android,
        socksPort: 1080,
        metricsPort: 1081,
        backuppcPorts: [2001],
      ),
    );

    // Parse xray config JSON.
    final config = JsonTool.decode(result.xrayJson);
    final outbounds = config['outbounds'] as List<dynamic>;

    // Find the backuppc outbound.
    final backuppc = outbounds.firstWhere(
      (o) => (o as Map<String, dynamic>)['tag'] == 'test-backuppc',
      orElse: () => <String, dynamic>{},
    ) as Map<String, dynamic>;

    expect(backuppc['protocol'], 'backuppc',
        reason: 'Android with nativeBackuppcOutbound=true should emit '
            'native backuppc outbound, not socks');
  });

  test('Android + nativeBackuppcOutbound=false → protocol=socks', () {
    final settings = ConnectionSettings(
      expert: false,
      selection: const ServerSelection.server(id: 1),
      trafficMode: TrafficMode.allVpn,
      nativeBackuppcOutbound: false, // ← Dart tunnel fallback
    );

    final result = Compiler.compile(
      settings: settings,
      entries: [makeServer()],
      finalExit: null,
      regions: RegionCatalog.empty,
      options: RuntimeOptions(
        platform: ConnectionPlatform.android,
        socksPort: 1080,
        metricsPort: 1081,
        backuppcPorts: [2001],
      ),
    );

    final config = JsonTool.decode(result.xrayJson);
    final outbounds = config['outbounds'] as List<dynamic>;

    final backuppc = outbounds.firstWhere(
      (o) => (o as Map<String, dynamic>)['tag'] == 'test-backuppc',
      orElse: () => <String, dynamic>{},
    ) as Map<String, dynamic>;

    expect(backuppc['protocol'], 'socks',
        reason: 'Android with nativeBackuppcOutbound=false should fall back '
            'to socks + Dart tunnel');
  });

  test('iOS → protocol=socks (no native outbound on iOS)', () {
    final settings = ConnectionSettings(
      expert: false,
      selection: const ServerSelection.server(id: 1),
      trafficMode: TrafficMode.allVpn,
      nativeBackuppcOutbound: true, // ← even if true, iOS can't use native
    );

    final result = Compiler.compile(
      settings: settings,
      entries: [makeServer()],
      finalExit: null,
      regions: RegionCatalog.empty,
      options: RuntimeOptions(
        platform: ConnectionPlatform.ios, // ← iOS
        socksPort: 1080,
        metricsPort: 1081,
        backuppcPorts: [2001],
      ),
    );

    final config = JsonTool.decode(result.xrayJson);
    final outbounds = config['outbounds'] as List<dynamic>;

    final backuppc = outbounds.firstWhere(
      (o) => (o as Map<String, dynamic>)['tag'] == 'test-backuppc',
      orElse: () => <String, dynamic>{},
    ) as Map<String, dynamic>;

    expect(backuppc['protocol'], 'socks',
        reason: 'iOS should always use socks + Dart tunnel '
            '(no VpnService.protect available)');
  });

  test('Native outbound → backuppcTunnels empty (no Dart tunnel)', () {
    final settings = ConnectionSettings(
      expert: false,
      selection: const ServerSelection.server(id: 1),
      trafficMode: TrafficMode.allVpn,
      nativeBackuppcOutbound: true,
    );

    final result = Compiler.compile(
      settings: settings,
      entries: [makeServer()],
      finalExit: null,
      regions: RegionCatalog.empty,
      options: RuntimeOptions(
        platform: ConnectionPlatform.android,
        socksPort: 1080,
        metricsPort: 1081,
        backuppcPorts: [2001],
      ),
    );

    expect(result.backuppcTunnels, isEmpty,
        reason: 'Native outbound does not create Dart tunnels — '
            'Xray handles everything');
  });

  test('Dart tunnel fallback → backuppcTunnels not empty', () {
    final settings = ConnectionSettings(
      expert: false,
      selection: const ServerSelection.server(id: 1),
      trafficMode: TrafficMode.allVpn,
      nativeBackuppcOutbound: false, // ← Dart tunnel
    );

    final result = Compiler.compile(
      settings: settings,
      entries: [makeServer()],
      finalExit: null,
      regions: RegionCatalog.empty,
      options: RuntimeOptions(
        platform: ConnectionPlatform.android,
        socksPort: 1080,
        metricsPort: 1081,
        backuppcPorts: [2001],
      ),
    );

    expect(result.backuppcTunnels, isNotEmpty,
        reason: 'Dart tunnel fallback should create tunnels');
  });
}
