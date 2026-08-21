import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// A headline/body font pairing — the four options here were originally
// prototyped in font_preview_screen.dart (now retired from the real UI in
// favor of this actually-wired picker, see theme_picker_screen.dart).
// `headlineFont`/`bodyFont` mirror GoogleFonts' own function signature
// (`TextStyle Function({TextStyle? textStyle})`) so an existing TextStyle
// (weight, size, color already set elsewhere) can be passed through and
// only have its font family swapped in, rather than replaced wholesale.
class FontPairing {
  final String name;
  final TextStyle Function({TextStyle? textStyle}) headlineFont;
  final TextStyle Function({TextStyle? textStyle}) bodyFont;
  const FontPairing({
    required this.name,
    required this.headlineFont,
    required this.bodyFont,
  });
}

class AppFonts {
  // Not const — GoogleFonts.xyz are themselves functions (tear-offs), not
  // compile-time constants.
  static final List<FontPairing> all = [
    const FontPairing(name: 'Poppins + Nunito', headlineFont: GoogleFonts.poppins, bodyFont: GoogleFonts.nunito),
    const FontPairing(name: 'Montserrat + Inter', headlineFont: GoogleFonts.montserrat, bodyFont: GoogleFonts.inter),
    const FontPairing(name: 'Rubik + Roboto', headlineFont: GoogleFonts.rubik, bodyFont: GoogleFonts.roboto),
    const FontPairing(name: 'Lato + Merriweather', headlineFont: GoogleFonts.lato, bodyFont: GoogleFonts.merriweather),
  ];
}

class AppTheme {
  final String name;
  final Color primary;
  final Color background;
  final Color surface;
  final Color onBackground;
  final Color primaryContainer;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;
  final Brightness brightness;
  // Null = free, always available (every theme above this field was added
  // has this). Non-null = a Hops Shop item — see hops_shop_page.dart and
  // CarrotWallet.owns(name). Gated in color_theme_page.dart's theme grid:
  // locked themes show their cost instead of being selectable, and the
  // Shop is the only place that actually spends carrots to unlock one.
  // Keyed by `name` — themes have no separate id field, and names are
  // already unique/stable across this catalog.
  final int? carrotCost;

  const AppTheme({
    required this.name,
    required this.primary,
    required this.background,
    required this.surface,
    required this.onBackground,
    required this.primaryContainer,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    this.brightness = Brightness.light,
    this.carrotCost,
  });

  // [font] is optional so every existing call site (this app has plenty
  // of raw TextStyle(...) literals scattered across screens rather than
  // Theme.of(context).textTheme references) keeps working unchanged if no
  // font is picked yet. When a font *is* picked, every TextTheme role gets
  // it explicitly — not just the 4 roles this app happens to reference by
  // name — because Flutter's Text widget merges its own style onto
  // whatever DefaultTextStyle the ambient Scaffold/MaterialApp built from
  // the theme, and that base could be resolved from any role depending on
  // context. Leaving roles undefined would mean some raw TextStyle()
  // literals silently keep the system font while others pick up the
  // chosen one, depending on exactly which role Flutter happened to
  // resolve — not a bug worth chasing when defining every role costs
  // nothing.
  ThemeData toThemeData({FontPairing? font}) {
    final isDark = brightness == Brightness.dark;

    // Build a ColorScheme that includes all the roles you use.
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: primaryContainer,
      onPrimaryContainer: isDark ? Colors.black : Colors.white,
      secondary: tertiaryContainer,
      onSecondary: onTertiaryContainer,
      tertiary: tertiaryContainer,
      onTertiary: onTertiaryContainer,
      surface: surface,
      onSurface: onBackground,
      surfaceContainerHighest: isDark ? surface : surface.withValues(alpha: 0.8),
      error: Colors.red.shade400,
      onError: Colors.white,
    );

    const baseTextTheme = TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w800),
      headlineMedium: TextStyle(fontWeight: FontWeight.bold),
      bodyLarge: TextStyle(fontWeight: FontWeight.w500, height: 1.5),
      labelLarge: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5),
    );

    final textTheme = font == null
        ? baseTextTheme
        : TextTheme(
            displayLarge: font.headlineFont(textStyle: baseTextTheme.displayLarge),
            displayMedium: font.headlineFont(textStyle: baseTextTheme.displayMedium),
            displaySmall: font.headlineFont(textStyle: baseTextTheme.displaySmall),
            headlineLarge: font.headlineFont(textStyle: baseTextTheme.headlineLarge),
            headlineMedium: font.headlineFont(textStyle: baseTextTheme.headlineMedium),
            headlineSmall: font.headlineFont(textStyle: baseTextTheme.headlineSmall),
            titleLarge: font.headlineFont(textStyle: baseTextTheme.titleLarge),
            titleMedium: font.headlineFont(textStyle: baseTextTheme.titleMedium),
            titleSmall: font.headlineFont(textStyle: baseTextTheme.titleSmall),
            bodyLarge: font.bodyFont(textStyle: baseTextTheme.bodyLarge),
            bodyMedium: font.bodyFont(textStyle: baseTextTheme.bodyMedium),
            bodySmall: font.bodyFont(textStyle: baseTextTheme.bodySmall),
            labelLarge: font.bodyFont(textStyle: baseTextTheme.labelLarge),
            labelMedium: font.bodyFont(textStyle: baseTextTheme.labelMedium),
            labelSmall: font.bodyFont(textStyle: baseTextTheme.labelSmall),
          );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: background,
      colorScheme: colorScheme,
      textTheme: textTheme,
      // Elevated Soft UI defaults — bigger consistent radii and real
      // (if gentle) elevation instead of the flat opacity-tinted
      // rectangles this app used to hand-roll slightly differently on
      // every screen. Widgets that explicitly override shape/color still
      // can (HopsCard draws its own two-layer shadow rather than relying
      // on this), but anything left at its Material default now gets the
      // same consistent look for free.
      cardTheme: CardThemeData(
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        // A small default rather than zero — plenty of Card(...) call
        // sites across the app rely on Material's own margin for basic
        // breathing room between list items rather than wrapping
        // themselves in an explicit margin, and zero would have made
        // those touch edge-to-edge with no warning.
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: (textTheme.headlineMedium ?? const TextStyle())
            .copyWith(fontSize: 20, fontWeight: FontWeight.bold, color: primary),
        iconTheme: IconThemeData(color: primary),
      ),
    );
  }
}

class AppThemes {
  static const List<AppTheme> all = [
    // 1 – Hops Default
    AppTheme(
      name: 'Hops Default',
      primary: Color(0xFF165c6f),
      background: Color(0xFFe2fffe),
      surface: Color(0xFFd2f5f4),
      onBackground: Color(0xFF002020),
      primaryContainer: Color(0xFF367588),
      tertiaryContainer: Color(0xFF417676),
      onTertiaryContainer: Color(0xFFc4fbfa),
    ),
    // 2 – Ocean Breeze
    AppTheme(
      name: 'Ocean Breeze',
      primary: Color(0xFF0D47A1),
      background: Color(0xFFE3F2FD),
      surface: Color(0xFFBBDEFB),
      onBackground: Color(0xFF0D47A1),
      primaryContainer: Color(0xFF5472D3),
      tertiaryContainer: Color(0xFF1976D2),
      onTertiaryContainer: Colors.white,
    ),
    // 3 – Sunset Glow
    // Was disabled with onBackground: Color(0xBF360C) — only 6 hex digits,
    // so Dart's Color(int) read that as 0x00BF360C: alpha byte 0x00, i.e.
    // fully transparent text. Every word on this theme would have
    // rendered invisible; re-enabled with the missing FF alpha prefix
    // restored (was very likely meant to be Material's Deep Orange 900).
    AppTheme(
      name: 'Sunset Glow',
      primary: Color(0xFFFF6F00),
      background: Color(0xFFFFF3E0),
      surface: Color(0xFFFFE0B2),
      onBackground: Color(0xFFBF360C),
      primaryContainer: Color(0xFFFFB74D),
      tertiaryContainer: Color(0xFFE65100),
      onTertiaryContainer: Colors.white,
    ),
    // 4 – Forest Calm
    AppTheme(
      name: 'Forest Calm',
      primary: Color(0xFF2E7D32),
      background: Color(0xFFE8F5E9),
      surface: Color(0xFFC8E6C9),
      onBackground: Color(0xFF1B5E20),
      primaryContainer: Color(0xFF81C784),
      tertiaryContainer: Color(0xFF388E3C),
      onTertiaryContainer: Colors.white,
    ),
    // 5 – Neon Vibes
    AppTheme(
      name: 'Neon Vibes',
      primary: Color(0xFF8E24AA),
      background: Color(0xFFF3E5F5),
      surface: Color(0xFFE1BEE7),
      onBackground: Color(0xFF4A148C),
      primaryContainer: Color(0xFFBA68C8),
      tertiaryContainer: Color(0xFF6A1B9A),
      onTertiaryContainer: Color(0xFFFFAB91),
    ),
    // 6 – Minimalist
    AppTheme(
      name: 'Minimalist',
      primary: Color(0xFF455A64),
      background: Color(0xFFECEFF1),
      surface: Color(0xFFCFD8DC),
      onBackground: Color(0xFF263238),
      primaryContainer: Color(0xFF78909C),
      tertiaryContainer: Color(0xFF546E7A),
      onTertiaryContainer: Colors.white,
    ),
    // 7 – Midnight (Dark)
    AppTheme(
      name: 'Midnight',
      primary: Color(0xFFBB86FC),
      background: Color(0xFF121212),
      surface: Color(0xFF1E1E1E),
      onBackground: Color(0xFFE0E0E0),
      primaryContainer: Color(0xFF3700B3),
      tertiaryContainer: Color(0xFF03DAC6),
      onTertiaryContainer: Color(0xFF000000),
      brightness: Brightness.dark,
    ),
    // 8 – Ocean Depths (Dark) — dark counterpart to Ocean Breeze
    AppTheme(
      name: 'Ocean Depths',
      primary: Color(0xFF64B5F6),
      background: Color(0xFF0A1929),
      surface: Color(0xFF132F4C),
      onBackground: Color(0xFFE3F2FD),
      primaryContainer: Color(0xFF1565C0),
      tertiaryContainer: Color(0xFF29B6F6),
      onTertiaryContainer: Color(0xFF001E3C),
      brightness: Brightness.dark,
    ),
    // 9 – Forest Night (Dark) — dark counterpart to Forest Calm
    AppTheme(
      name: 'Forest Night',
      primary: Color(0xFF81C784),
      background: Color(0xFF0D1F0F),
      surface: Color(0xFF16281A),
      onBackground: Color(0xFFE8F5E9),
      primaryContainer: Color(0xFF2E7D32),
      tertiaryContainer: Color(0xFF66BB6A),
      onTertiaryContainer: Color(0xFF002204),
      brightness: Brightness.dark,
    ),
    // 10 – Rose Dusk (Dark) — a hue nothing else in this list covers
    AppTheme(
      name: 'Rose Dusk',
      primary: Color(0xFFF48FB1),
      background: Color(0xFF1A0E14),
      surface: Color(0xFF2A1620),
      onBackground: Color(0xFFFCE4EC),
      primaryContainer: Color(0xFFAD1457),
      tertiaryContainer: Color(0xFFEC407A),
      onTertiaryContainer: Color(0xFF3E0018),
      brightness: Brightness.dark,
    ),
    // 11 – Sunset Ember (Dark) — dark counterpart to Sunset Glow
    AppTheme(
      name: 'Sunset Ember',
      primary: Color(0xFFFFB74D),
      background: Color(0xFF1F1209),
      surface: Color(0xFF2E1C0F),
      onBackground: Color(0xFFFFF3E0),
      primaryContainer: Color(0xFFE65100),
      tertiaryContainer: Color(0xFFFF8A65),
      onTertiaryContainer: Color(0xFF3E1400),
      brightness: Brightness.dark,
    ),
    // 12 – Slate Night (Dark) — dark counterpart to Minimalist, a cool
    // neutral grey-blue for anyone who wants dark mode without a strong
    // accent color dominating the whole app.
    AppTheme(
      name: 'Slate Night',
      primary: Color(0xFF90A4AE),
      background: Color(0xFF10151A),
      surface: Color(0xFF1C242B),
      onBackground: Color(0xFFECEFF1),
      primaryContainer: Color(0xFF455A64),
      tertiaryContainer: Color(0xFF78909C),
      onTertiaryContainer: Color(0xFF0B0F12),
      brightness: Brightness.dark,
    ),
    // ── Hops Shop exclusives ─────────────────────────────────────────────
    // Appended at the end, not mixed into the free catalog above — every
    // existing index (0-11) has to stay pointing at the same theme, since
    // themeNotifier and admin_settings_screen.dart's defaultLightIndex/
    // defaultDarkIndex both persist/reference themes BY INDEX. Inserting a
    // new theme in the middle would silently reassign everyone's saved
    // selection to a different theme on next launch.
    // 13 – Golden Carrot (Light) — the "you paid for this" shine
    AppTheme(
      name: 'Golden Carrot',
      primary: Color(0xFFB8860B),
      background: Color(0xFFFFF8E1),
      surface: Color(0xFFFFECB3),
      onBackground: Color(0xFF4A3200),
      primaryContainer: Color(0xFFFFC107),
      tertiaryContainer: Color(0xFFFF8F00),
      onTertiaryContainer: Colors.white,
      carrotCost: 40,
    ),
    // 14 – Cotton Candy (Light)
    AppTheme(
      name: 'Cotton Candy',
      primary: Color(0xFFD81B8A),
      background: Color(0xFFFFF0F8),
      surface: Color(0xFFFFD6EC),
      onBackground: Color(0xFF5C0038),
      primaryContainer: Color(0xFFFF80C0),
      tertiaryContainer: Color(0xFF7C4DFF),
      onTertiaryContainer: Colors.white,
      carrotCost: 25,
    ),
    // 15 – Obsidian (Dark) — near-black with a single sharp accent
    AppTheme(
      name: 'Obsidian',
      primary: Color(0xFF00E5FF),
      background: Color(0xFF000000),
      surface: Color(0xFF0D0D0D),
      onBackground: Color(0xFFE0F7FA),
      primaryContainer: Color(0xFF00838F),
      tertiaryContainer: Color(0xFF00ACC1),
      onTertiaryContainer: Colors.black,
      brightness: Brightness.dark,
      carrotCost: 25,
    ),
    // 16 – Royal Amethyst (Dark)
    AppTheme(
      name: 'Royal Amethyst',
      primary: Color(0xFFCE93D8),
      background: Color(0xFF150A1F),
      surface: Color(0xFF241333),
      onBackground: Color(0xFFF3E5F5),
      primaryContainer: Color(0xFF6A1B9A),
      tertiaryContainer: Color(0xFFAB47BC),
      onTertiaryContainer: Colors.white,
      brightness: Brightness.dark,
      carrotCost: 40,
    ),
  ];

  // ── Plain dark-mode switching ─────────────────────────────────────────
  //
  // The catalog above is a flat list a user picks from by name, which is
  // fine for "make it look nice" but has no answer for "just turn dark
  // mode on". These give a simple switch something to aim at.
  //
  // No light↔dark pairing table on purpose: the themes are named by
  // feeling rather than paired one-to-one (Sunset Glow's counterpart is
  // Sunset Ember, five entries later, while Neon Vibes has no obvious
  // twin), so any arithmetic mapping would be wrong for some of them.
  // Callers remember the last index used at each brightness instead — see
  // admin_settings_screen.dart's _setDarkMode.

  /// Hops Default.
  static const int defaultLightIndex = 0;

  /// Midnight.
  static const int defaultDarkIndex = 6;

  static bool isDark(int index) =>
      index >= 0 && index < all.length && all[index].brightness == Brightness.dark;
}