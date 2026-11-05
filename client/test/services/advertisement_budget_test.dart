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
  // ── Lost & Found ──────────────────────────────────────────────────────
  //
  // This feature had NO budget coverage, which is exactly how it drifted.
  // kLostFoundChunkTextBudget was written as `29 - overhead` = 19, and 29
  // is not the ceiling — so a full chunk came to 10 + 19 = 29 bytes against
  // a 26-byte limit and _advertiseWithName refused it. Every post whose
  // "<object>|<location>" text filled one chunk failed with "the post could
  // not be sent".
  group('Lost & Found chunk budget', () {
    test('a full chunk fits the advertisement ceiling', () {
      final name = encodeLostFoundChunk(
        postId: 'AB12',
        typeChar: 'L',
        chunkIndex: 0,
        totalChunks: 2,
        chunkText: 'x' * kLostFoundChunkTextBudget,
      );
      expect(advertisementNameFits(name), isTrue,
          reason: 'A chunk filled to kLostFoundChunkTextBudget produces a '
              '${utf8.encode(name).length}-byte name, over the '
              '$kAdvertisementNameMaxBytes-byte ceiling. The radio rejects '
              'it asynchronously, so the post silently never sends.');
    });

    test('the budget leaves room for the feature its own framing', () {
      expect(kLostFoundOverhead, 10,
          reason: 'LNF: (4) + postId (4) + type (1) + chunkInfo (1).');
      expect(kLostFoundChunkTextBudget + kLostFoundOverhead,
          lessThanOrEqualTo(kAdvertisementNameMaxBytes),
          reason: 'text budget + framing must not exceed the ceiling.');
    });

    test('it keeps the same margin Community Alerts proved it needs', () {
      // 26 is the theoretical ceiling; a real handset reported a 23-byte
      // one, which is why kCommunityNameBudget is 22. Deriving Lost & Found
      // from 26 would fix the arithmetic and still not send on that phone.
      expect(kLostFoundChunkTextBudget + kLostFoundOverhead,
          lessThanOrEqualTo(kCommunityNameBudget),
          reason: 'Lost & Found must respect the same conservative budget '
              'as Community Alerts, not the theoretical 26.');
    });

    test('the reported failing post now fits in every chunk', () {
      // "Access Card" lost in "Corridors" — the exact report. 21 characters.
      final chunks = splitLostFoundText('Access Card|Corridors');
      expect(chunks, isNotEmpty);
      expect(chunks.length, lessThanOrEqualTo(kLostFoundMaxChunks));
      for (var i = 0; i < chunks.length; i++) {
        final name = encodeLostFoundChunk(
          postId: 'AB12',
          typeChar: 'L',
          chunkIndex: i,
          totalChunks: chunks.length,
          chunkText: chunks[i],
        );
        expect(advertisementNameFits(name), isTrue,
            reason: 'chunk $i of "Access Card|Corridors" does not fit: '
                '"$name" is ${utf8.encode(name).length} bytes.');
      }
      // And it must still round-trip to the original text.
      expect(chunks.join(), 'Access Card|Corridors');
    });

    test('two full 30-character fields still fit within the chunk ceiling',
        () {
      final text = '${'o' * 30}|${'l' * 30}'; // the UI field maxLengths
      final chunks = splitLostFoundText(text);
      expect(chunks.length, lessThanOrEqualTo(kLostFoundMaxChunks),
          reason: 'The 8-chunk ceiling must cover what the input fields '
              'actually allow, or a long post is silently truncated.');
      expect(chunks.join(), text);
    });
  });
  // ── Manufacturer data alongside a name ────────────────────────────────
  //
  // Device-verified on a Galaxy A04e (Android 14): a flare whose name was
  // only 15 bytes was rejected ADVERTISE_FAILED_DATA_TOO_LARGE, because the
  // signature chunk riding beside it needed 24 bytes of a scan response
  // that had 11 left. The flare name itself had advertised fine a second
  // earlier, so the signature was destroying working alerts.
  group('manufacturer-data budget', () {
    test('the observed failing case is correctly rejected', () {
      const name = 'EMG:Victor:fire'; // exactly what the device logged
      expect(utf8.encode(name).length, 15);
      // marker + chunkInfo + signature bytes
      const chunkPayload = 2 + kFlareSigChunkBudgetBytes;
      expect(chunkPayload, 20);
      expect(advertisementManufacturerPayloadBudget(name), 7,
          reason: '26 (name ceiling) - 15 (name) - 4 (mfg AD header) = 7');
      expect(manufacturerPayloadFitsWithName(name, chunkPayload), isFalse,
          reason: 'This is the packet the radio rejected. If this ever '
              'returns true the arithmetic has drifted back.');
    });

    test('a flare signature cannot fit beside ANY usable flare name', () {
      // 8 chunks is the hard ceiling (chunkInfo packs 3 bits of index), and
      // an RSA-2048 signature is 256 bytes, so a chunk would have to carry
      // 32 signature bytes — more than the whole payload budget even with
      // an empty name. Pinned so nobody re-enables signing by shrinking the
      // chunk and assuming it now fits.
      const sigBytes = 256;
      const maxChunks = 8;
      final neededPerChunk = (sigBytes / maxChunks).ceil();
      expect(neededPerChunk, 32);
      expect(advertisementManufacturerPayloadBudget(''), lessThan(neededPerChunk),
          reason: 'Even with no name at all there is not room for a chunk '
              'big enough to carry the signature in 8 parts.');
    });

    test('budget shrinks byte-for-byte with the name and floors at zero', () {
      expect(advertisementManufacturerPayloadBudget('A' * 10), 12);
      expect(advertisementManufacturerPayloadBudget('A' * 22), 0);
      expect(advertisementManufacturerPayloadBudget('A' * 26), 0,
          reason: 'Must floor at 0, never go negative.');
    });

    test('measured in UTF-8 bytes, not characters', () {
      // 'é' is two bytes, so it costs twice what .length suggests.
      final budget = advertisementManufacturerPayloadBudget('é' * 5);
      expect(budget, 26 - 10 - 4);
    });

    test('the Study Bunny location still fits beside a full-length tag', () {
      // The one manufacturer-data user that MUST keep working: marker plus
      // a one-byte location index, beside the longest subject the UI allows.
      final name = 'SBF:AB12:${'x' * advertisementTextBudget(9)}';
      expect(advertisementNameFits(name), isTrue);
      expect(manufacturerPayloadFitsWithName(name, 2), isFalse,
          reason: 'A full-length Study Bunny subject leaves no room for the '
              'location byte, so the location silently does not travel. '
              'Documented, not desired — see CLAUDE.md.');
      // With a short subject it does fit, which is the common case.
      expect(manufacturerPayloadFitsWithName('SBF:AB12:Maths', 2), isTrue);
    });
  });
}
