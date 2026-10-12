import 'package:material_ui/material_ui.dart';
import 'package:onexray/core/db/database/constants.dart';

@immutable
class AppPalette {
  // The confirmation overlay is shared by both prototype themes.
  static const restoreOverlay = Color.fromRGBO(4, 16, 13, 0.4);

  const AppPalette({
    required this.background,
    required this.foreground,
    required this.card,
    required this.cardForeground,
    required this.popover,
    required this.popoverForeground,
    required this.primary,
    required this.primaryHover,
    required this.primarySolid,
    required this.primarySolidHover,
    required this.primaryForeground,
    required this.surfaceHover,
    required this.secondary,
    required this.secondaryForeground,
    required this.muted,
    required this.mutedForeground,
    required this.mutedStrong,
    required this.accent,
    required this.accentForeground,
    required this.destructive,
    required this.destructiveSolid,
    required this.destructiveSolidHover,
    required this.destructiveForeground,
    required this.border,
    required this.borderStrong,
    required this.input,
    required this.ring,
    required this.selection,
    required this.scannerBackground,
    required this.overlay,
    required this.header,
    required this.brand,
    required this.sidebar,
    required this.sidebarForeground,
    required this.sidebarPrimary,
    required this.sidebarPrimaryForeground,
    required this.sidebarAccent,
    required this.sidebarAccentForeground,
    required this.sidebarBorder,
    required this.sidebarRing,
    required this.selectedSurface,
    required this.running,
    required this.runningText,
    required this.runningBadge,
    required this.runningBadgeForeground,
    required this.runningForeground,
    required this.runningSurface,
    required this.restarting,
    required this.restartingText,
    required this.warningSurface,
    required this.destructiveSurface,
    required this.chart1,
    required this.chart2,
    required this.chart3,
    required this.chart4,
    required this.chart5,
  });

  // BackupPC VPN: green tones after the server panel (web/src/styles.css in
  // xray-backuppc). The panel is dark-only; the light theme keeps the same
  // hues with the brand green #0F6E56 for text-level contrast on white.
  static const light = AppPalette(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF13201C),
    card: Color(0xFFFFFFFF),
    cardForeground: Color(0xFF13201C),
    popover: Color(0xFFFFFFFF),
    popoverForeground: Color(0xFF13201C),
    primary: Color(0xFF0F6E56),
    primaryHover: Color(0xFF0B5A46),
    primarySolid: Color(0xFF0F6E56),
    primarySolidHover: Color(0xFF0B5A46),
    primaryForeground: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFFF1F7F5),
    secondary: Color(0xFFFFFFFF),
    secondaryForeground: Color(0xFF13201C),
    muted: Color(0xFFF5F8F7),
    mutedForeground: Color(0xFF5F6B67),
    mutedStrong: Color(0xFF46524E),
    accent: Color(0xFFE5F4EF),
    accentForeground: Color(0xFF0F6E56),
    destructive: Color(0xFFCF2828),
    destructiveSolid: Color(0xFFCF2828),
    destructiveSolidHover: Color(0xFFB82020),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFFD8E2DE),
    borderStrong: Color(0xFFC5D2CD),
    input: Color(0xFFD8E2DE),
    ring: Color(0xFF0F6E56),
    selection: Color(0xFFE5F4EF),
    scannerBackground: Color(0xFF0A1F1A),
    overlay: Color.fromRGBO(6, 20, 16, 0.48),
    header: Color(0xFFFFFFFF),
    brand: Color(0xFF0A4A3A),
    sidebar: Color(0xFFF5F8F7),
    sidebarForeground: Color(0xFF46524E),
    sidebarPrimary: Color(0xFF0F6E56),
    sidebarPrimaryForeground: Color(0xFFFFFFFF),
    sidebarAccent: Color(0xFFE1EFEA),
    sidebarAccentForeground: Color(0xFF0A4A3A),
    sidebarBorder: Color(0xFFD8E2DE),
    sidebarRing: Color(0xFF0F6E56),
    selectedSurface: Color(0xFFE5F4EF),
    running: Color(0xFF1A7F37),
    runningText: Color(0xFF1A7F37),
    runningBadge: Color(0xFF047857),
    runningBadgeForeground: Color(0xFFFFFFFF),
    runningForeground: Color(0xFF10141B),
    runningSurface: Color(0xFFEAF6EE),
    restarting: Color(0xFF9A6500),
    restartingText: Color(0xFF8A5A00),
    warningSurface: Color(0xFFFFF7E6),
    destructiveSurface: Color(0xFFFFF1F1),
    chart1: Color(0xFF1B9C85),
    chart2: Color(0xFF2DA44E),
    chart3: Color(0xFFD98B00),
    chart4: Color(0xFFE54151),
    chart5: Color(0xFF8250DF),
  );

  // Dark: the panel's own tokens (bg #0d1117, accent #39c5a8, green #3fb950).
  static const dark = AppPalette(
    background: Color(0xFF0D1117),
    foreground: Color(0xFFE6EDF3),
    card: Color(0xFF161B22),
    cardForeground: Color(0xFFE6EDF3),
    popover: Color(0xFF1C2129),
    popoverForeground: Color(0xFFE6EDF3),
    primary: Color(0xFF39C5A8),
    primaryHover: Color(0xFF5FD4BB),
    primarySolid: Color(0xFF238263),
    primarySolidHover: Color(0xFF1F6B52),
    primaryForeground: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFF21262D),
    secondary: Color(0xFF0D1117),
    secondaryForeground: Color(0xFFE6EDF3),
    muted: Color(0xFF161B22),
    mutedForeground: Color(0xFF8B949E),
    mutedStrong: Color(0xFFC9D1D9),
    accent: Color(0xFF11302B),
    accentForeground: Color(0xFF39C5A8),
    destructive: Color(0xFFF85149),
    destructiveSolid: Color(0xFFDA3633),
    destructiveSolidHover: Color(0xFFB62324),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFF262D36),
    borderStrong: Color(0xFF364049),
    input: Color(0xFF30363D),
    ring: Color(0xFF39C5A8),
    selection: Color(0xFF11302B),
    scannerBackground: Color(0xFF0A1F1A),
    overlay: Color.fromRGBO(1, 4, 9, 0.6),
    header: Color(0xFF0D1117),
    brand: Color(0xFF5FD4BB),
    sidebar: Color(0xFF010409),
    sidebarForeground: Color(0xFFC9D1D9),
    sidebarPrimary: Color(0xFF39C5A8),
    sidebarPrimaryForeground: Color(0xFF04150F),
    sidebarAccent: Color(0xFF1C2129),
    sidebarAccentForeground: Color(0xFFE6EDF3),
    sidebarBorder: Color(0xFF262D36),
    sidebarRing: Color(0xFF39C5A8),
    selectedSurface: Color(0xFF11302B),
    running: Color(0xFF3FB950),
    runningText: Color(0xFF3FB950),
    runningBadge: Color(0xFF56D364),
    runningBadgeForeground: Color(0xFF04260F),
    runningForeground: Color(0xFF04120A),
    runningSurface: Color(0xFF15361F),
    restarting: Color(0xFFD29922),
    restartingText: Color(0xFFE3B341),
    warningSurface: Color(0xFF352A12),
    destructiveSurface: Color(0xFF3A1D1A),
    chart1: Color(0xFF39C5A8),
    chart2: Color(0xFF3FB950),
    chart3: Color(0xFFD29922),
    chart4: Color(0xFFF85149),
    chart5: Color(0xFFA371F7),
  );

  final Color background;
  final Color foreground;
  final Color card;
  final Color cardForeground;
  final Color popover;
  final Color popoverForeground;
  final Color primary;
  final Color primaryHover;
  final Color primarySolid;
  final Color primarySolidHover;
  // Foregrounds pair with solid fills, not the dark theme's interactive colors.
  final Color primaryForeground;
  final Color surfaceHover;
  final Color secondary;
  final Color secondaryForeground;
  final Color muted;
  final Color mutedForeground;
  final Color mutedStrong;
  final Color accent;
  final Color accentForeground;
  final Color destructive;
  final Color destructiveSolid;
  final Color destructiveSolidHover;
  final Color destructiveForeground;
  final Color border;
  final Color borderStrong;
  final Color input;
  final Color ring;
  final Color selection;
  final Color scannerBackground;
  final Color overlay;
  final Color header;
  final Color sidebar;
  final Color brand;
  final Color sidebarForeground;
  final Color sidebarPrimary;
  final Color sidebarPrimaryForeground;
  final Color sidebarAccent;
  final Color sidebarAccentForeground;
  final Color sidebarBorder;
  final Color sidebarRing;
  final Color selectedSurface;
  final Color running;
  final Color runningText;
  final Color runningBadge;
  final Color runningBadgeForeground;
  final Color runningForeground;
  final Color runningSurface;
  final Color restarting;
  final Color restartingText;
  final Color warningSurface;
  final Color destructiveSurface;
  final Color chart1;
  final Color chart2;
  final Color chart3;
  final Color chart4;
  final Color chart5;

  static AppPalette lerp(AppPalette begin, AppPalette end, double t) {
    Color color(Color a, Color b) => Color.lerp(a, b, t) ?? b;

    return AppPalette(
      background: color(begin.background, end.background),
      foreground: color(begin.foreground, end.foreground),
      card: color(begin.card, end.card),
      cardForeground: color(begin.cardForeground, end.cardForeground),
      popover: color(begin.popover, end.popover),
      popoverForeground: color(begin.popoverForeground, end.popoverForeground),
      primary: color(begin.primary, end.primary),
      primaryHover: color(begin.primaryHover, end.primaryHover),
      primarySolid: color(begin.primarySolid, end.primarySolid),
      primarySolidHover: color(begin.primarySolidHover, end.primarySolidHover),
      primaryForeground: color(begin.primaryForeground, end.primaryForeground),
      surfaceHover: color(begin.surfaceHover, end.surfaceHover),
      secondary: color(begin.secondary, end.secondary),
      secondaryForeground: color(
        begin.secondaryForeground,
        end.secondaryForeground,
      ),
      muted: color(begin.muted, end.muted),
      mutedForeground: color(begin.mutedForeground, end.mutedForeground),
      mutedStrong: color(begin.mutedStrong, end.mutedStrong),
      accent: color(begin.accent, end.accent),
      accentForeground: color(begin.accentForeground, end.accentForeground),
      destructive: color(begin.destructive, end.destructive),
      destructiveSolid: color(begin.destructiveSolid, end.destructiveSolid),
      destructiveSolidHover: color(
        begin.destructiveSolidHover,
        end.destructiveSolidHover,
      ),
      destructiveForeground: color(
        begin.destructiveForeground,
        end.destructiveForeground,
      ),
      border: color(begin.border, end.border),
      borderStrong: color(begin.borderStrong, end.borderStrong),
      input: color(begin.input, end.input),
      ring: color(begin.ring, end.ring),
      selection: color(begin.selection, end.selection),
      scannerBackground: color(begin.scannerBackground, end.scannerBackground),
      overlay: color(begin.overlay, end.overlay),
      header: color(begin.header, end.header),
      sidebar: color(begin.sidebar, end.sidebar),
      brand: color(begin.brand, end.brand),
      sidebarForeground: color(begin.sidebarForeground, end.sidebarForeground),
      sidebarPrimary: color(begin.sidebarPrimary, end.sidebarPrimary),
      sidebarPrimaryForeground: color(
        begin.sidebarPrimaryForeground,
        end.sidebarPrimaryForeground,
      ),
      sidebarAccent: color(begin.sidebarAccent, end.sidebarAccent),
      sidebarAccentForeground: color(
        begin.sidebarAccentForeground,
        end.sidebarAccentForeground,
      ),
      sidebarBorder: color(begin.sidebarBorder, end.sidebarBorder),
      sidebarRing: color(begin.sidebarRing, end.sidebarRing),
      selectedSurface: color(begin.selectedSurface, end.selectedSurface),
      running: color(begin.running, end.running),
      runningText: color(begin.runningText, end.runningText),
      runningBadge: color(begin.runningBadge, end.runningBadge),
      runningBadgeForeground: color(
        begin.runningBadgeForeground,
        end.runningBadgeForeground,
      ),
      runningForeground: color(begin.runningForeground, end.runningForeground),
      runningSurface: color(begin.runningSurface, end.runningSurface),
      restarting: color(begin.restarting, end.restarting),
      restartingText: color(begin.restartingText, end.restartingText),
      warningSurface: color(begin.warningSurface, end.warningSurface),
      destructiveSurface: color(
        begin.destructiveSurface,
        end.destructiveSurface,
      ),
      chart1: color(begin.chart1, end.chart1),
      chart2: color(begin.chart2, end.chart2),
      chart3: color(begin.chart3, end.chart3),
      chart4: color(begin.chart4, end.chart4),
      chart5: color(begin.chart5, end.chart5),
    );
  }
}

class AppColorTokens extends ThemeExtension<AppColorTokens> {
  const AppColorTokens(this.palette);

  static const light = AppColorTokens(AppPalette.light);
  static const dark = AppColorTokens(AppPalette.dark);

  final AppPalette palette;

  Color get surface => palette.card;
  Color get surfaceBorder => palette.border;
  Color get primaryText => palette.foreground;
  Color get secondaryText => palette.mutedForeground;
  Color get tagBackground => palette.muted;
  Color get selectedBackground => palette.selectedSurface;

  static AppColorTokens fallback(Brightness brightness) {
    return brightness == Brightness.light ? light : dark;
  }

  @override
  AppColorTokens copyWith({AppPalette? palette}) {
    return AppColorTokens(palette ?? this.palette);
  }

  @override
  AppColorTokens lerp(ThemeExtension<AppColorTokens>? other, double t) {
    if (other is! AppColorTokens) {
      return this;
    }
    return AppColorTokens(AppPalette.lerp(palette, other.palette, t));
  }
}

class ColorManager {
  static AppColorTokens tokens(BuildContext context) {
    return Theme.of(context).extension<AppColorTokens>() ??
        AppColorTokens.fallback(Theme.of(context).brightness);
  }

  static AppPalette palette(BuildContext context) => tokens(context).palette;

  static Color surface(BuildContext context) => tokens(context).surface;

  static Color primaryText(BuildContext context) => tokens(context).primaryText;

  static Color secondaryText(BuildContext context) {
    return tokens(context).secondaryText;
  }

  static Color nodeLatency(BuildContext context, int delay) {
    final colors = palette(context);
    if (!PingDelayConstants.isSuccessful(delay)) return colors.mutedForeground;
    // These tones remain legible as small text on normal and selected cards.
    return delay <= 500
        ? colors.runningBadge
        : delay <= 1000
        ? colors.restartingText
        : colors.primaryHover;
  }

  static Color tagBackground(BuildContext context) {
    return tokens(context).tagBackground;
  }

  static Color border(BuildContext context) => tokens(context).surfaceBorder;

  static Color selected(BuildContext context) {
    return tokens(context).selectedBackground;
  }
}
