// Study Bunny location encoding.
//
// The location travels as a one-byte INDEX into kStudyLocations, which
// makes the list's order part of the wire format. That is the whole risk
// here and what most of these tests are about: reordering or removing an
// entry silently relabels every tag already in flight, so someone in the
// Library gets shown as being in a lab. Nothing would error — it would
// just be wrong, for a feature whose entire purpose is finding a person.
import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/hops_constants.dart';

void main() {
  group('round trip', () {
    test('every location survives encode then decode', () {
      for (var i = 0; i < kStudyLocations.length; i++) {
        expect(decodeStudyLocation(encodeStudyLocation(i)), i,
            reason: 'index $i (${kStudyLocations[i]}) must round-trip');
      }
    });

    test('encodes to exactly two bytes', () {
      // Marker + index. The point of using an index at all is that it
      // costs this little; a free-text location would be ten or more.
      expect(encodeStudyLocation(0).length, 2);
    });

    test('fits the advertisement budget with room to spare', () {
      // Manufacturer data is a separate allowance from the name, but it
      // shares the packet, so it is worth knowing this is tiny.
      expect(encodeStudyLocation(kStudyLocations.length - 1).length,
          lessThan(8));
    });
  });

  group('rejects what it should', () {
    test('ignores data with a different protocol marker', () {
      // The manufacturer-data slot is shared with rotating-ID seeds,
      // flare signatures and the Discoverable name. Decoding one of those
      // as a location would invent a place out of unrelated bytes.
      expect(decodeStudyLocation([kDiscoverableProtocolMarker, 2]), isNull);
      expect(decodeStudyLocation([kWatchSeedProtocolMarker, 2]), isNull);
    });

    test('ignores truncated data', () {
      expect(decodeStudyLocation([]), isNull);
      expect(decodeStudyLocation([kStudyLocationProtocolMarker]), isNull);
    });

    test('returns null for an index this build does not know', () {
      // A newer build may add locations. Rather than clamping into range —
      // which would show a location the sender never chose — an unknown
      // index reads as "no location", a state the UI already handles.
      final tooBig = [kStudyLocationProtocolMarker, kStudyLocations.length];
      expect(decodeStudyLocation(tooBig), isNull);
      expect(decodeStudyLocation([kStudyLocationProtocolMarker, 255]), isNull);
    });
  });

  group('the location list is a wire format', () {
    test('the marker byte is stable', () {
      // Changing this stops interoperating with any build already
      // installed, for no gain.
      expect(kStudyLocationProtocolMarker, 0x4C);
    });

    test('indices 0..n map to the expected names', () {
      // Pins ORDER, not just membership. A test that only checked the set
      // of names would pass after a reorder, which is the dangerous edit.
      expect(kStudyLocations[0], 'Venue 1');
      expect(kStudyLocations[2], 'Venue 3');
      expect(kStudyLocations[13], 'Venue 14');
      expect(kStudyLocations[14], 'Student Pods');
      expect(kStudyLocations[15], 'Auditorium');
      expect(kStudyLocations.last, 'Benches');
    });

    test('no duplicate names', () {
      // Two identical labels would be indistinguishable to a user while
      // being different on the wire.
      expect(kStudyLocations.toSet().length, kStudyLocations.length);
    });

    test('stays within one byte', () {
      expect(kStudyLocations.length, lessThanOrEqualTo(256));
    });
  });

  group('studyLocationName', () {
    test('names a valid index', () {
      expect(studyLocationName(0), 'Venue 1');
    });

    test('returns null for null, negative or out-of-range', () {
      // Null is the ordinary case — the location is optional — so this
      // must not throw on it.
      expect(studyLocationName(null), isNull);
      expect(studyLocationName(-1), isNull);
      expect(studyLocationName(kStudyLocations.length), isNull);
    });
  });
}
