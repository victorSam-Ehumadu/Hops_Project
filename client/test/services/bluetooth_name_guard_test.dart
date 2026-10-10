// Unit tests for the payload-name detector
// (lib/services/bluetooth_name_guard.dart).
//
// The detector is what stops a protocol string being mistaken for the
// user's own Bluetooth name and saved as the value to restore to. If a
// prefix goes missing from the list, the failure is silent and permanent:
// the phone keeps that string as its name and every device nearby shows
// it, including in paired-device lists.

import 'package:flutter_test/flutter_test.dart';
import 'package:client/services/bluetooth_name_guard.dart';

void main() {
  group('looksLikeHopsAdvertisementName', () {
    test('recognises every prefix the app broadcasts', () {
      for (final prefix in kHopsAdvertisementPrefixes) {
        expect(looksLikeHopsAdvertisementName('${prefix}payload'), isTrue,
            reason: '"$prefix" must be recognised as a Hops payload');
      }
    });

    test('recognises the payloads a user would actually see', () {
      // The report from the field was a chat ping appearing in Bluetooth
      // settings on someone else's phone.
      expect(looksLikeHopsAdvertisementName('CHT:diya:Test2'), isTrue);
      expect(looksLikeHopsAdvertisementName('HPS:xk3f9a2b'), isTrue);
      expect(looksLikeHopsAdvertisementName('EMG:victor:unsafe'), isTrue);
      expect(looksLikeHopsAdvertisementName('EMG_OFF:victor'), isTrue);
      expect(looksLikeHopsAdvertisementName('CM:victor__aBhello'), isTrue);
      expect(looksLikeHopsAdvertisementName('VBT:Library:3'), isTrue);
    });

    test('leaves ordinary device names alone', () {
      // These must be storable as the name to restore to.
      for (final name in const [
        "Victor's Galaxy S21",
        'Pixel 7',
        'iPhone',
        'Redmi Note 12',
        'Diya',
        'Test2',
        'Galaxy Buds Pro',
      ]) {
        expect(looksLikeHopsAdvertisementName(name), isFalse,
            reason: '"$name" is a real device name and must be preserved');
      }
    });

    test('is not fooled by a prefix appearing later in the name', () {
      // Only a name that STARTS with a prefix is a payload. A phone
      // legitimately called "Sam's CHT: rig" is not one.
      expect(looksLikeHopsAdvertisementName("Sam's CHT: rig"), isFalse);
      expect(looksLikeHopsAdvertisementName('my HPS: device'), isFalse);
    });

    test('tolerates surrounding whitespace', () {
      expect(looksLikeHopsAdvertisementName('  CHT:diya:Test2  '), isTrue);
    });

    test('treats an empty or blank name as not a payload', () {
      // Nothing to restore from, but it must not be classified as a
      // payload either - that would be a name worth keeping if the
      // adapter ever reported one.
      expect(looksLikeHopsAdvertisementName(''), isFalse);
      expect(looksLikeHopsAdvertisementName('   '), isFalse);
    });

    test('the prefix list has no duplicates and no empty entries', () {
      expect(kHopsAdvertisementPrefixes.toSet().length,
          kHopsAdvertisementPrefixes.length);
      expect(kHopsAdvertisementPrefixes.any((p) => p.isEmpty), isFalse);
    });

    test('covers every prefix hops_app.dart dispatches on', () {
      // Kept in step with the prefix-dispatch chain in
      // _HopsAppState's scan handler. A prefix added there and forgotten
      // here is exactly the silent failure this file exists to catch.
      const dispatched = <String>[
        'HPS:', 'EMG:', 'EMG_OFF:', 'ADM:', 'ADM_OFF:',
        'FR:', 'FA:', 'WR:', 'WA:', 'ACK:', 'HOP:', 'CHT:',
        'VBT:', 'VBX:', 'LNR:',
        'SBF:', 'SBI:', 'SBC:', 'SBX:',
        'CM:', 'CA:', 'CX:', 'DM:', 'LNF:',
      ];
      for (final prefix in dispatched) {
        expect(kHopsAdvertisementPrefixes, contains(prefix),
            reason: '"$prefix" is broadcast but not recognised as one of ours');
      }
    });
  });
}
