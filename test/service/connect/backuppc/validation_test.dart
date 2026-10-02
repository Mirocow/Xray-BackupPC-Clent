import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/connect/backuppc/validation.dart';

Map<String, dynamic> _vless() => {
  'tag': 'node',
  'protocol': 'vless',
  'settings': {
    'address': 'example.com',
    'port': 443,
    'id': '00000000-0000-0000-0000-000000000000',
    'encryption': 'none',
  },
};

Map<String, dynamic> _backuppc() => {
  'tag': 'backup',
  'protocol': 'backuppc',
  'settings': {
    'serverAddr': 'backup.example.com:8443',
    'uuid': '52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90',
    'host': 'cdn.example.com',
    'endpointPaths': ['/backuppc.BackupService/BackupStream'],
  },
};

void main() {
  test('backuppc-only list never reaches the native validator', () async {
    var nativeCalls = 0;
    final error = await validateOutboundsMixed([_backuppc()], (_) async {
      nativeCalls++;
      return 'rejected';
    });

    expect(error, isEmpty);
    expect(nativeCalls, 0);
  });

  test('native-only list keeps the native path and config shape', () async {
    final configs = <String>[];
    final error = await validateOutboundsMixed(
      [_vless()],
      (config) async {
        configs.add(config);
        return '';
      },
    );

    expect(error, isEmpty);
    expect(configs, hasLength(1));
    expect(configs.single, contains('"outbounds"'));
  });

  test('mixed list validates both parts and merges errors', () async {
    final configs = <String>[];
    final error = await validateOutboundsMixed(
      [
        _backuppc(),
        _vless(),
        {
          'tag': 'broken',
          'protocol': 'backuppc',
          'settings': {'serverAddr': ''},
        },
      ],
      (config) async {
        configs.add(config);
        return 'Invalid node';
      },
    );

    // Ошибки обеих сторон склеены.
    expect(error, contains('Invalid node'));
    expect(error, contains('backuppc'));
    // Нативный валидатор получил только vless.
    expect(configs, hasLength(1));
    expect(configs.single, isNot(contains('backuppc')));
  });

  test('non-map elements go to the native validator as before', () async {
    var nativeCalls = 0;
    final error = await validateOutboundsMixed([1], (_) async {
      nativeCalls++;
      return 'Invalid node';
    });

    expect(error, 'Invalid node');
    expect(nativeCalls, 1);
  });
}
