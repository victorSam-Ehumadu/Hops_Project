// Unit tests for lib/services/accessibility_prefs.dart.
//
// These toggles change app *behaviour*, which is what separates this file
// from cosmetic_prefs.dart. Two properties are worth pinning:
//
//   * Everything defaults OFF. Speech is a surprising behaviour, and
//     speakWatchMeAlerts in particular says a contact's name out loud to
//     whoever is within earshot. A default that flipped to on would be a
//     privacy regression that nothing else would catch.
//   * The toggles are independent. speakWatchMeAlerts was deliberately not
//     folded into readMessagesAloud — a Watch Me alert is not a message,
//     and someone who asked for their chats read aloud has not thereby
//     asked for their buddy's movements announced. If a later refactor
//     collapses them onto one key, these tests fail.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/accessibility_prefs.dart';

void main() {
  late AccessibilityPrefs prefs;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    prefs = AccessibilityPrefs.instance;
    prefs.resetForTest();
  });

  group('defaults', () {
    test('every toggle is off on a fresh install', () async {
      await prefs.load();
      expect(prefs.readMessagesAloud.value, isFalse);
      expect(prefs.speakWatchMeAlerts.value, isFalse,
          reason: 'Speaking a contact\'s name aloud must be opt-in.');
      expect(prefs.colorblindMode.value, isFalse);
    });

    test('load() is idempotent and does not clobber a live change', () async {
      await prefs.load();
      await prefs.setSpeakWatchMeAlerts(true);
      await prefs.load(); // the load-once latch should make this a no-op
      expect(prefs.speakWatchMeAlerts.value, isTrue);
    });
  });

  group('persistence', () {
    test('each toggle survives a reload', () async {
      await prefs.load();
      await prefs.setReadMessagesAloud(true);
      await prefs.setSpeakWatchMeAlerts(true);
      await prefs.setColorblindMode(true);

      prefs.resetForTest(); // simulates a fresh process, same stored prefs
      await prefs.load();

      expect(prefs.readMessagesAloud.value, isTrue);
      expect(prefs.speakWatchMeAlerts.value, isTrue);
      expect(prefs.colorblindMode.value, isTrue);
    });

    test('turning a toggle back off persists too', () async {
      await prefs.load();
      await prefs.setSpeakWatchMeAlerts(true);
      await prefs.setSpeakWatchMeAlerts(false);

      prefs.resetForTest();
      await prefs.load();

      expect(prefs.speakWatchMeAlerts.value, isFalse,
          reason: 'A toggle switched off must not come back on after a '
              'restart — a stored `true` with no stored `false` would.');
    });
  });

  group('independence', () {
    test('speech toggles do not share storage', () async {
      await prefs.load();
      await prefs.setReadMessagesAloud(true);

      expect(prefs.speakWatchMeAlerts.value, isFalse,
          reason: 'Asking for chat messages to be read aloud must not also '
              'start announcing Watch Me alerts.');

      prefs.resetForTest();
      await prefs.load();
      expect(prefs.readMessagesAloud.value, isTrue);
      expect(prefs.speakWatchMeAlerts.value, isFalse);
    });

    test('the Watch Me toggle does not affect colourblind mode', () async {
      await prefs.load();
      await prefs.setSpeakWatchMeAlerts(true);
      expect(prefs.colorblindMode.value, isFalse);
    });
  });

  group('notifiers', () {
    test('a change notifies listeners', () async {
      await prefs.load();
      var fired = 0;
      void listener() => fired++;
      prefs.speakWatchMeAlerts.addListener(listener);
      addTearDown(() => prefs.speakWatchMeAlerts.removeListener(listener));

      await prefs.setSpeakWatchMeAlerts(true);
      expect(fired, 1,
          reason: 'The settings switch rebuilds from this notifier, so a '
              'silent write would leave the UI showing the old state.');
    });
  });
}
