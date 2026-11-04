// The "WX:" advertisement that ends a watch, and why it is one prefix.
//
// Watch Me is requested by the person who wants watching: they send
// "WR:<them>:<me>", the recipient accepts and becomes the watcher. Only
// the watcher used to hold state, so only the watcher could stop it —
// consent could be given but not withdrawn, which is backwards for a
// feature that shares where you are.
//
// "WX:<other>:<me>" ends it from EITHER side. These tests pin the two
// things that would break it silently: the name has to fit the radio, and
// the guard has to recognise it as a payload rather than as somebody's
// real Bluetooth name.

import 'dart:convert';

import 'package:client/services/bluetooth_name_guard.dart';
import 'package:client/services/hops_constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors hops_app.dart's _adUser.
String adUser(String username) =>
    username.length > 9 ? username.substring(0, 9) : username;

void main() {
  group('the watch-cancel advertisement', () {
    test('fits even with two maximum-length usernames', () {
      // 3 + 9 + 1 + 9 = 22, the same shape WR:/WA: already use.
      final name = 'WX:${adUser('averylongusername')}:${adUser('anotherlongone')}';
      expect(utf8.encode(name).length, 22);
      expect(advertisementNameFits(name), isTrue);
    });

    test('is recognised as a Hops payload, not a phone name', () {
      // The advertised name IS the device's Bluetooth name while it is on
      // the air. Without this the guard would record "WX:bob:alice" as the
      // user's real adapter name and restore it forever after.
      expect(looksLikeHopsAdvertisementName('WX:bob:alice'), isTrue);
    });

    test('the guard knows every watch prefix', () {
      for (final p in ['WR:', 'WA:', 'WX:']) {
        expect(looksLikeHopsAdvertisementName('${p}bob:alice'), isTrue,
            reason: '$p missing from kHopsAdvertisementPrefixes');
      }
    });

    test('a real phone name is still left alone', () {
      for (final name in ["Victor's Phone", 'Galaxy A52', 'WX Pro']) {
        expect(looksLikeHopsAdvertisementName(name), isFalse,
            reason: '"$name" must not be mistaken for a payload');
      }
    });

    test('addressing is by recipient first, like WR: and WA:', () {
      // The receiver checks parts[0] against its own truncated username,
      // so the order matters: "WX:<other>:<me>" means "other, this is me,
      // the watch is off".
      const me = 'alice';
      const other = 'bob';
      final name = 'WX:${adUser(other)}:${adUser(me)}';
      final parts = name.substring(3).split(':');
      expect(parts.first, adUser(other));
      expect(parts.last, adUser(me));
    });
  });
}
