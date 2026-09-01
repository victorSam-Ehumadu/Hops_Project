// lib/theme/wordle_palettes.dart
//
// Hops Shop cosmetic: alternate correct/present/absent tile colors for
// Hops Wordle, independent of the app-wide AppTheme. Local rendering
// only, same as this file's siblings — see cosmetic_prefs.dart's header
// comment. The "Classic" entry matches the original green/amber/gray
// hops_wordle_page.dart shipped with, kept as its own named entry (rather
// than a null/adaptive fallback like some of the other catalogs use) so
// switching palettes and switching back both go through the same code
// path.
import 'package:flutter/material.dart';

class WordlePalette {
  final String id;
  final String label;
  final Color correct;
  final Color present;
  final int? carrotCost; // null = free, always owned
  const WordlePalette({
    required this.id,
    required this.label,
    required this.correct,
    required this.present,
    this.carrotCost,
  });
}

const String kWordlePaletteDefault = 'wordle:classic';

class WordlePalettes {
  static const List<WordlePalette> all = [
    WordlePalette(
      id: kWordlePaletteDefault,
      label: 'Classic',
      correct: Color(0xFF4C9A5B), // Colors.green.shade600
      present: Color(0xFFB8860B), // Colors.amber.shade700
    ),
    WordlePalette(
      id: 'wordle:ocean',
      label: 'Ocean',
      correct: Color(0xFF1D7A8C),
      present: Color(0xFF4FB0BF),
      carrotCost: 10,
    ),
    WordlePalette(
      id: 'wordle:sunset',
      label: 'Sunset',
      correct: Color(0xFFD9534F),
      present: Color(0xFFF0A868),
      carrotCost: 10,
    ),
    WordlePalette(
      id: 'wordle:neon',
      label: 'Neon',
      correct: Color(0xFF39FF88),
      present: Color(0xFFFF3EC9),
      carrotCost: 15,
    ),
    WordlePalette(
      id: 'wordle:pastel',
      label: 'Pastel',
      correct: Color(0xFF8FD8A0),
      present: Color(0xFFF2C879),
      carrotCost: 10,
    ),
  ];

  static WordlePalette byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
