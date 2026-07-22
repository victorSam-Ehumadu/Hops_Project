import 'package:flutter/material.dart';

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
  });

  ThemeData toThemeData() {
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
      surfaceContainerHighest: isDark ? surface : surface.withOpacity(0.8),
      error: Colors.red.shade400,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: background,
      colorScheme: colorScheme,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontWeight: FontWeight.w800),
        headlineMedium: TextStyle(fontWeight: FontWeight.bold),
        bodyLarge: TextStyle(fontWeight: FontWeight.w500, height: 1.5),
        labelLarge: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5),
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
    AppTheme(
      name: 'Sunset Glow',
      primary: Color(0xFFFF6F00),
      background: Color(0xFFFFF3E0),
      surface: Color(0xFFFFE0B2),
      onBackground: Color(0xBF360C),
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
  ];
}