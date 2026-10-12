/// Брендинг сборки BackupPC VPN.
///
/// BackupPC VPN — изменённая версия OneXray (https://github.com/OneXray/OneXray),
/// распространяется под той же лицензией GNU GPL v3.0. Имя, ссылки и
/// поведение, отличающие сборку от исходного проекта, собраны здесь.
/// Все внешние ссылки приложения ведут на [sourceUrl]; на OneXray — только
/// обязательное указание исходного проекта ([upstreamUrl]).
abstract final class AppBranding {
  static const name = 'BackupPC VPN';

  static const upstreamName = 'OneXray';
  static const upstreamUrl = 'https://github.com/OneXray/OneXray';
  static const license = 'GPL-3.0';

  static const sourceUrl = 'https://github.com/Mirocow/Xray-BackupPC-Clent';
  static const issuesUrl = '$sourceUrl/issues/new';
  static const releasesUrl = '$sourceUrl/releases';
  static const _docs = '$sourceUrl/blob/main/docs/app';
  static const docsUrl = '$_docs/README.md';
  static const routingDocsUrl = '$_docs/routing.md';
  static const creditsUrl = '$_docs/credits.md';
  static const privacyUrl = '$_docs/privacy.md';

  /// Ссылки «поделиться» и импорта: `backuppcvpn://app/config/add?...`.
  /// Своя схема, чтобы не конфликтовать с установленным OneXray.
  static const linkScheme = 'backuppcvpn';
  static const linkHost = 'app';

  /// Проверка обновлений выключена: релизы выходят в GitLab, на GitHub их
  /// пока нет, и проверять приложению нечего.
  static const updateChecksEnabled = false;

  /// Оценка в магазине приложений и сообщество к этой сборке не относятся.
  static const storeReviewEnabled = false;
  static const communityEnabled = false;
}
