// lib/services/accessibility_prefs.dart
//
// Accessibility toggles — separate from cosmetic_prefs.dart (which is
// purely "how things look, your own choice, no functional effect") because
// these actually change app BEHAVIOR: readMessagesAloud makes incoming 1:1
// chat messages get spoken (see chat_terminal.dart's _handleIncomingMessage),
// speakWatchMeAlerts does the same for Watch Me's status changes (see
// watch_me_page.dart's _triggerAlert/_announce), colorblindMode swaps Watch
// Me's proximity colors for a colorblind-safe palette (see
// watch_me_page.dart's _proximityInfo). Text size already has
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
  static const _speakWatchMeAlertsKey = 'a11y_speak_watch_me_alerts_v1';
  static const _colorblindModeKey = 'a11y_colorblind_mode_v1';

  final ValueNotifier<bool> readMessagesAloud = ValueNotifier<bool>(false);

  /// Speak Watch Me status changes aloud.
  ///
  /// Deliberately NOT folded into [readMessagesAloud]: a Watch Me alert is
  /// not a message, and someone who wants their chats read has not thereby
  /// asked for their buddy's name announced out loud. The whole point of
  /// Watch Me is walking somewhere alone, which is exactly when looking at
  /// the screen is the thing you don't want to do — so this is the one
  /// place speech genuinely beats a glance.
  ///
  /// Off by default. Speech is a surprising behaviour, and this one says a
  /// contact's name aloud to whoever is within earshot.
  final ValueNotifier<bool> speakWatchMeAlerts = ValueNotifier<bool>(false);

  final ValueNotifier<bool> colorblindMode = ValueNotifier<bool>(false);

  bool _loaded = false;

  /// Clears the load-once latch and the in-memory values.
  ///
  /// This is a singleton, so without it every test after the first
  /// inherits the previous one's toggles and `load()` returns immediately
  /// — making results depend on test order. Resets in-memory state only;
  /// the caller is expected to have reset SharedPreferences too.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    readMessagesAloud.value = false;
    speakWatchMeAlerts.value = false;
    colorblindMode.value = false;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    readMessagesAloud.value = prefs.getBool(_readMessagesAloudKey) ?? false;
    speakWatchMeAlerts.value = prefs.getBool(_speakWatchMeAlertsKey) ?? false;
    colorblindMode.value = prefs.getBool(_colorblindModeKey) ?? false;
  }

  Future<void> setReadMessagesAloud(bool value) async {
    readMessagesAloud.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_readMessagesAloudKey, value);
  }

  Future<void> setSpeakWatchMeAlerts(bool value) async {
    speakWatchMeAlerts.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_speakWatchMeAlertsKey, value);
  }

  Future<void> setColorblindMode(bool value) async {
    colorblindMode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_colorblindModeKey, value);
  }
}
