// test/views/contact_seed_exchange_test.dart
//
// A source-level guard, not a behavioural test — same technique as
// flare_radio_invariant_test.dart next door.
//
// WHAT THIS NOW GUARDS, AND WHY IT IS THE OPPOSITE OF WHAT IT GUARDED
//
// This file used to assert that the friend and watch handshakes each
// pushed this device's rotating-ID seed to the peer as manufacturer-data
// chunks riding alongside the handshake advertisement, so Radar could name
// a contact's dot without the two ever opening a 1:1 chat.
//
// That cannot work. Manufacturer data and a local name cannot share one
// 31-byte BLE scan response:
//
//   name "WR:<user>:<user>"    24 bytes (2 AD header + 22 chars)
//   manufacturer seed chunk    24 bytes (4 AD header + 20 payload)
//                              --
//                              48 bytes -> ADVERTISE_FAILED_DATA_TOO_LARGE
//
// The radio rejected the whole advertisement, so the handshake itself
// never went out either. It went unnoticed for as long as it did because
// that verdict arrives on an async callback that only reported flare
// failures; once every feature started reporting, friend requests began
// visibly failing with "data too large" on real hardware.
//
// So the mechanism is gone, and this test now guards its absence. The
// temptation to re-add it is real — "contacts you added show named on the
// radar" is a reasonable thing to want — so the byte arithmetic is written
// into the failure message rather than left for someone to rediscover.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _hopsAppPath = 'lib/views/hops_app.dart';

void main() {
  late String source;

  setUpAll(() {
    final file = File(_hopsAppPath);
    expect(file.existsSync(), isTrue,
        reason: 'Expected $_hopsAppPath relative to the package root. '
            'If the file moved, update this test rather than deleting it.');
    // Comments stripped: the file deliberately explains the removed
    // mechanism BY NAME so nobody re-adds it, and a naive text search
    // matches that explanation and fails on the very documentation that
    // exists to prevent the regression.
    source = file
        .readAsLinesSync()
        .map((l) {
          final i = l.indexOf('//');
          return i == -1 ? l : l.substring(0, i);
        })
        // Space, not a newline: every check here is a substring search or
        // a brace count, and a space keeps tokens from running together
        // where a stripped comment ended a line mid-expression.
        .join(' ');
  });

  test('no advertisement sends seed chunks as manufacturer data', () {
    // The helpers are gone; their absence is the invariant.
    for (final symbol in ['_cycleOwnSeedChunks', '_handleIncomingSeedChunk']) {
      expect(source.contains(symbol), isFalse,
          reason: '$symbol is back. Manufacturer data cannot share a '
              '31-byte scan response with a local name — a 22-char name '
              'costs 24 bytes and a seed chunk costs 24 more, so the whole '
              'advertisement fails with ADVERTISE_FAILED_DATA_TOO_LARGE '
              'and the handshake never leaves the radio. Use a dedicated '
              'chunked NAME payload instead, as CM:/DM: do.');
    }
  });

  test('the handshake advertisements carry no manufacturer data at all', () {
    // Checks each sender's own body rather than the file as a whole, since
    // other features (Study Bunny location, flare signatures) legitimately
    // use manufacturer data on advertisements whose names leave room.
    for (final fn in [
      'sendFriendRequest',
      'acceptFriendRequest',
      'sendWatchRequest',
      '_acceptWatchRequestBle',
    ]) {
      expect(_bodyOf(source, fn), isNot(contains('manufacturerData')),
          reason: '$fn attaches manufacturer data to an advertisement whose '
              'name already fills the scan response. Do the byte '
              'arithmetic before adding this back.');
    }
  });

  test('the seed still reaches a peer somehow — via RFCOMM', () {
    // The one route that does work, and the reason Radar can name a dot
    // at all. If this disappears, rotating-token resolution has no input
    // and every contact becomes permanently anonymous.
    final chat = File('lib/views/chat_terminal.dart').readAsStringSync();
    expect(chat, contains('upsertContactRotatingSeed'),
        reason: 'chat_terminal no longer stores a peer rotating seed, so '
            'nothing anywhere does and Radar can never name a contact.');
  });
}

/// The body of [name], located by brace depth. Finds the *declaration*,
/// not a call site — several of these are called earlier in the file than
/// they are declared.
String _bodyOf(String source, String name) {
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
  expect(start, greaterThan(-1), reason: 'No declaration of $name found.');
  final open = source.indexOf('{', start);
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
