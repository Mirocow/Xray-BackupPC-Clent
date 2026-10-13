import 'package:test/test.dart';
import 'package:backuppc_mesh/backuppc_mesh.dart';

void main() {
  group('HopConfig', () {
    test('toJson + fromJson round-trip', () {
      final original = HopConfig(
        peerUUID: '8d1f6c5a-3b7e-4d2a-9c1f-5e6d7a8b9c0d',
        serverAddr: 'berlin.corp:9443',
        uuid: '52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90',
        certFingerprint: 'abcdef0123456789',
        insecure: false,
        host: 'donor.example.com',
        publicKey: 'base64-pubkey',
        role: MeshRole.hybrid,
      );
      final json = original.toJson();
      final restored = HopConfig.fromJson(json);

      expect(restored.peerUUID, equals(original.peerUUID));
      expect(restored.serverAddr, equals(original.serverAddr));
      expect(restored.uuid, equals(original.uuid));
      expect(restored.certFingerprint, equals(original.certFingerprint));
      expect(restored.insecure, equals(original.insecure));
      expect(restored.host, equals(original.host));
      expect(restored.publicKey, equals(original.publicKey));
      expect(restored.role, equals(original.role));
    });

    test('splitServerAddr with port', () {
      final hop = HopConfig(
        peerUUID: 'test',
        serverAddr: 'berlin.corp:9443',
        uuid: 'uuid',
      );
      final (host, port) = hop.splitServerAddr();
      expect(host, equals('berlin.corp'));
      expect(port, equals(9443));
    });

    test('splitServerAddr default port', () {
      final hop = HopConfig(
        peerUUID: 'test',
        serverAddr: 'berlin.corp',
        uuid: 'uuid',
      );
      final (host, port) = hop.splitServerAddr();
      expect(host, equals('berlin.corp'));
      expect(port, equals(443));
    });

    test('splitServerAddr with IPv6 brackets', () {
      final hop = HopConfig(
        peerUUID: 'test',
        serverAddr: '[2a00:1450:4003:80b::200e]:9443',
        uuid: 'uuid',
      );
      final (host, port) = hop.splitServerAddr();
      expect(host, equals('2a00:1450:4003:80b::200e'));
      expect(port, equals(9443));
    });
  });

  group('MeshConfig', () {
    test('fromJson with chain', () {
      final cfg = MeshConfig.fromJson({
        'chain': [
          {
            'peerUUID': 'peer-1',
            'serverAddr': 'a:9443',
            'uuid': 'uuid-1',
          },
          {
            'peerUUID': 'peer-2',
            'serverAddr': 'b:9443',
            'uuid': 'uuid-2',
          },
        ],
        'topology': 'star',
        'role': 'hybrid',
      });
      expect(cfg.chain.length, equals(2));
      expect(cfg.chain[0].peerUUID, equals('peer-1'));
      expect(cfg.topology, equals(MeshTopology.star));
      expect(cfg.role, equals(MeshRole.hybrid));
      expect(cfg.isMesh, isTrue);
    });

    test('empty chain → not mesh', () {
      final cfg = MeshConfig.fromJson({});
      expect(cfg.isMesh, isFalse);
    });

    test('default topology is fullMesh', () {
      final cfg = MeshConfig.fromJson({});
      expect(cfg.topology, equals(MeshTopology.fullMesh));
    });

    test('default role is client', () {
      final cfg = MeshConfig.fromJson({});
      expect(cfg.role, equals(MeshRole.client));
    });
  });

  group('PerAppRule', () {
    test('toJson + fromJson', () {
      final rule = PerAppRule(
        appPackage: 'com.example.app',
        peerUUID: 'peer-1',
        isExcluded: false,
      );
      final json = rule.toJson();
      final restored = PerAppRule.fromJson(json);
      expect(restored.appPackage, equals('com.example.app'));
      expect(restored.peerUUID, equals('peer-1'));
      expect(restored.isExcluded, isFalse);
    });

    test('excluded rule', () {
      final rule = PerAppRule(
        appPackage: 'com.excluded.app',
        peerUUID: '',
        isExcluded: true,
      );
      expect(rule.isExcluded, isTrue);
    });
  });

  group('GeoRule', () {
    test('toJson + fromJson', () {
      final rule = GeoRule(
        geosite: 'geosite:RU',
        countryCode: 'RU',
        peerUUID: 'ru-peer',
      );
      final json = rule.toJson();
      final restored = GeoRule.fromJson(json);
      expect(restored.geosite, equals('geosite:RU'));
      expect(restored.countryCode, equals('RU'));
      expect(restored.peerUUID, equals('ru-peer'));
    });
  });

  group('HopRouter', () {
    test('per-app rule match', () {
      final cfg = MeshConfig(
        perAppRules: [
          PerAppRule(appPackage: 'com.test.app', peerUUID: 'peer-1'),
          PerAppRule(appPackage: 'com.excluded', isExcluded: true),
        ],
        chain: [
          HopConfig(peerUUID: 'default', serverAddr: 'd:9443', uuid: 'u'),
        ],
      );
      final router = HopRouter(cfg);

      // Match → peer-1
      expect(
        router.resolve('target.com:443', appPackage: 'com.test.app'),
        equals('peer-1'),
      );

      // Excluded → null (direct)
      expect(
        router.resolve('target.com:443', appPackage: 'com.excluded'),
        isNull,
      );

      // No match → default
      expect(
        router.resolve('target.com:443', appPackage: 'com.other'),
        equals('default'),
      );
    });

    test('geo rule suffix match', () {
      final cfg = MeshConfig(
        geoRules: [
          GeoRule(countryCode: 'RU', peerUUID: 'ru-peer'),
        ],
        chain: [
          HopConfig(peerUUID: 'default', serverAddr: 'd:9443', uuid: 'u'),
        ],
      );
      final router = HopRouter(cfg);

      expect(router.resolve('example.ru:443'), equals('ru-peer'));
      expect(router.resolve('example.com:443'), equals('default'));
    });

    test('single-hop fallback', () {
      final cfg = MeshConfig(
        chain: [
          HopConfig(peerUUID: 'only-peer', serverAddr: 'o:9443', uuid: 'u'),
        ],
      );
      final router = HopRouter(cfg);
      expect(router.resolve('target.com:443'), equals('only-peer'));
    });

    test('empty chain → null', () {
      final cfg = MeshConfig(chain: []);
      final router = HopRouter(cfg);
      expect(router.resolve('target.com:443'), isNull);
    });

    test('latency cache add + get', () {
      final cfg = MeshConfig(
        loadBasedRouting: true,
        chain: [
          HopConfig(peerUUID: 'peer-a', serverAddr: 'a:9443', uuid: 'u'),
          HopConfig(peerUUID: 'peer-b', serverAddr: 'b:9443', uuid: 'u'),
        ],
      );
      final router = HopRouter(cfg);

      // No latency data → first peer
      expect(router.resolve('target.com:443'), equals('peer-a'));

      // Add latency for peer-b (better)
      router.addLatencySample('peer-b', 50);
      expect(router.resolve('target.com:443'), equals('peer-b'));
    });
  });

  group('MeshPath', () {
    test('construction with streamGroupID', () {
      final path = MeshPath(
        hops: [
          HopConfig(peerUUID: 'hop-1', serverAddr: 'h1:9443', uuid: 'u1'),
        ],
        target: 'target.example.com',
        port: 443,
      );
      expect(path.hops.length, equals(1));
      expect(path.target, equals('target.example.com'));
      expect(path.port, equals(443));
      expect(path.streamGroupID, isNotEmpty);
      expect(path.streamGroupID.startsWith('mesh-'), isTrue);
    });

    test('nextHopUUID from first hop', () {
      final path = MeshPath(
        hops: [
          HopConfig(peerUUID: 'first', serverAddr: 'f:9443', uuid: 'u'),
          HopConfig(peerUUID: 'second', serverAddr: 's:9443', uuid: 'u'),
        ],
        target: 'target.com',
        port: 443,
      );
      expect(path.nextHopUUID, equals('first'));
    });

    test('empty hops → null nextHopUUID', () {
      final path = MeshPath(
        hops: [],
        target: 'target.com',
        port: 443,
      );
      expect(path.nextHopUUID, isNull);
    });

    test('hasLoop detects existing peer', () {
      final path = MeshPath(
        hops: [
          HopConfig(peerUUID: 'peer-a', serverAddr: 'a:9443', uuid: 'u'),
        ],
        target: 'target.com',
        port: 443,
      );
      expect(path.hasLoop('peer-a'), isTrue);
      expect(path.hasLoop('peer-b'), isFalse);
    });

    test('addForwarder dedup', () {
      final path = MeshPath(
        hops: [],
        target: 'target.com',
        port: 443,
      );
      path.addForwarder('peer-1');
      path.addForwarder('peer-1'); // duplicate
      path.addForwarder('peer-2');
      expect(path.forwardedBy.length, equals(2));
      expect(path.forwardedBy, contains('peer-1'));
      expect(path.forwardedBy, contains('peer-2'));
    });
  });
}
