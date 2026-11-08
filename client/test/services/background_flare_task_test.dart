// The one piece of the background flare listener that can be tested without
// a background isolate, plugins or a radio: which alerts a stand-down
// cancels.
//
// It gets its own test because this exact rule has a history. CLAUDE.md's
// "Concurrent alerts" section records that stand-downs must be scoped to
// their sender with a TRAILING COLON, because matching "EMG:<sender>"
// without one also matches a different user whose truncated tag merely
// starts with this one's — and that the unscoped cancel must never be
// called from a stand-down path, or it silences everyone's alarms.
//
// Sender tags are truncated to 8 characters on the wire, so near-collisions
// are not hypothetical: "vic" and "victor" both fit, and both are plausible
// usernames on one campus.
import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/background_flare_task.dart';

void main() {
  group('flareKeysStoodDownBy', () {
    test('cancels the matching sender', () {
      final active = ['EMG:victor:fire', 'EMG:diya:help'];
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:victor'),
          ['EMG:victor:fire']);
    });

    test('does NOT cancel a sender whose tag merely starts the same', () {
      // The whole reason the trailing colon exists.
      final active = ['EMG:victor:fire', 'EMG:vic:help'];
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:vic'), ['EMG:vic:help'],
          reason: 'Standing down "vic" must not silence "victor". A prefix '
              'match without the trailing colon would take both.');
    });

    test('cancels every alert from one sender, whatever the reason', () {
      // One person can have more than one alert in the registry: alerts are
      // keyed by sender AND reason, so a second flare with a new reason is a
      // separate entry. A stand-down ends all of theirs.
      final active = [
        'EMG:victor:fire',
        'EMG:victor:help me',
        'EMG:diya:lost',
      ];
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:victor'),
          ['EMG:victor:fire', 'EMG:victor:help me']);
    });

    test('a personal stand-down does not silence an Official Alert', () {
      // Different kinds, even from a same-named account. An admin alert is
      // stood down by ADM_OFF: only.
      final active = ['EMG:victor:fire', 'ADM:victor:evacuate'];
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:victor'),
          ['EMG:victor:fire']);
      expect(flareKeysStoodDownBy(active, 'ADM_OFF:victor'),
          ['ADM:victor:evacuate']);
    });

    test('an unknown or malformed advertisement cancels nothing', () {
      final active = ['EMG:victor:fire'];
      // Not a stand-down at all.
      expect(flareKeysStoodDownBy(active, 'HPS:xk3f9a2b'), isEmpty);
      expect(flareKeysStoodDownBy(active, 'EMG:victor:fire'), isEmpty);
      // A stand-down with no sender. Guessing here would mean silencing
      // somebody else's emergency, so it must cancel nothing.
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:'), isEmpty);
      expect(flareKeysStoodDownBy(active, 'EMG_OFF'), isEmpty);
      expect(flareKeysStoodDownBy(active, ''), isEmpty);
    });

    test('an empty registry is fine', () {
      expect(flareKeysStoodDownBy(const [], 'EMG_OFF:victor'), isEmpty);
    });

    test('a REASON containing a colon is still cancelled by its sender', () {
      // The wire format is EMG:<sender>:<reason>. The sender ends at the
      // first colon and cannot contain one (usernames are letters, digits
      // and underscores), but a reason is free text and may well — "Lab
      // 3: fire" is a perfectly ordinary thing to type under pressure.
      //
      // So "EMG:od:d:fire" is sender "od" with reason "d:fire", and od's
      // stand-down must cancel it. Getting this backwards would leave a
      // flare ringing on every nearby phone after the person who raised it
      // had already cancelled, purely because of their punctuation.
      final active = ['EMG:od:d:fire'];
      expect(flareKeysStoodDownBy(active, 'EMG_OFF:od'), ['EMG:od:d:fire']);
    });
  });

  group('a stood-down flare does not immediately re-raise itself', () {
    // The bug this group exists for, reported from two phones on
    // 8 Nov 2026: standing down cancelled the alarm and it came back a
    // moment later, which is indistinguishable from the stand-down never
    // having arrived.
    //
    // Cause: FlutterBluePlus.scanResults accumulates and never drops an
    // entry, so the flare's own EMG: advertisement stays in the list,
    // still inside the freshness window, after the stand-down has been
    // handled. The handler keyed "have I raised this?" on the same map
    // the stand-down empties, so the next emission raised it again.
    final now = DateTime(2026, 11, 8, 20, 7, 50);
    const cooldown = Duration(minutes: 5, seconds: 5);

    test('a flare never heard before is raised', () {
      expect(shouldRaiseFlare(raisedAt: null, now: now, cooldown: cooldown),
          isTrue);
    });

    test('the same flare a moment later is not raised again', () {
      // The exact failure: one second after it was raised and stood down.
      expect(
          shouldRaiseFlare(
              raisedAt: now.subtract(const Duration(seconds: 1)),
              now: now,
              cooldown: cooldown),
          isFalse);
    });

    test('the cooldown outlives the freshness window', () {
      // This is what actually makes the fix work. If a stale advertisement
      // can still be considered fresh after the cooldown lapses, the
      // re-raise comes back exactly as before. 20s of freshness against a
      // 5-minute cooldown is a wide margin; the test guards the ordering,
      // not the specific numbers.
      expect(cooldown, greaterThan(const Duration(seconds: 20) * 2),
          reason: 'A cooldown shorter than the scan freshness window lets '
              'the stale EMG: entry re-raise the alert it just cancelled.');
    });

    test('the same flare much later IS raised again', () {
      // Being stood down must not blacklist a sender forever — a second,
      // genuine emergency from the same person for the same reason has to
      // get through.
      expect(
          shouldRaiseFlare(
              raisedAt: now.subtract(const Duration(minutes: 6)),
              now: now,
              cooldown: cooldown),
          isTrue);
    });

    test('the boundary counts as raisable, not as still-cooling', () {
      expect(
          shouldRaiseFlare(
              raisedAt: now.subtract(cooldown), now: now, cooldown: cooldown),
          isTrue);
    });
  });

  group('handover timings are sane relative to each other', () {
    test('the UI is considered gone only after several missed heartbeats', () {
      expect(kUiConsideredGoneAfter, greaterThan(kUiHeartbeatInterval * 2),
          reason: 'A single missed stamp — a slow frame, a GC pause — must '
              'not hand the radio over while the app is working fine.');
      expect(kUiConsideredGoneAfter.inSeconds, lessThanOrEqualTo(60),
          reason: 'Too long and a closed phone is deaf to a flare for a '
              'minute, which is the window this feature exists to close.');
    });
  });
}
