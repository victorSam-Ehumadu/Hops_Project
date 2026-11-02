// Round-trips a Community Alert through the real wire format: split into
// parts, split into chunks, encode each chunk as an advertisement name,
// check every name actually fits the radio's budget, decode them back and
// reassemble.
//
// Written for a reported failure where an alert longer than about ten
// characters never arrived while shorter ones did. That is the exact
// signature of a chunk boundary: kCommunityNameTextBudget is 11, so a
// message of 11 bytes or less travels as ONE chunk and anything longer
// needs two. A bug in the multi-chunk path is invisible until you cross
// that line, which is why this walks the whole pipeline rather than
// testing the pieces separately.

import 'dart:convert';

import 'package:client/services/hops_constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// The receiver's side, condensed: buffer chunks by index and join them
/// once all are present (see community_alerts.dart's _ChunkBuffer).
String? reassemble(List<String> advNames) {
  final chunks = <int, String>{};
  int? total;
  for (final name in advNames) {
    final d = decodeCommunityNameChunk(name);
    if (d == null) return null;
    total = d.totalChunks;
    chunks[d.chunkIndex] = d.text;
  }
  if (total == null || chunks.length < total) return null;
  return List.generate(total, (i) => chunks[i] ?? '').join();
}

List<String> encodeAll(String message, String adminUsername) {
  final chunks = splitCommunityMessage(message);
  return [
    for (var i = 0; i < chunks.length; i++)
      encodeCommunityNameChunk(
        senderTag: adminUsername,
        msgId: 7,
        chunkIndex: i,
        totalChunks: chunks.length,
        chunkText: chunks[i],
        isAdmin: true,
      )
  ];
}

void main() {
  group('a Community Alert survives the round trip', () {
    // The reported message. 15 characters — two chunks.
    const reported = 'fire in block 2';

    test('the reported message chunks, fits, and reassembles exactly', () {
      final names = encodeAll(reported, 'adminuser');

      expect(names.length, greaterThan(1),
          reason: 'this message must need more than one chunk, or the test '
              'is not exercising the path that was reported broken');

      for (final n in names) {
        expect(advertisementNameFits(n), isTrue,
            reason: 'chunk "$n" is ${utf8.encode(n).length} bytes, over the '
                '$kAdvertisementNameMaxBytes-byte ceiling — the radio '
                'refuses it and the alert silently never leaves the phone');
      }

      expect(reassemble(names), reported);
    });

    test('every length from 1 to the full capacity round-trips', () {
      const src = 'fire in block 2 — evacuate now, use the east stairwell';
      for (var len = 1; len <= src.length; len++) {
        final message = src.substring(0, len);
        final names = encodeAll(message, 'adminuser');
        for (final n in names) {
          expect(advertisementNameFits(n), isTrue,
              reason: 'length $len produced an over-long chunk: "$n"');
        }
        final back = reassemble(names);
        final expected = splitCommunityMessage(message).join();
        expect(back, expected, reason: 'length $len did not round-trip');
      }
    });

    test('the chunk boundary itself is not a cliff', () {
      // 11 bytes is one chunk; 12 is the first that needs two. If the
      // multi-chunk path is broken, this is where it shows.
      final one = encodeAll('a' * kCommunityNameTextBudget, 'adminuser');
      final two = encodeAll('a' * (kCommunityNameTextBudget + 1), 'adminuser');
      expect(one.length, 1);
      expect(two.length, 2);
      expect(reassemble(one), 'a' * kCommunityNameTextBudget);
      expect(reassemble(two), 'a' * (kCommunityNameTextBudget + 1));
    });

    test('a short admin username does not shift the decoder offsets', () {
      // The tag is padded to a fixed width precisely so the decoder can use
      // fixed offsets; a short name must not corrupt the payload.
      final names = encodeAll(reported, 'abc');
      for (final n in names) {
        expect(advertisementNameFits(n), isTrue);
      }
      expect(reassemble(names), reported);
    });

    test('an alert is split into parts that each fit the chunk ceiling', () {
      final split = splitIntoAlertParts(reported);
      expect(split.truncated, isFalse);
      expect(split.parts.length, 1,
          reason: '15 characters is well inside one part');
      expect(split.parts.first, reported,
          reason: 'a short alert must not be altered by part-splitting');
    });
  });
}
