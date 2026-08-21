// lib/services/accessibility_prefs.dart
//
// Accessibility toggles — separate from cosmetic_prefs.dart (which is
// purely "how things look, your own choice, no functional effect") because
// these actually change app BEHAVIOR: readMessagesAloud makes incoming 1:1
// chat messages get spoken (see chat_terminal.dart's _handleIncomingMessage),
// colorblindMode swaps Watch Me's proximity colors for a colorblind-safe
// palette (see watch_me_page.dart's _proximityInfo). Text size already has
// its own dedicated control (main.dart's fontScaleNotifier /
// views/font_size_page.dart) — not duplicated here, just linked to from
// accessibility_settings_page.dart so everything accessibility-related is
// discoverable from one place.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccessibilityPrefs {
  AccessibilityPrefs._();
  static final AccessibilityPrefs instance = AccessibilityPrefs._();

  static const _readMessagesAloudKey = 'a11y_read_messages_aloud_v1';
  static const _colorblindModeKey = 'a11y_colorblind_mode_v1';

  final ValueNotifier<bool> readMessagesAloud = ValueNotifier<bool>(false);
  final ValueNotifier<bool> colorblindMode = ValueNotifier<bool>(false);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    readMessagesAloud.value = prefs.getBool(_readMessagesAloudKey) ?? false;
    colorblindMode.value = prefs.getBool(_colorblindModeKey) ?? false;
  }

  Future<void> setReadMessagesAloud(bool value) async {
    readMessagesAloud.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_readMessagesAloudKey, value);
  }

  Future<void> setColorblindMode(bool value) async {
    colorblindMode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_colorblindModeKey, value);
  }
}
