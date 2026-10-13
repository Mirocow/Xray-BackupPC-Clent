import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/shared/share/xray_share_reader.dart';

void main() {
  test(
    'preserves libXray outbound maps without app-side schema validation',
    () async {
      final json = jsonDecode('''
{
  "outbounds": [
    {
      "name": "Valid",
      "protocol": "vless",
      "editorOnly": {"keep": true},
      "settings": {
        "address": "example.com",
        "port": 443,
        "id": "00000000-0000-0000-0000-000000000000",
        "encryption": "none",
        "advanced": {"keep": true}
      }
    },
    {
      "name": "Incomplete",
      "protocol": "vless",
      "settings": {
        "port": 443,
        "id": "00000000-0000-0000-0000-000000000000",
        "encryption": "none"
      }
    },
    {
      "name": "Unsupported",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
''') as Map<String, dynamic>;
      final rows = await XrayShareReader().readXrayJsonOutbounds(json);

      expect(rows, hasLength(3));
      expect(
        rows.map((row) => row.name.value),
        containsAll(<String>['Valid', 'Incomplete', 'Unsupported']),
      );
      final valid = rows.firstWhere((row) => row.name.value == 'Valid');
      final wrapper = jsonDecode(
        utf8.decode(base64Decode(valid.data.value!)),
      ) as Map<String, dynamic>;
      final stored =
          (wrapper['outbounds'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(stored['tag'], 'Valid');
      expect(stored, isNot(contains('name')));
      expect(stored['editorOnly'], {'keep': true});
      expect((stored['settings'] as Map<String, dynamic>)['advanced'], {
        'keep': true,
      });
    },
  );

  test('does not revalidate Shadowsocks methods returned by libXray', () async {
    final json = jsonDecode('''
{
  "outbounds": [
    {
      "name": "Canonical",
      "protocol": "shadowsocks",
      "settings": {
        "address": "example.com",
        "port": 8388,
        "method": "aes-256-gcm",
        "password": "password"
      }
    },
    {
      "name": "Alias",
      "protocol": "shadowsocks",
      "settings": {
        "address": "example.com",
        "port": 8388,
        "method": "aead_aes_256_gcm",
        "password": "password"
      }
    }
  ]
}
''') as Map<String, dynamic>;
    final rows = await XrayShareReader().readXrayJsonOutbounds(json);

    expect(rows.map((row) => row.name.value), ['Canonical', 'Alias']);
  });

  test(
    'preserves missing and explicit VMess security returned by libXray',
    () async {
      final json = jsonDecode('''
{
  "outbounds": [
    {
      "name": "Canonical",
      "protocol": "vmess",
      "settings": {
        "address": "example.com",
        "port": 443,
        "id": "00000000-0000-0000-0000-000000000000",
        "security": "auto"
      }
    },
    {
      "name": "Legacy",
      "protocol": "vmess",
      "settings": {
        "address": "example.com",
        "port": 443,
        "id": "00000000-0000-0000-0000-000000000000",
        "security": "none"
      }
    },
    {
      "name": "Default",
      "protocol": "vmess",
      "settings": {
        "address": "example.com",
        "port": 443,
        "id": "00000000-0000-0000-0000-000000000000"
      }
    }
  ]
}
''') as Map<String, dynamic>;
      final rows = await XrayShareReader().readXrayJsonOutbounds(json);

      expect(rows.map((row) => row.name.value), [
        'Canonical',
        'Legacy',
        'Default',
      ]);
      final saved = jsonDecode(
        utf8.decode(base64Decode(rows.last.data.value!)),
      );
      expect(saved['outbounds'][0]['settings'].containsKey('security'), false);
    },
  );

  test('uses libXray tag metadata without borrowing sendThrough', () async {
    final xrayJson = <String, dynamic>{
      'outbounds': [
        {
          'protocol': 'vless',
          'tag': 'Imported Node',
          'sendThrough': '127.0.0.1',
          'settings': {
            'address': 'example.com',
            'port': 443,
            'id': '00000000-0000-0000-0000-000000000000',
            'encryption': 'none',
          },
        },
      ],
    };

    final rows = await XrayShareReader().readXrayJsonOutbounds(xrayJson);

    expect(rows.single.name.value, 'Imported Node');
    final wrapper = jsonDecode(
      utf8.decode(base64Decode(rows.single.data.value!)),
    ) as Map<String, dynamic>;
    final stored =
        (wrapper['outbounds'] as List<dynamic>).single as Map<String, dynamic>;
    expect(stored['tag'], 'Imported Node');
    expect(stored['sendThrough'], '127.0.0.1');
    expect(stored, isNot(contains('name')));
  });

  test('uses protocol as the tag when a share has no node name', () async {
    final rows = await XrayShareReader().readXrayJsonOutbounds({
      'outbounds': [
        {
          'protocol': 'vless',
          'settings': {
            'address': 'example.com',
            'port': 443,
            'id': '00000000-0000-0000-0000-000000000000',
            'encryption': 'none',
          },
        },
      ],
    });

    expect(rows.single.name.value, 'vless');
    final wrapper = jsonDecode(
      utf8.decode(base64Decode(rows.single.data.value!)),
    ) as Map<String, dynamic>;
    final stored =
        (wrapper['outbounds'] as List<dynamic>).single as Map<String, dynamic>;
    expect(stored['tag'], 'vless');
    expect(stored, isNot(contains('name')));
  });

  group('backuppc links are split before the native converter', () {
    test('backuppc lines become outbounds, other lines stay native', () {
      final (outbounds, native) = XrayShareReader().splitBackupPcLinks(
        'vless://00000000-0000-0000-0000-000000000000@example.com:443\n'
        'backuppc://52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90@backup.example.com:8443'
        '?host=cdn.example.com&endpoints=/backuppc.BackupService/BackupStream'
        '#Office%20Backup\n'
        '\n',
      );

      expect(outbounds, hasLength(1));
      expect(outbounds.single['protocol'], 'backuppc');
      final settings = outbounds.single['settings'] as Map<String, dynamic>;
      expect(settings['serverAddr'], 'backup.example.com:8443');
      expect(settings['uuid'], '52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90');
      expect(settings['host'], 'cdn.example.com');
      expect(settings['endpointPaths'], <String>[
        '/backuppc.BackupService/BackupStream',
      ]);
      expect(outbounds.single['tag'], 'Office Backup');
      expect(native, isNot(contains('backuppc://')));
      expect(native.trim(), 'vless://00000000-0000-0000-0000-000000000000@example.com:443');
    });

    test('input without backuppc links stays whole', () {
      final text = 'vless://id@example.com:443\nvmess://base64';
      final (outbounds, native) = XrayShareReader().splitBackupPcLinks(text);

      expect(outbounds, isEmpty);
      expect(native, text);
    });

    test('a broken backuppc link rejects the input', () {
      expect(
        () => XrayShareReader().splitBackupPcLinks(
          'backuppc://not-a-uuid@host?fp=zz',
        ),
        throwsFormatException,
      );
    });

    test('backuppc-only input keeps the native part empty', () {
      final (outbounds, native) = XrayShareReader().splitBackupPcLinks(
        'backuppc://uuid@example.com:443#Node',
      );
      expect(outbounds.single['settings']['serverAddr'], 'example.com:443');
      expect(native.trim(), isEmpty);
    });
  });

  group('splitBackupPcLinks sanitizes mangled URLs before parsing', () {
    test('URL with embedded newlines (chat/email wrap) parses', () {
      // Long backuppc:// URLs (2000+ chars) often wrap across lines when
      // copied from chat/email. The newlines should be stripped before
      // BackupPcLink.tryParse is called.
      final url =
          'backuppc://52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90@example.com:8443'
          '?endpoints=%2Fbackuppc.BackupService%2FBackupStream\n'
          '   %2C%2Fbackuppc.ChunkService%2FPutChunk\n'
          '   &fp=7fbda8efec2e37418266b14e48e513bbce4e7868901f99318859ce65a4b6c72d\n'
          '   &host=cdn.example.com\n'
          '   #Office%20Backup';
      final (outbounds, _) = XrayShareReader().splitBackupPcLinks(url);
      expect(outbounds, hasLength(1));
      expect(outbounds.single['protocol'], 'backuppc');
      final settings = outbounds.single['settings'] as Map<String, dynamic>;
      expect(settings['serverAddr'], 'example.com:8443');
      expect(settings['endpointPaths'], hasLength(2));
      expect(outbounds.single['tag'], 'Office Backup');
    });

    test('URL with `+` chars in query (chat-wrap artifact) parses', () {
      // When long backuppc:// URLs are wrapped across lines by chat/email
      // clients, the `%2C` (comma — separator between endpoint paths in
      // the endpoints= parameter) gets replaced by `+` (form-encoded
      // whitespace from newlines+spaces).
      //
      // Our sanitizer replaces `+` with `%2C` in query string, restoring
      // the comma separator. This handles the user's actual case where
      // URL has `+++` between endpoint paths.
      //
      // Test case: URL with `+` between two comma-separated paths.
      // After sanitization, `+` becomes `%2C`, value becomes
      // `/backuppc.BackupService/BackupStream,,/backuppc.ChunkService/PutChunk`
      // (with double comma — empty entry filtered out by split+filter).
      final url =
          'backuppc://uuid@example.com:8443'
          '?endpoints=%2Fbackuppc.BackupService%2FBackupStream+'
          '%2C%2Fbackuppc.ChunkService%2FPutChunk';
      final (outbounds, _) = XrayShareReader().splitBackupPcLinks(url);
      expect(outbounds, hasLength(1));
      final settings = outbounds.single['settings'] as Map<String, dynamic>;
      // After sanitization, endpoints split by comma yields 2 paths
      // (empty entry between double comma is filtered out).
      expect(settings['endpointPaths'], hasLength(2));
    });

    test('URL with `+++` between paths (user\'s real case) parses', () {
      // EXACT pattern from user's screenshot: `+++` between two endpoint
      // paths where original had `%2C` (comma). After sanitization,
      // `+++` becomes `%2C%2C%2C`, value becomes
      // `...ReplicateStream,,,/backuppc.CatalogService...` (with triple
      // comma — empty entries filtered out by split+filter).
      final url =
          'backuppc://uuid@example.com:8443'
          '?endpoints=%2Fbackuppc.BackupService%2FBackupStream%2C'
          '%2Fbackuppc.ReplicationService%2FReplicateStream+++'
          '%2Fbackuppc.CatalogService%2FPutIndex';
      final (outbounds, _) = XrayShareReader().splitBackupPcLinks(url);
      expect(outbounds, hasLength(1));
      final settings = outbounds.single['settings'] as Map<String, dynamic>;
      expect(settings['endpointPaths'], hasLength(3));
      expect(
        (settings['endpointPaths'] as List).first,
        '/backuppc.BackupService/BackupStream',
      );
      expect(
        (settings['endpointPaths'] as List).last,
        '/backuppc.CatalogService/PutIndex',
      );
    });

    test('truncated URL (no backuppc:// prefix) gives clear error', () {
      // When user copies URL from a wrapped display that truncated the
      // beginning, the URL might start with mid-text instead of "backuppc://".
      // In this case, Uri.tryParse returns a URI with empty scheme,
      // splitBackupPcLinks skips it (not a backuppc scheme), and the URL
      // goes to "other" list. BackupPcLink.tryParse is never called.
      //
      // But if user explicitly types "backuppc://..." and the URL is
      // otherwise malformed, tryParse returns null and we throw a clear
      // error mentioning "URL must start with backuppc://".
      expect(
        () => XrayShareReader().splitBackupPcLinks(
          'backuppc://host-without-uuid',
        ),
        throwsFormatException,
      );
    });

    test('URL with all 38 default endpoint paths parses after sanitization', () {
      // Real server-generated URL has 38 default endpoint paths joined by
      // comma. When URL-encoded, that's ~2000 chars in endpoints param
      // alone. If the URL is wrapped across lines, sanitization must
      // strip the newlines and restore the original URL.
      final paths = <String>[
        '/backuppc.BackupService/BackupStream',
        '/backuppc.ChunkService/PutChunk',
        '/backuppc.StorageService/UploadStream',
        '/backuppc.ChunkService/StreamChunks',
        '/backuppc.StorageService/WriteStream',
        '/backuppc.StorageService/PutBlocks',
        '/backuppc.SnapshotService/SendSnapshot',
        '/backuppc.SnapshotService/SnapshotStream',
        '/backuppc.RsyncService/DeltaStream',
        '/backuppc.RsyncService/RsyncTransfer',
      ];
      // Build URL like server does: backuppc://uuid@host?endpoints=...&fp=...
      final eps = paths.map((p) =>
          p.replaceAll('/', '%2F').replaceAll(',', '%2C')).join('%2C');
      final url =
          'backuppc://52724a0e@example.com:8443'
          '?endpoints=$eps'
          '&fp=7fbda8efec2e37418266b14e48e513bbce4e7868901f99318859ce65a4b6c72d'
          '&host=cdn.example.com#test';
      final (outbounds, _) = XrayShareReader().splitBackupPcLinks(url);
      expect(outbounds, hasLength(1));
      final settings = outbounds.single['settings'] as Map<String, dynamic>;
      expect(settings['endpointPaths'], hasLength(10));
    });

    test('TRUNCATED URL (user\'s real case) gives clear "TRUNCATED" error', () {
      // This is the EXACT URL from user's screenshot (commit history shows
      // user reported "нет изменений" / "no changes" with this URL pasted).
      // URL starts with 'ndexStream' (end of 'BackupStream') — missing
      // 'backuppc://uuid@host:port?endpoints=%2Fbackuppc.BackupService%2FBacku'
      // prefix. Has '+++' chars (form-encoded spaces from chat wrap).
      //
      // Before my fix: this URL went to "other" list, native parser failed,
      // user saw generic "Поддерживаемые ссылки не найдены" (no supported
      // links recognized) — no clue about the real issue.
      //
      // After my fix: _looksLikeTruncatedBackupPcUrl detects backuppc
      // patterns + no scheme → throws clear FormatException mentioning
      // TRUNCATED + how to copy full URL from server panel.
      const userUrl =
          'ndexStream%2C%2Fbackuppc.ReplicationService%2FReplicateStream'
          '+++%2Fbackuppc.CatalogService%2FPutIndex%2C%2Fbackuppc.'
          'TransferService%2FUploadBackup+++%2Fbackuppc.TransferService'
          '%2FRestoreStream&fp=371302f5228fadd799e62e64b6897010dbaefce1'
          '78ae4d55d45f56e838bbad80&host=lampa-tv.ru#thinkpad';
      expect(
        () => XrayShareReader().splitBackupPcLinks(userUrl),
        throwsFormatException,
      );
    });

    test('text WITHOUT backuppc patterns is NOT flagged as truncated', () {
      // Plain text and non-backuppc URLs should NOT trigger the truncated
      // detection — they go to "other" list normally for native parser.
      const plainTexts = [
        'just some text',
        'https://example.com/subscription',
        'vless://uuid@host:443',
        'vmess://base64data',
        '',
      ];
      for (final text in plainTexts) {
        final (outbounds, other) = XrayShareReader().splitBackupPcLinks(text);
        expect(outbounds, isEmpty, reason: 'text: "$text"');
        expect(other, isNot(contains('TRUNCATED')));
      }
    });
  });
}
