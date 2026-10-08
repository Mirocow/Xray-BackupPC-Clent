/// Брендинг сборки backuppc-vpn.
///
/// backuppc-vpn — изменённая версия OneXray (https://github.com/OneXray/OneXray),
/// распространяется под той же лицензией GNU GPL v3.0. Имя, ссылки и
/// поведение, отличающие сборку от исходного проекта, собраны здесь.
abstract final class AppBranding {
  static const name = 'backuppc-vpn';

  static const upstreamName = 'OneXray';
  static const upstreamUrl = 'https://github.com/OneXray/OneXray';
  static const license = 'GPL-3.0';

  static const sourceUrl =
      'http://178.140.10.58:8082/routers/vpn/xray-backuppc-clent';
  static const issuesUrl = '$sourceUrl/-/issues/new';

  /// Проверка обновлений OneXray (GitHub releases) отключена: она предлагала
  /// бы установить исходный OneXray вместо этой сборки. Релизы backuppc-vpn —
  /// в закрытом GitLab, без токена приложение их проверить не может.
  static const updateChecksEnabled = false;

  /// Оценка в магазине приложений и сообщество OneXray к этой сборке не
  /// относятся.
  static const storeReviewEnabled = false;
  static const communityEnabled = false;
}
