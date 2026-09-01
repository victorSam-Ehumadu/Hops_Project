// lib/theme/chat_bubble_skins.dart
//
// Hops Shop cosmetic: recolors YOUR OWN outgoing chat bubbles in 1:1 chat
// (chat_terminal.dart). Local rendering only, same as this app's other
// customization messages have to convey — you see your own skin on your
// own bubbles in every conversation, but the person you're chatting with
// doesn't see it on their end (their client renders their own copy of the
// conversation independently, same as most chat apps' "bubble color"
// settings already work). See cosmetic_prefs.dart's header comment.
import 'package:flutter/material.dart';

class BubbleSkinOption {
  final String id;
  final String label;
  final Color? bubbleColor; // null = theme default (colors.primary)
  final Color? textColor; // null = theme default (white)
  final int? carrotCost; // null = free, always owned
  const BubbleSkinOption({
    required this.id,
    required this.label,
    this.bubbleColor,
    this.textColor,
    this.carrotCost,
  });
}

const String kBubbleSkinDefault = 'bubble:default';

class BubbleSkinOptions {
  static const List<BubbleSkinOption> all = [
    BubbleSkinOption(id: kBubbleSkinDefault, label: 'Default'),
    BubbleSkinOption(
      id: 'bubble:sunset',
      label: 'Sunset',
      bubbleColor: Color(0xFFFF7E5F),
      textColor: Colors.white,
      carrotCost: 15,
    ),
    BubbleSkinOption(
      id: 'bubble:mint',
      label: 'Mint',
      bubbleColor: Color(0xFF2FBF8F),
      textColor: Colors.white,
      carrotCost: 15,
    ),
    BubbleSkinOption(
      id: 'bubble:royal',
      label: 'Royal',
      bubbleColor: Color(0xFF5B3A9B),
      textColor: Colors.white,
      carrotCost: 15,
    ),
    BubbleSkinOption(
      id: 'bubble:midnight',
      label: 'Midnight',
      bubbleColor: Color(0xFF1B1F3B),
      textColor: Colors.white,
      carrotCost: 20,
    ),
  ];

  static BubbleSkinOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
