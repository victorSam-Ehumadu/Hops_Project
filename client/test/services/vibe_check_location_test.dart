// Vibe Check's venue list, and the one constraint it has to satisfy.
//
// Unlike kStudyLocations — where the location travels as a one-byte INDEX
// and the list's order IS the wire format — a Vibe Check location travels
// as plain TEXT inside "VBT:<location>:<level>". That makes the list free
// to reorder and extend, and makes LENGTH the only thing that can break:
// an over-long venue produces an over-long advertisement name, which the
// radio rejects asynchronously, so the report appears on the sender's own
// screen and never leaves the phone. That exact bug has already happened
// here once, when the field's maxLength was set to the text budget with no
// allowance for this format's own 6 bytes of framing.

import 'dart:convert';

import 'package:client/services/hops_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the Vibe Check venue list', () {
    test('every venue fits the advertisement once framed', () {
      for (final venue in kVibeCheckLocations) {
        final advName = 'VBT:$venue:3';
        expect(advertisementNameFits(advName), isTrue,
            reason: '"$venue" produces a ${utf8.encode(advName).length}-byte '
                'name, over the $kAdvertisementNameMaxBytes-byte ceiling — '
                'the report would never leave the phone');
      }
    });

    test('the budget leaves room for the framing', () {
      // "VBT:" + ":" + one digit = 6.
      expect(kVibeCheckLocationMaxBytes,
          kAdvertisementNameMaxBytes - 6);
      for (final venue in kVibeCheckLocations) {
        expect(utf8.encode(venue).length,
            lessThanOrEqualTo(kVibeCheckLocationMaxBytes),
            reason: '"$venue" exceeds the venue budget');
      }
    });

    test('it carries the campus venues plus the Vibe-only places', () {
      for (final shared in kStudyLocations) {
        expect(kVibeCheckLocations, contains(shared),
            reason: 'the two pickers should offer the same campus venues');
      }
      for (final extra in ['Lab 1', 'Lab 2', 'Lab 3', 'Reception']) {
        expect(kVibeCheckLocations, contains(extra));
      }
    });

    test('no duplicates', () {
      // Two identical labels are indistinguishable to a reader while being
      // two separate rows in any grouping of where the crowds are.
      expect(kVibeCheckLocations.toSet().length, kVibeCheckLocations.length);
    });

    test('no venue contains a colon', () {
      // The wire format splits on ":" — a venue carrying one would be
      // parsed as a location and a level that were never sent.
      for (final venue in kVibeCheckLocations) {
        expect(venue.contains(':'), isFalse, reason: '"$venue" has a colon');
      }
    });
  });
}
