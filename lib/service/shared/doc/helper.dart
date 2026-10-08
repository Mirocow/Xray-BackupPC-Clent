import 'package:onexray/core/constants/branding.dart';

/// Документация, благодарности и политика — в репозитории BackupPC VPN.
class DocURLHelper {
  static Uri docUri() => Uri.parse(AppBranding.docsUrl);

  static Uri routingUri() => Uri.parse(AppBranding.routingDocsUrl);

  static Uri creditsUri() => Uri.parse(AppBranding.creditsUrl);

  static Uri privacyUri() => Uri.parse(AppBranding.privacyUrl);
}
