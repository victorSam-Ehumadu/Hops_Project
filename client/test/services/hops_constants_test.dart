// Unit tests for the BLE advertisement wire format (lib/services/hops_constants.dart).
//
// This module is the highest-value test target in the project: it is pure
// Dart with no plugin dependencies, and it encodes the tightest constraint
// in the codebase — an advertisement payload that fails *entirely* if the
// encoded name runs long. Every field width here is load-bearing, and the
// file's own comments record a real outage caused by hardcoded field
// offsets drifting out of step with a widened sender tag. These tests pin
// the layout so that can't happen silently again.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:client/services/hops_constants.dart';

void main() {
  // ── Budget arithmetic ─────────────────────────────────────────────────
  //
  // The derived budgets are what every encoder clamps against, so a change
  // to one constant that silently shrinks another is a wire-format break.
  group('advertisement budgets', () {
    test('community text budget is the name budget minus its overhead', () {
      expect(kCommunityNameTextBudget, kCommunityNameBudget - kCommunityNameOverhead);
      // 22 - 13. Was 11 at a 24-byte budget. Briefly 7 at a 20-byte
      // budget, reverted — see kCommunityNameBudget for why that was the
      // wrong move.
      expect(kCommunityNameTextBudget, 9);
    });

    test('a COMPLETELY FULL chunk still fits the budget', () {
      // The one case that has broken three times, and it has never once
      // looked like a packet problem from the outside: short alerts send,
      // and from one particular length onwards they silently do not,
      // because the cutoff lands exactly where a chunk first fills up.
      //
      // Most recently the alert "attention" would not send — nine
      // characters, which at the then-budget was precisely a full chunk and
      // therefore a name of exactly the ceiling. Asserting the derived
      // arithmetic is not enough on its own (it was self-consistent every
      // time); this builds the worst-case name and measures it.
      final fullChunk = encodeCommunityNameChunk(
        senderTag: 'Sender12',
        msgId: 63,
        chunkIndex: 7,
        totalChunks: 8,
        chunkText: 'x' * kCommunityNameTextBudget,
      );
      expect(utf8.encode(fullChunk).length, lessThanOrEqualTo(kCommunityNameBudget),
          reason: 'A chunk filled to kCommunityNameTextBudget must still fit '
              'kCommunityNameBudget. If this fails the two constants have '
              'drifted and messages of one exact length will vanish.');
      // And that the budget itself stays under the hard advertisement
      // ceiling, with margin — the ceiling is theoretical and at least one
      // handset honours something lower.
      expect(kCommunityNameBudget, lessThan(kAdvertisementNameMaxBytes));
    });

    test('community overhead matches the documented field layout', () {
      // prefix(3) + senderTag(8) + msgId(1) + chunkInfo(1)
      expect(kCommunityNameOverhead, 3 + kCommunityNameSenderTagChars + 1 + 1);
    });

    test('direct message text budget is the name budget minus its overhead', () {
      expect(kDirectMessageTextBudget, kCommunityNameBudget - kDirectMessageOverhead);
      // 22 - 11. Was 13 at a 24-byte name budget. Moves with the budget
      // because a DM rides the same advertisement name.
      expect(kDirectMessageTextBudget, 11);
    });

    test('direct message overhead matches the documented field layout', () {
      // prefix(3) + recipientTag(3) + senderTag(3) + msgId(1) + chunkInfo(1)
      expect(kDirectMessageOverhead, 3 + (kDirectMessageTagChars * 2) + 1 + 1);
    });

    test('max plaintext is derived from base64 expansion and the nonce', () {
      // base64 carries 3 bytes per 4 characters, then 6 bytes go to the nonce.
      const base64Chars = kDirectMessageMaxChunks * kDirectMessageTextBudget;
      expect(kDirectMessageMaxPlaintextBytes, ((base64Chars ~/ 4) * 3) - 6);
      // Falls out of the budget above rather than being chosen: 8 chunks x
      // 11 characters of base64 = 88 -> 66 bytes, less the 6-byte nonce.
      expect(kDirectMessageMaxPlaintextBytes, 60);
    });

    test('alert part budget stays inside the reliable few-chunk band', () {
      expect(kAlertPartMaxBytes, kCommunityNameTextBudget * 3);
      // A part must never need more chunks than the 3-bit chunk counter allows.
      expect(kAlertPartMaxBytes ~/ kCommunityNameTextBudget,
          lessThanOrEqualTo(kCommunityNameMaxChunks));
    });

    test('chunk counters fit the 3 bits the wire format reserves', () {
      expect(kCommunityNameMaxChunks, lessThanOrEqualTo(8));
      expect(kDirectMessageMaxChunks, lessThanOrEqualTo(8));
    });
  });

  // ── Community chat chunks ─────────────────────────────────────────────
  group('community chat chunk encoding', () {
    test('round-trips a single-chunk message', () {
      final encoded = encodeCommunityNameChunk(
        senderTag: 'Kwame123',
        msgId: 5,
        chunkIndex: 0,
        totalChunks: 1,
        chunkText: 'hello',
      );

      final decoded = decodeCommunityNameChunk(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.senderTag, 'Kwame123');
      expect(decoded.msgId, 5);
      expect(decoded.chunkIndex, 0);
      expect(decoded.totalChunks, 1);
      expect(decoded.text, 'hello');
      expect(decoded.isAdmin, isFalse);
    });

    test('admin prefix decodes as admin through the same path', () {
      final encoded = encodeCommunityNameChunk(
        senderTag: 'HopsAdmin',
        msgId: 1,
        chunkIndex: 0,
        totalChunks: 1,
        chunkText: 'notice',
        isAdmin: true,
      );

      expect(encoded.startsWith(kAdminCommunityChatPrefix), isTrue);
      expect(decodeCommunityNameChunk(encoded)!.isAdmin, isTrue);
    });

    test('a short sender tag is padded so field offsets do not shift', () {
      // This is the exact class of bug the source file documents: a tag
      // narrower than the fixed width slides msgId and chunkInfo left, and
      // the decoder then reads them out of the middle of the username.
      final encoded = encodeCommunityNameChunk(
        senderTag: 'Vic',
        msgId: 9,
        chunkIndex: 0,
        totalChunks: 1,
        chunkText: 'hi',
      );

      final decoded = decodeCommunityNameChunk(encoded)!;
      expect(decoded.senderTag, 'Vic_____');
      expect(decoded.senderTag.length, kCommunityNameSenderTagChars);
      expect(decoded.msgId, 9);
      expect(decoded.text, 'hi');
    });

    test('an over-long sender tag is truncated to the fixed width', () {
      final encoded = encodeCommunityNameChunk(
        senderTag: 'VeryLongUsername',
        msgId: 0,
        chunkIndex: 0,
        totalChunks: 1,
        chunkText: 'x',
      );

      expect(decodeCommunityNameChunk(encoded)!.senderTag, 'VeryLong');
    });

    test('carries the last addressable chunk of a full-length message', () {
      // chunkIndex 7 of 8 packs both 3-bit fields at their maximum.
      final encoded = encodeCommunityNameChunk(
        senderTag: 'Sender12',
        msgId: 63,
        chunkIndex: 7,
        totalChunks: 8,
        chunkText: 'tail',
      );

      final decoded = decodeCommunityNameChunk(encoded)!;
      expect(decoded.chunkIndex, 7);
      expect(decoded.totalChunks, 8);
      expect(decoded.msgId, 63);
    });

    test('message ids wrap within 6 bits rather than overflowing the field', () {
      final wrapped = encodeCommunityNameChunk(
        senderTag: 'Sender12', msgId: 64, chunkIndex: 0, totalChunks: 1, chunkText: '');
      final zero = encodeCommunityNameChunk(
        senderTag: 'Sender12', msgId: 0, chunkIndex: 0, totalChunks: 1, chunkText: '');

      expect(wrapped, zero);
      expect(decodeCommunityNameChunk(wrapped)!.msgId, 0);
    });

    test('encoded chunks never exceed the advertisement name budget', () {
      for (final text in splitCommunityMessage('The quick brown fox jumps over it')) {
        final encoded = encodeCommunityNameChunk(
          senderTag: 'Sender12',
          msgId: 1,
          chunkIndex: 0,
          totalChunks: 3,
          chunkText: text,
        );
        expect(utf8.encode(encoded).length, lessThanOrEqualTo(kCommunityNameBudget),
            reason: 'over-budget names fail the whole advertisement');
      }
    });

    test('rejects names that are not community chunks', () {
      expect(decodeCommunityNameChunk('HPS:abcd1234'), isNull);
      expect(decodeCommunityNameChunk('EMG:Vic:Fire'), isNull);
      expect(decodeCommunityNameChunk(''), isNull);
    });

    test('rejects a truncated chunk instead of reassembling garbage', () {
      expect(decodeCommunityNameChunk('CM:Vic'), isNull);
    });

    test('rejects a chunk whose counter fields are outside the alphabet', () {
      // ':' is deliberately excluded from the field alphabet so a prefix
      // separator can never be misread as a counter.
      expect(decodeCommunityNameChunk('CM:Sender12::text'), isNull);
    });
  });

  // ── Message splitting ─────────────────────────────────────────────────
  group('splitCommunityMessage', () {
    test('keeps a short message in one chunk', () {
      expect(splitCommunityMessage('hello'), ['hello']);
    });

    test('always yields at least one chunk for an empty message', () {
      expect(splitCommunityMessage(''), ['']);
    });

    test('splits on the byte budget, not the character count', () {
      // Each chunk must fit 11 *bytes*; the advertisement budget is a byte
      // budget, so a multi-byte character costs more than one.
      final chunks = splitCommunityMessage('aaaaaaaaaaabbbbbbbbbbbccc');
      for (final chunk in chunks) {
        expect(utf8.encode(chunk).length, lessThanOrEqualTo(kCommunityNameTextBudget));
      }
      expect(chunks.join(), 'aaaaaaaaaaabbbbbbbbbbbccc');
    });

    test('never splits a multi-byte character across two chunks', () {
      // A byte-index split lands mid-character and corrupts it on both
      // sides of the seam — unrecoverable, and emoji in chat are ordinary.
      const message = '😀😀😀 café 😀😀';
      final chunks = splitCommunityMessage(message);

      for (final chunk in chunks) {
        expect(utf8.encode(chunk).length, lessThanOrEqualTo(kCommunityNameTextBudget));
        // A corrupted seam shows up as a replacement character.
        expect(chunk.contains('�'), isFalse);
      }
      expect(chunks.join(), message);
    });

    test('caps at the addressable chunk ceiling', () {
      final chunks = splitCommunityMessage('x' * 500);
      expect(chunks.length, kCommunityNameMaxChunks);
    });
  });

  group('splitIntoAlertParts', () {
    test('keeps a short alert as a single untruncated part', () {
      final result = splitIntoAlertParts('Gate closed');
      expect(result.parts, ['Gate closed']);
      expect(result.truncated, isFalse);
    });

    test('splits on word boundaries rather than mid-word', () {
      final result = splitIntoAlertParts(
          'Main gate is closed until further notice please use the side entrance');

      expect(result.parts.length, greaterThan(1));
      for (final part in result.parts) {
        expect(utf8.encode(part).length, lessThanOrEqualTo(kAlertPartMaxBytes));
        expect(part.trim(), part, reason: 'parts should not carry edge whitespace');
      }
      // Rejoining the parts reproduces the original word sequence.
      expect(result.parts.join(' ').split(RegExp(r'\s+')),
          'Main gate is closed until further notice please use the side entrance'
              .split(RegExp(r'\s+')));
    });

    test('falls back to a hard split for a single oversized word', () {
      // A long URL has no spaces to break on, but a part still has to fit.
      final result = splitIntoAlertParts('https://example.edu/notices/2026/campus-safety-update');

      for (final part in result.parts) {
        expect(utf8.encode(part).length, lessThanOrEqualTo(kAlertPartMaxBytes));
      }
      expect(result.parts.length, greaterThan(1));
    });

    test('reports truncation instead of silently dropping the tail', () {
      final result = splitIntoAlertParts(List.filled(120, 'word').join(' '));

      expect(result.parts.length, lessThanOrEqualTo(kAlertMaxParts));
      expect(result.truncated, isTrue,
          reason: 'a silent length limit moves the bug to a confused admin');
    });

    test('always yields at least one part for an empty alert', () {
      final result = splitIntoAlertParts('   ');
      expect(result.parts, ['']);
      expect(result.truncated, isFalse);
    });
  });

  // ── Moderation deletions ──────────────────────────────────────────────
  group('community deletion', () {
    test('round-trips a deletion', () {
      final encoded = encodeCommunityDeletion(
        senderTag: 'Kwame123',
        msgId: 2,
        reason: CommunityDeleteReason.harassment,
      );

      final decoded = decodeCommunityDeletion(encoded)!;
      expect(decoded.senderTag, 'Kwame123');
      expect(decoded.msgId, 2);
      expect(decoded.reason, CommunityDeleteReason.harassment);
    });

    test('identifies its target with the same key the receiver already uses', () {
      // senderTag + msgId, so a deletion needs no new identifier on the wire.
      final chunk = decodeCommunityNameChunk(encodeCommunityNameChunk(
        senderTag: 'Kwame123', msgId: 7, chunkIndex: 0, totalChunks: 1, chunkText: 'x'))!;
      final deletion = decodeCommunityDeletion(encodeCommunityDeletion(
        senderTag: 'Kwame123', msgId: 7, reason: CommunityDeleteReason.spam))!;

      expect(deletion.senderTag, chunk.senderTag);
      expect(deletion.msgId, chunk.msgId);
    });

    test('falls back to a generic reason rather than dropping an unknown one', () {
      // A newer build may send a reason this one has no label for. Removing
      // the message is the part that matters.
      const unknownReason = '${kCommunityDeletePrefix}Kwame123C_';
      final decoded = decodeCommunityDeletion(unknownReason);

      expect(decoded, isNotNull);
      expect(decoded!.reason, CommunityDeleteReason.other);
    });

    test('reason ordinals are stable on the wire', () {
      // The ordinal travels, so entries may be appended but never reordered
      // — an older build would render a shifted index as the wrong reason.
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.spam), 0);
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.harassment), 1);
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.inappropriate), 2);
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.misinformation), 3);
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.other), 4);
      expect(CommunityDeleteReason.values.indexOf(CommunityDeleteReason.removedBySender), 5);
    });

    test('every reason has a user-facing label', () {
      for (final reason in CommunityDeleteReason.values) {
        expect(kCommunityDeleteReasonLabels[reason], isNotNull);
      }
    });

    test('rejects a name that is not a deletion', () {
      expect(decodeCommunityDeletion('CM:Kwame123FAhi'), isNull);
      expect(decodeCommunityDeletion('CX:short'), isNull);
    });
  });

  // ── Direct messages ───────────────────────────────────────────────────
  group('direct message chunk encoding', () {
    test('round-trips a chunk carrying both tags', () {
      final encoded = encodeDirectMessageChunk(
        recipientTag: 'abc',
        senderTag: 'xyz',
        msgId: 1,
        chunkIndex: 2,
        totalChunks: 4,
        chunkPayload: 'QUJDRA',
      );

      final decoded = decodeDirectMessageChunk(encoded)!;
      expect(decoded.recipientTag, 'abc');
      expect(decoded.senderTag, 'xyz');
      expect(decoded.msgId, 1);
      expect(decoded.chunkIndex, 2);
      expect(decoded.totalChunks, 4);
      expect(decoded.payload, 'QUJDRA');
    });

    test('addresses by a fixed-width slice of the rotating token', () {
      expect(directMessageTag('abcdefgh'), 'abc');
      expect(directMessageTag('abcdefgh').length, kDirectMessageTagChars);
    });

    test('pads a short token so both tag fields stay aligned', () {
      expect(directMessageTag('ab'), 'ab_');
      expect(directMessageTag('ab').length, kDirectMessageTagChars);
    });

    test('rejects names that are not direct message chunks', () {
      expect(decodeDirectMessageChunk('CM:Kwame123FAhi'), isNull);
      expect(decodeDirectMessageChunk('DM:short'), isNull);
    });
  });

  // ── Rotating presence identifiers ─────────────────────────────────────
  //
  // The privacy property the presence beacon depends on: a passive scanner
  // must not be able to read a stable identifier off the air and follow a
  // device around campus.
  group('rotating presence tokens', () {
    final seed = List<int>.generate(32, (i) => i);
    final otherSeed = List<int>.generate(32, (i) => 255 - i);

    test('fits the advertisement budget alongside its prefix', () {
      final token = computeRotatingToken(seed, at: DateTime.utc(2026, 8, 31, 12));
      expect(token.length, 8);
      expect(utf8.encode('HPS:$token').length, lessThanOrEqualTo(kCommunityNameBudget));
    });

    test('is deterministic within one window', () {
      // Two different times inside the same 15-minute bucket.
      final a = computeRotatingToken(seed, at: DateTime.utc(2026, 8, 31, 12, 1));
      final b = computeRotatingToken(seed, at: DateTime.utc(2026, 8, 31, 12, 13));
      expect(a, b);
    });

    test('changes between windows so a device cannot be tracked over time', () {
      final a = computeRotatingToken(seed, at: DateTime.utc(2026, 8, 31, 12, 1));
      final b = computeRotatingToken(seed, at: DateTime.utc(2026, 8, 31, 13, 1));
      expect(a, isNot(b));
    });

    test('differs between devices in the same window', () {
      final at = DateTime.utc(2026, 8, 31, 12);
      expect(computeRotatingToken(seed, at: at),
          isNot(computeRotatingToken(otherSeed, at: at)));
    });

    test('recognises a contact in the current window', () {
      expect(matchesRotatingToken(seed, computeRotatingToken(seed)), isTrue);
    });

    test('tolerates a window rollover by accepting the previous window', () {
      final previous = computeRotatingToken(seed,
          at: DateTime.now().subtract(kRotatingIdWindow));
      expect(matchesRotatingToken(seed, previous), isTrue);
    });

    test('does not recognise an unrelated token', () {
      expect(matchesRotatingToken(seed, 'AAAAAAAA'), isFalse);
      expect(matchesRotatingToken(seed, computeRotatingToken(otherSeed)), isFalse);
    });

    test('matches on a truncated prefix for the narrower tag fields', () {
      final token = computeRotatingToken(seed);
      expect(matchesRotatingTokenPrefix(seed, token.substring(0, 4)), isTrue);
    });
  });

  // ── Anonymous display labels ──────────────────────────────────────────
  group('anonymousLabelFor', () {
    test('is stable, so a conversation stays followable', () {
      expect(anonymousLabelFor('Kwame123'), anonymousLabelFor('Kwame123'));
    });

    test('is short enough for an "Anonymous #xxxx" label', () {
      expect(anonymousLabelFor('Kwame123').length, 4);
    });

    test('ignores the padding a short tag was widened with', () {
      // 'Vic' and its padded wire form are the same person.
      expect(anonymousLabelFor('Vic'), anonymousLabelFor('Vic_____'));
    });

    test('does not simply echo the username back', () {
      // Building the label from the tag rendered "Anonymous #Kwame123",
      // which is the opposite of anonymous.
      expect(anonymousLabelFor('Kwame123'), isNot(contains('Kwame')));
    });

    test('distinguishes different senders', () {
      expect(anonymousLabelFor('Kwame123'), isNot(anonymousLabelFor('Thabo456')));
    });
  });

  // ── Emergency flare signature chunks ──────────────────────────────────
  group('flare signature chunking', () {
    test('round-trips a chunk', () {
      final encoded = encodeFlareSigChunk(
        chunkIndex: 3,
        totalChunks: 5,
        chunkBytes: [1, 2, 3, 4],
      );

      final decoded = decodeFlareSigChunk(encoded)!;
      expect(decoded.chunkIndex, 3);
      expect(decoded.totalChunks, 5);
      expect(decoded.bytes, [1, 2, 3, 4]);
    });

    test('carries the last addressable chunk of a full signature', () {
      // 4 bits each, so 15 of 16 saturates both halves of the packed byte.
      final decoded = decodeFlareSigChunk(
          encodeFlareSigChunk(chunkIndex: 15, totalChunks: 16, chunkBytes: [9]))!;

      expect(decoded.chunkIndex, 15);
      expect(decoded.totalChunks, 16);
    });

    test('reassembles a full RSA-2048 signature from its chunks', () {
      final signature = List<int>.generate(256, (i) => i % 256);
      final chunks = <List<int>>[];
      for (var i = 0; i < signature.length; i += kFlareSigChunkBudgetBytes) {
        chunks.add(signature.sublist(
            i, (i + kFlareSigChunkBudgetBytes).clamp(0, signature.length)));
      }

      final reassembled = <int>[];
      for (var i = 0; i < chunks.length; i++) {
        final decoded = decodeFlareSigChunk(encodeFlareSigChunk(
          chunkIndex: i,
          totalChunks: chunks.length,
          chunkBytes: chunks[i],
        ))!;
        expect(decoded.chunkIndex, i);
        expect(decoded.totalChunks, chunks.length);
        reassembled.addAll(decoded.bytes);
      }

      expect(reassembled, signature);
    });

    test('every encoded chunk fits the manufacturer-data budget', () {
      final encoded = encodeFlareSigChunk(
        chunkIndex: 0,
        totalChunks: 1,
        chunkBytes: List.filled(kFlareSigChunkBudgetBytes, 0),
      );
      expect(encoded.length, lessThanOrEqualTo(kCommunityChunkBudgetBytes));
    });

    test('a distinct marker keeps it from being misparsed as another payload', () {
      expect(decodeFlareSigChunk([kWatchSeedProtocolMarker, 0x00, 1, 2]), isNull);
      expect(decodeFlareSigChunk([kFlareSigProtocolMarker]), isNull);
      expect(decodeFlareSigChunk([]), isNull);
    });
  });

  // ── Post ownership (LNO: / SBO:) ──────────────────────────────────────
  //
  // Lost & Found posts and Study Bunny tags carry no sender in their own
  // names, so a report against one reached a moderator attributed to
  // nobody. Ownership rides a separate short advertisement keyed on the id
  // the post already has.
  group('owner records', () {
    test('both prefixes fit the budget with room to spare', () {
      // Every previous miscalculation on this radio came from sitting
      // exactly on a ceiling, so this asserts margin, not just a fit.
      for (final prefix in [kLostFoundOwnerPrefix, kStudyOwnerPrefix]) {
        final name = encodeOwnerRecord(
            prefix: prefix, id: 'AB12', username: 'averylongusername');
        expect(utf8.encode(name).length, kOwnerRecordLength);
        expect(utf8.encode(name).length, lessThan(kCommunityNameBudget));
      }
    });

    test('round trips, truncating a long username to the wire tag', () {
      final name = encodeOwnerRecord(
          prefix: kLostFoundOwnerPrefix, id: 'AB12', username: 'Victorious1');
      final back = decodeOwnerRecord(name, kLostFoundOwnerPrefix)!;
      expect(back.id, 'AB12');
      expect(back.senderTag, communitySenderTag('Victorious1'));
    });

    test('a short username keeps its padding, as the wire carries it', () {
      // NOT trimmed. communitySenderTag pads with '_', and '_' is a legal
      // username character, so trimming cannot tell "vic" padded apart
      // from a real account named "vic_____". The padded form is what
      // KeyDirectory.candidatesForTruncatedUsername already expects, and
      // it understands both shapes.
      final name = encodeOwnerRecord(
          prefix: kStudyOwnerPrefix, id: 'ZZ99', username: 'vic');
      expect(utf8.encode(name).length, kOwnerRecordLength);
      expect(decodeOwnerRecord(name, kStudyOwnerPrefix)!.senderTag,
          communitySenderTag('vic'));
    });

    test('the two prefixes never decode as each other', () {
      // They are the same shape, so only the prefix separates a study tag
      // owner from a Lost & Found one. Crossing them would attribute a
      // post to whoever happened to own a tag with a colliding id.
      final lnf = encodeOwnerRecord(
          prefix: kLostFoundOwnerPrefix, id: 'AB12', username: 'vic');
      expect(decodeOwnerRecord(lnf, kStudyOwnerPrefix), isNull);
      expect(decodeOwnerRecord(lnf, kLostFoundOwnerPrefix), isNotNull);
    });

    test('anything malformed decodes to null rather than a guess', () {
      // A WRONG attribution is worse than none here: it would put an
      // innocent account's name on a moderation report.
      expect(decodeOwnerRecord('LNO:AB12', kLostFoundOwnerPrefix), isNull);
      expect(decodeOwnerRecord('LNO:AB12vic12345678', kLostFoundOwnerPrefix),
          isNull);
      expect(decodeOwnerRecord('LNF:AB12vic_____', kLostFoundOwnerPrefix), isNull);
      expect(decodeOwnerRecord('', kLostFoundOwnerPrefix), isNull);
      // All padding, no name.
      expect(decodeOwnerRecord('SBO:AB12________', kStudyOwnerPrefix), isNull);
    });

    test('the id width matches what both features actually generate', () {
      // Lost & Found post ids and Study Bunny tag ids are generated in
      // different files; this is the assumption that lets one encoder
      // serve both.
      expect(kOwnerRecordIdChars, kLostFoundPostIdChars);
    });
  });

  // ── Service identity ──────────────────────────────────────────────────
  test('the service UUID is a single shared constant', () {
    // Duplicating this as a private constant per file previously meant
    // editing it changed nothing at runtime.
    expect(HOPS_SERVICE_UUID, "0000FA57-0000-1000-8000-00805F9B34FB");
  });

  group('how long a personal flare stays live', () {
    // Receivers' auto-cancel, the sender's countdown, and both the
    // in-app and background notification auto-expiries all key off this
    // one value.
    test('is five minutes', () {
      expect(kEmergencyFlareDuration, const Duration(minutes: 5));
    });

    test('is long enough to cross a building, not just to be noticed', () {
      // The point of the change from 60s: a minute is roughly how long it
      // takes to register an alarm and work out where it came from, which
      // left no time to actually get there. Guards against anyone
      // "tidying" it back to seconds.
      expect(kEmergencyFlareDuration.inMinutes, greaterThanOrEqualTo(3));
    });

    test('is spoken in whole minutes, not in seconds', () {
      // The SnackBar interpolated .inSeconds, which read as "300 seconds".
      expect(describeAlertDuration(kEmergencyFlareDuration), '5 minutes');
      expect(describeAlertDuration(const Duration(seconds: 60)), '1 minute');
      expect(describeAlertDuration(const Duration(seconds: 30)), '30 seconds');
      // Not a whole number of minutes — stays in seconds rather than
      // rounding, since rounding an emergency window down would misstate
      // it in the one direction that matters.
      expect(describeAlertDuration(const Duration(seconds: 90)), '90 seconds');
    });
  });
}
