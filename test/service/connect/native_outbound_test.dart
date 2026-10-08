import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/connect/compiler.dart';
import 'package:onexray/service/connect/routing/region_catalog.dart';
import 'package:onexray/service/connect/settings.dart';

// Android: узлы backuppc — нативный outbound ядра (settings.nativeBackuppcOutbound,
// по умолчанию включён) вместо socks на Dart-туннель.

final _catalog = RegionCatalog.fromJson(
  {
    'geosite': <String, List<String>>{},
    'geoip': <String, List<String>>{},
  },
  geositeCodes: const [],
  geoipCodes: const [],
);

RuntimeOptions _options([
  ConnectionPlatform platform = ConnectionPlatform.android,
]) => RuntimeOptions(
  platform: platform,
  sessionDirectory: '/unused-session',
  metricsPort: 18186,
  socksPort: 18187,
);

Map<String, dynamic> _backuppcOutbound() => {
  'tag': 'user tag',
  'protocol': 'backuppc',
  'settings': {
    'serverAddr': '203.0.113.7:8443',
    'uuid': '0b3e6f1a-1111-4222-8333-944455556666',
    'host': 'backup.example.org',
    'certFingerprint': 'abcdef',
  },
};

ResolvedServer _backuppc(int id) =>
    ResolvedServer(id: id, sourceId: 1, outbound: _backuppcOutbound());

ConnectionSettings _allVpn({bool native = true}) => ConnectionSettings(
  trafficMode: TrafficMode.allVpn,
  nativeBackuppcOutbound: native,
);

CompiledConnection _compile(
  ConnectionSettings settings, {
  ConnectionPlatform platform = ConnectionPlatform.android,
}) => ConnectionCompiler.compile(
  settings: settings,
  entries: [_backuppc(1)],
  regions: _catalog,
  options: _options(platform),
  backuppcPorts: const [20001],
);

Map<String, dynamic> _outbound(CompiledConnection plan, String tag) =>
    (plan.config['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
      (o) => o['tag'] == tag,
    );

String _proxyDns(CompiledConnection plan) =>
    (plan.config['dns']['servers'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((s) => s['tag'] == 'app-dns-proxy')['address']
        as String;

void main() {
  test('Android, native on (default): backuppc stays a core outbound', () {
    expect(ConnectionSettings().nativeBackuppcOutbound, isTrue);
    final plan = _compile(_allVpn());
    final entry = _outbound(plan, 'app-entry-0');
    expect(entry['protocol'], 'backuppc');
    expect(entry['settings'], _backuppcOutbound()['settings']);
    expect(plan.backuppcTunnels, isEmpty);
  });

  test('Android, native off: socks to the local Dart tunnel', () {
    final plan = _compile(_allVpn(native: false));
    expect(_outbound(plan, 'app-entry-0')['protocol'], 'socks');
    expect(plan.backuppcTunnels.single.port, 20001);
  });

  test('other platforms keep the Dart tunnel even with the flag on', () {
    final plan = _compile(_allVpn(), platform: ConnectionPlatform.ios);
    expect(_outbound(plan, 'app-entry-0')['protocol'], 'socks');
    expect(plan.backuppcTunnels, hasLength(1));
  });

  test('native: proxy DNS goes over TCP (backuppc carries no UDP)', () {
    expect(_proxyDns(_compile(_allVpn())), 'tcp://8.8.8.8');
    expect(_proxyDns(_compile(_allVpn(native: false))), '8.8.8.8');
  });

  test('native: a chained final exit stays on the Dart tunnel', () {
    final plan = ConnectionCompiler.compile(
      settings: ConnectionSettings(
        nativeBackuppcOutbound: true,
        smart: SmartRoutingSettings(entryCount: 1, finalExitId: 9),
      ),
      entries: [
        ResolvedServer(
          id: 1,
          sourceId: 1,
          outbound: {
            'protocol': 'socks',
            'settings': {'address': '198.51.100.1', 'port': 1080},
          },
        ),
      ],
      finalExit: _backuppc(9),
      regions: _catalog,
      options: _options(),
      backuppcPorts: const [20001],
    );
    final exit = _outbound(plan, 'app-exit-0');
    // нативный outbound не использует dialerProxy: выход обошёл бы вход
    expect(exit['protocol'], 'socks');
    expect(exit['streamSettings']['sockopt']['dialerProxy'], 'app-entry-0');
    expect(plan.backuppcTunnels, hasLength(1));
  });

  test('native: Raw keeps backuppc outbounds untouched', () {
    final plan = ConnectionCompiler.compile(
      settings: ConnectionSettings(expert: true, nativeBackuppcOutbound: true),
      entries: const [],
      raw: {
        'outbounds': [
          {..._backuppcOutbound(), 'tag': 'bpc'},
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
      },
      regions: _catalog,
      options: _options(),
      backuppcPorts: const [20001],
    );
    expect(_outbound(plan, 'bpc')['protocol'], 'backuppc');
    expect(plan.backuppcTunnels, isEmpty);
  });
}
