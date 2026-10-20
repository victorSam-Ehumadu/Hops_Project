// test/views/contact_seed_exchange_test.dart
//
// A source-level guard, not a behavioural test — same reasoning as
// flare_radio_invariant_test.dart next door.
//
// The idle presence beacon broadcasts "HPS:<rotating token>", not a
// username, so Radar cannot name a dot by string comparison. It names one
// by trying each contact's stored *rotating seed* against the observed
// token (RadarScreen._resolveToken). That only works if the seed is on
// file, and a seed only ever gets there by being transmitted.
//
// So every handshake that creates a lasting relationship has to carry the
// seed, in BOTH directions. Miss one side and the symptom is remote and
// confusing: the contact appears in your list perfectly normally, but
// their Radar dot stays anonymous forever — until the two of you happen
// to open a 1:1 chat, whose profile exchange backfills the seed by a
// completely unrelated route. That is precisely the bug the friend
// handshake shipped with: FR:/FA: added the contact but never sent a
// seed, so "people you have added show up named on the radar" silently
// stopped working when the beacon moved from a plaintext username to a
// rotating token.
//
// Nothing BLE is reachable from a unit test (see CLAUDE.md), and two
// physical devices are the only other way this surfaces, so this test
// asserts the shape of the source instead.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _hopsAppPath = 'lib/views/hops_app.dart';

/// Sends our own seed alongside a transient advertisement.
const String _cycle = '_cycleOwnSeedChunks';

/// Reassembles a peer's seed off an incoming advertisement.
const String _reassemble = '_handleIncomingSeedChunk';

/// The four halves of the two relationship-forming handshakes: the method
/// that broadcasts each one, and whether that side sends, receives, or
/// both. A request must send (so the recipient can name us) and receive
/// (so we can name them) — a relationship is mutual, and so is naming.
const Map<String, String> _senders = {
  'sendFriendRequest': 'FR:',
  'acceptFriendRequest': 'FA:',
  'sendWatchRequest': 'WR:',
  '_acceptWatchRequestBle': 'WA:',
};

void main() {
  late String source;

  setUpAll(() {
    final file = File(_hopsAppPath);
    expect(file.existsSync(), isTrue,
        reason: 'Expected $_hopsAppPath relative to the package root. '
            'If the file moved, update this test rather than deleting it.');
    source = file.readAsStringSync();
  });

  /// The body of [name], from its signature to the closing brace of the
  /// method — located by brace depth so a nested closure doesn't end it
  /// early.
  String bodyOf(String name) {
    // Find the *declaration*, not a call site — three of these four are
    // called earlier in the file than they are declared, and matching the
    // call gave a body that started at some unrelated later brace.
    var start = -1;
    for (var from = 0;;) {
      final at = source.indexOf('$name(', from);
      if (at == -1) break;
      final close = source.indexOf(')', at);
      if (close != -1) {
        final after = source.substring(close + 1).trimLeft();
        if (after.startsWith('{') || after.startsWith('async {')) {
          start = at;
          break;
        }
      }
      from = at + 1;
    }
    expect(start, greaterThan(-1),
        reason: 'No declaration of $name found in $_hopsAppPath.');
    final open = source.indexOf('{', start);
    expect(open, greaterThan(-1));
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('Unbalanced braces reading $name.');
  }

  for (final entry in _senders.entries) {
    test('${entry.key} sends our own seed with its ${entry.value} '
        'advertisement', () {
      expect(bodyOf(entry.key), contains(_cycle),
          reason: '${entry.key} broadcasts ${entry.value} but never calls '
              '$_cycle, so the peer never learns our rotating seed and can '
              'never put our name on our Radar dot. Cycle the seed '
              'alongside the advertisement, as the other three do.');
    });

    test('${entry.key} cancels the seed cycle when it reverts the radio',
        () {
      // The cycle re-advertises on a repeating timer. Reverting to the
      // presence beacon without cancelling it means the next tick
      // re-advertises the handshake name on top of the beacon.
      expect(bodyOf(entry.key), contains('_seedCycleTimer?.cancel()'),
          reason: '${entry.key} starts a seed cycle but does not cancel it '
              'before handing the radio back, so a pending tick will '
              're-advertise ${entry.value} over the presence beacon.');
    });
  }

  test('both friend-handshake receivers reassemble the peer seed', () {
    // Guarding the receive side separately because it is the half that
    // was missing, and it fails silently: the contact is still added, so
    // everything looks like it worked.
    for (final prefix in ['FR:', 'FA:']) {
      final at = source.indexOf('name.startsWith("$prefix")');
      expect(at, greaterThan(-1),
          reason: 'No $prefix dispatch branch found in $_hopsAppPath.');
      // Look only as far as the next prefix dispatch, so a neighbouring
      // branch's call can't satisfy this.
      final next = source.indexOf('name.startsWith("', at + 20);
      final branch =
          source.substring(at, next == -1 ? source.length : next);
      expect(branch, contains(_reassemble),
          reason: 'The $prefix handler does not call $_reassemble, so a '
              'contact added through it has no rotating seed on file and '
              'their Radar dot stays anonymous indefinitely.');
    }
  });
}
