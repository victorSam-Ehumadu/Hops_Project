// The advertisement-name byte budget, and the framing arithmetic each
// feature has to do against it.
//
// This is the exact thing that drifted and broke Vibe Check and Study
// Bunny in the field. Both features set their input field's maxLength to a
// number that looked like the budget but took no account of their own
// framing, so a perfectly ordinary location name produced a name over the
// 26-byte ceiling. The radio rejected the whole advertisement
// asynchronously, the send looked successful, and the report appeared
// locally while never leaving the phone.
//
// Worth pinning because the failure is invisible from this side: nothing
// about an over-long name is detectable without two physical devices, and
// the arithmetic is the one part that IS testable here.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/hops_constants.dart';

void main() {
  group('the ceiling itself', () {
    test('is 26 bytes, the computed legacy-packet limit', () {
      // 31-byte packet, minus the 2-byte AD header for the name, minus the
      // 3-byte TX Power structure Android stacks append unasked. If this
      // number changes, every framing calculation below moves with it and
      // the features that depend on it need re-checking.
      expect(kAdvertisementNameMaxBytes, 26);
    });

    test('accepts a name exactly at the limit and rejects one past it', () {
      expect(advertisementNameFits('a' * 26), isTrue);
      expect(advertisementNameFits('a' * 27), isFalse);
    });
  });

  group('measured in bytes, not characters', () {
    test('a multi-byte character costs more than one', () {
      // 13 two-byte characters = 26 bytes: fits exactly, even though
      // String.length reports only 13. A character-based check would have
      // allowed twice the real budget.
      final accented = 'é' * 13;
      expect(accented.length, 13);
      expect(utf8.encode(accented).length, 26);
      expect(advertisementNameFits(accented), isTrue);
      expect(advertisementNameFits('é' * 14), isFalse);
    });

    test('an emoji is counted at its real cost', () {
      // Four bytes each, so seven of them (28B) must not fit despite
      // String.length being 14 — comfortably under a naive 26 check.
      final emoji = '🐰' * 7;
      expect(advertisementNameFits(emoji), isFalse);
    });
  });

  group('per-feature framing', () {
    test('leaves 20 bytes of text for a Vibe Check report', () {
      // "VBT:" + location + ":" + one level digit = 6 bytes of framing.
      expect(advertisementTextBudget(6), 20);
    });

    test('a location at that budget produces a name that fits', () {
      final name = 'VBT:${'a' * advertisementTextBudget(6)}:2';
      expect(advertisementNameFits(name), isTrue,
          reason: 'the budget must account for this feature’s own framing');
    });

    test('one character more than the budget does NOT fit', () {
      // The regression itself: this is what the old maxLength of 24
      // allowed, and what then failed on the radio.
      final name = 'VBT:${'a' * (advertisementTextBudget(6) + 1)}:2';
      expect(advertisementNameFits(name), isFalse);
    });

    test('leaves 17 bytes of text for a Study Bunny subject', () {
      // "SBF:" + a 4-character id + ":" = 9 bytes of framing.
      expect(advertisementTextBudget(9), 17);
    });

    test('a subject at that budget produces a name that fits', () {
      final name = 'SBF:ab12:${'a' * advertisementTextBudget(9)}';
      expect(advertisementNameFits(name), isTrue);
    });

    test('the old 20-character subject limit did not fit', () {
      // Documents the broken state rather than just the fixed one, so
      // nobody restores the old number thinking it was fine.
      expect(advertisementNameFits('SBF:ab12:${'a' * 20}'), isFalse);
    });

    test('framing larger than the ceiling clamps to zero, not negative', () {
      expect(advertisementTextBudget(kAdvertisementNameMaxBytes + 5), 0);
    });
  });

  test('the idle presence beacon fits with room to spare', () {
    // HPS: + an 8-character rotating token. Sanity check that the format
    // the app spends ~all its time broadcasting is nowhere near the limit.
    expect(advertisementNameFits('HPS:${'a' * 8}'), isTrue);
  });
}
