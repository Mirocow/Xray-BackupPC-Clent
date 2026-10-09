import 'package:flutter/foundation.dart';
import 'package:backuppc_dart/backuppc_dart.dart' show BackupPcLink;
import 'package:onexray/core/db/database/database.dart';
import 'package:onexray/core/pigeon/host_api.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/servers/outbound/map.dart';
import 'package:onexray/service/servers/outbound/state_db.dart';

class XrayShareReader {
  Future<List<CoreConfigCompanion>> parseShareText(
    String text, {
    String? ageSecretKey,
  }) async {
    // backuppc:// парсится чистым Dart (нативный конвертер его не знает).
    final (backuppcOutbounds, nativeText) = splitBackupPcLinks(text);
    final outbounds = <Map<String, dynamic>>[...backuppcOutbounds];
    if (nativeText.trim().isNotEmpty) {
      outbounds.addAll(
        await AppHostApi().convertShareLinksToXrayJson(
          nativeText,
          ageSecretKey: ageSecretKey,
        ),
      );
    }
    return readXrayJsonOutbounds({'outbounds': outbounds});
  }

  /// Разделяет ввод: строки `backuppc://` → outbound-ы, остальное —
  /// нативному конвертеру. Некорректная backuppc-ссылка — ошибка ввода
  /// (нативный конвертер так же поступает с битыми vless/vmess).
  ///
  /// Sanitization перед парсингом:
  /// 1. JOIN wrapped URL fragments. Long backuppc:// URLs (2000+ chars
  ///    из-за 38 default endpoint paths) часто копируются из чата/email
  ///    где они wrap'ятся на новые строки. split('\n') разбивает URL
  ///    на фрагменты. Мы detect continuation lines (don't start with a
  ///    URL scheme) и JOIN их к предыдущей строке.
  /// 2. Strip whitespace из joined URL (handles spaces, tabs).
  /// 3. Replace `+` chars in query string на `%20` (form-encoded space).
  ///    Некоторые clipboard managers / chat clients кодируют пробелы как `+`.
  ///    Uri.parse декодирует `%20` в пробел, но `+` в query Uri.parse НЕ
  ///    декодирует (только form-urlencoded context). Это приводит к `+`
  ///    в значениях параметров, что ломает startsWith('/') проверку для
  ///    endpoints.
  /// 4. Show clear error if URL is malformed after sanitization.
  /// 5. DETECT TRUNCATED backuppc URLs: if input contains backuppc-related
  ///    patterns (backuppc.ReplicationService, endpoints=, fp=, host=)
  ///    but doesn't start with backuppc:// scheme, throw a clear error
  ///    explaining the URL is truncated.
  @visibleForTesting
  (List<Map<String, dynamic>>, String) splitBackupPcLinks(String text) {
    final backuppcOutbounds = <Map<String, dynamic>>[];
    final other = <String>[];
    // First pass: join continuation lines (lines that don't start with a
    // URL scheme) to the previous line. This handles URLs that were wrapped
    // across multiple lines when copied from chat/email.
    final logicalLines = _joinContinuationLines(text);
    for (final line in logicalLines) {
      final trimmed = line.trim();
      final scheme = trimmed.isEmpty
          ? ''
          : Uri.tryParse(trimmed)?.scheme.toLowerCase() ?? '';
      if (scheme == 'backuppc') {
        final sanitized = _sanitizeBackupPcUrl(trimmed);
        final link = BackupPcLink.tryParse(sanitized);
        if (link == null) {
          throw FormatException(
            'Invalid backuppc link after sanitization. '
            'URL must start with "backuppc://" and contain uuid@host:port. '
            'Got: "${sanitized.length > 80 ? "${sanitized.substring(0, 80)}..." : sanitized}"',
          );
        }
        backuppcOutbounds.add(link.toOutboundJson());
      } else if (_looksLikeTruncatedBackupPcUrl(trimmed)) {
        // URL contains backuppc-related patterns but doesn't start with
        // backuppc:// — likely truncated when copied from chat/email.
        // Throw a clear error explaining the issue.
        throw FormatException(
          'Pasted text contains backuppc share-link fragments (endpoints=, '
          'fp=, backuppc.ReplicationService, etc.) but doesn\'t start with '
          '"backuppc://" scheme. The URL appears to be TRUNCATED — the '
          'beginning is missing. Please copy the FULL URL from the server '
          'panel (Clients page → ⧉ copy button), not from chat/email that '
          'may wrap or truncate long URLs.',
        );
      } else {
        other.add(line);
      }
    }
    return (backuppcOutbounds, other.join('\n'));
  }

  /// Detects if input looks like a TRUNCATED backuppc:// share-link.
  /// Returns true if input contains backuppc-related patterns (endpoint
  /// paths, query params) but doesn't have a URL scheme.
  ///
  /// Patterns checked (case-insensitive):
  /// - Query params: `endpoints=`, `fp=`, `host=`, `insecure=`, `pad=`, `ua=`
  /// - Endpoint service names: `backuppc.BackupService`,
  ///   `backuppc.ChunkService`, `backuppc.StorageService`,
  ///   `backuppc.SnapshotService`, `backuppc.RsyncService`,
  ///   `backuppc.ArchiveService`, `backuppc.DedupService`,
  ///   `backuppc.ReplicationService`, `backuppc.CatalogService`,
  ///   `backuppc.TransferService`
  /// - URL-encoded path chars: `%2Fbackuppc.` (slash + backuppc prefix)
  ///
  /// Returns false for normal text, valid URLs with schemes, etc.
  static bool _looksLikeTruncatedBackupPcUrl(String input) {
    if (input.isEmpty) return false;
    // If input has a URL scheme (anything before `://`), it's not truncated.
    if (input.contains('://')) return false;
    final lower = input.toLowerCase();
    // Check for backuppc share-link query params.
    final hasBackupPcParams = lower.contains('endpoints=') ||
        lower.contains('fp=') ||
        lower.contains('&host=') ||
        lower.contains('?host=') ||
        lower.contains('insecure=') ||
        lower.contains('pad=') ||
        lower.contains('&ua=') ||
        lower.contains('?ua=');
    // Check for backuppc endpoint service names.
    final hasBackupPcServices = lower.contains('backuppc.') &&
        (lower.contains('backupservice') ||
            lower.contains('chunkservice') ||
            lower.contains('storageservice') ||
            lower.contains('snapshotservice') ||
            lower.contains('rsyncservice') ||
            lower.contains('archiveservice') ||
            lower.contains('dedupservice') ||
            lower.contains('replicationservice') ||
            lower.contains('catalogservice') ||
            lower.contains('transferservice'));
    // Check for URL-encoded backuppc paths.
    final hasEncodedBackupPc = lower.contains('%2fbackuppc.');
    return hasBackupPcParams || hasBackupPcServices || hasEncodedBackupPc;
  }

  /// Joins continuation lines: if a line doesn't start with a URL scheme
  /// (e.g. "backuppc://", "vless://", "https://") AND the previous line
  /// does, join it to the previous line. This handles URLs that were
  /// wrapped across multiple lines by chat/email clients.
  ///
  /// Example input:
  ///   backuppc://uuid@host:8443?endpoints=%2Fbackuppc.BackupService%2FBackupStream
  ///      %2C%2Fbackuppc.ChunkService%2FPutChunk
  ///      &fp=...
  ///      #tag
  ///   vless://other-uuid@other-host:443
  ///
  /// Output:
  ///   [
  ///     "backuppc://uuid@host:8443?endpoints=...%2C%2Fbackuppc...&fp=...#tag",
  ///     "vless://other-uuid@other-host:443",
  ///   ]
  static List<String> _joinContinuationLines(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        // Empty line breaks continuation — don't join.
        out.add(line);
        continue;
      }
      final scheme = Uri.tryParse(trimmed)?.scheme.toLowerCase() ?? '';
      final startsWithScheme = scheme.isNotEmpty &&
          (trimmed.contains('://') || scheme == 'backuppcvpn');
      if (startsWithScheme) {
        // New URL starts here.
        out.add(line);
      } else if (out.isNotEmpty) {
        // Continuation line — join to previous line (no separator, since
        // URL fragments shouldn't have spaces between them).
        final prevIndex = out.length - 1;
        out[prevIndex] = out[prevIndex] + trimmed;
      } else {
        // No previous URL to continue — line is standalone.
        out.add(line);
      }
    }
    return out;
  }

  /// Sanitize backuppc:// URL before parsing:
  /// - Strip ALL whitespace (spaces, tabs) — handles URLs that had
  ///   continuation lines joined (might have embedded spaces from
  ///   leading indentation).
  /// - Replace `+` chars in query with `%20` (some chat clients encode
  ///   spaces as `+` instead of `%20`).
  static String _sanitizeBackupPcUrl(String url) {
    // Fast path: if no whitespace and no `+`, return as-is.
    if (!url.contains(RegExp(r'\s')) && !url.contains('+')) {
      return url;
    }
    // Find where the query starts (after first '?') and fragment ('#').
    final queryStart = url.indexOf('?');
    final fragmentStart = url.indexOf('#');
    final prefixEnd = queryStart >= 0
        ? queryStart
        : (fragmentStart >= 0 ? fragmentStart : url.length);
    final prefix = url.substring(0, prefixEnd).replaceAll(RegExp(r'\s'), '');
    var query = '';
    var fragment = '';
    if (queryStart >= 0) {
      final queryEnd = fragmentStart >= 0 && fragmentStart > queryStart
          ? fragmentStart
          : url.length;
      query = url.substring(queryStart, queryEnd);
      // Replace `+` with `%20` in query string (form-encoded space).
      query = query.replaceAll('+', '%20');
      // Strip whitespace from query.
      query = query.replaceAll(RegExp(r'\s'), '');
    }
    if (fragmentStart >= 0) {
      fragment = url.substring(fragmentStart).replaceAll(RegExp(r'\s'), '');
    }
    return '$prefix$query$fragment';
  }

  @visibleForTesting
  Future<List<CoreConfigCompanion>> readXrayJsonOutbounds(
    Map<String, dynamic> xrayJson,
  ) async {
    final res = <CoreConfigCompanion>[];
    final outbounds = xrayJson['outbounds'];
    if (outbounds is! List<dynamic>) {
      return res;
    }

    for (var index = 0; index < outbounds.length; index++) {
      if (index > 0 && index % 64 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final value = outbounds[index];
      if (value is! Map<String, dynamic>) {
        continue;
      }
      final outbound = copyOutboundMap(value);
      try {
        res.add(outboundCompanion(outbound));
      } catch (error, stackTrace) {
        ygLogger(
          "Failed to read imported outbound (${error.runtimeType})\n$stackTrace",
        );
      }
    }
    return res;
  }
}
