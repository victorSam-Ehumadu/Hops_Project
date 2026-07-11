import 'package:flutter/material.dart';

class HopsTheme {
  // Sade's Tonal Color Palette translated to Flutter 0xFF integers[cite: 1]
  static const Color background = Color(0xFFe2fffe);
  static const Color onBackground = Color(0xFF002020);
  static const Color primary = Color(0xFF165c6f);
  static const Color primaryContainer = Color(0xFF367588);
  static const Color onPrimaryContainer = Color(0xFFdaf5ff);
  static const Color surfaceContainerLow = Color(0xFFd7fafa);
  static const Color surfaceContainer = Color(0xFFd2f5f4);
  static const Color surfaceContainerHighest = Color(0xFFc6e9e9);
  static const Color tertiaryContainer = Color(0xFF417676);
  static const Color onTertiaryContainer = Color(0xFFc4fbfa);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.light(
        primary: primary,
        shadow: Colors.transparent,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontWeight: FontWeight.w800, color: primary),
        headlineMedium: TextStyle(fontWeight: FontWeight.bold, color: primary),
        bodyLarge: TextStyle(fontWeight: FontWeight.w500, color: onBackground, height: 1.5),
        labelLarge: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5),
      ),
    );
  }
}