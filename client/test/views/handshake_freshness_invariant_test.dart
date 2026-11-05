// Source-level guards, not behavioural tests — the same approach as
// flare_radio_invariant_test.dart, and for the same reason: the bug these
// protect against only appears with two physical devices and a wait, so no
// unit test can actually reproduce it.
//
// THE BUG. `FlutterBluePlus.scanResults` emits the whole accumulated result
// list on every update, and hops_app.dart does not pass `removeIfGone`, so an
// entry never leaves that list for the life of the scan. Android also hands
// back a new random advertising address on each re-advertise, so when a device
// finishes a transient handshake advertisement and reverts to its HPS: beacon,
// the beacon usually arrives as a DIFFERENT entry and the handshake entry is
// never overwritten. It sits there with its old name, being re-delivered
// indefinitely.
//
// For a one-shot handshake that is live, not cosmetic. A watch request that
// was sent and accepted days ago is still in the list, and the only thing
// stopping it being raised again is a 30-second dedup set. Once that expires
// the request reappears with nobody having sent it — which is exactly how this
// was found: ending a watch dropped the peer from the set that happened to be
// suppressing their stale request, and a brand new request appeared for the
// watch that had just been ended.
//
// Name-based dedup cannot fix it. A genuine repeat request is byte-identical
// to the stale one; the only thing separating them is when it was last heard.
// Hence `heardRecently`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Comments deliberately describe this mechanism in prose, including the
/// prefixes, so a naive search matches the explanation as well as the code.
String _stripComments(String src) {
  final noBlocks = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlocks
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  final file = File('lib/views/hops_app.dart');
  late String code;

  setUpAll(() {
    expect(file.existsSync(), isTrue,
        reason: 'hops_app.dart not found — run tests from client/');
    code = _stripComments(file.readAsStringSync());
  });

  test('the freshness window exists and is longer than any transient send',
      () {
    final match = RegExp(
      r'_kHandshakeAdFreshness\s*=\s*Duration\(seconds:\s*(\d+)\)',
    ).firstMatch(code);
    expect(match, isNotNull,
        reason: '_kHandshakeAdFreshness is gone. Without it the handshake '
            'branches cannot tell a live advertisement from a stale '
            'scan-list entry.');

    final seconds = int.parse(match!.group(1)!);
    // The longest a sender holds a one-shot handshake advertisement is the
    // 10s of sendWatchRequest. The window must comfortably exceed that, or a
    // genuinely live handshake gets rejected as stale.
    expect(seconds, greaterThanOrEqualTo(15),
        reason: 'A window this short can reject a live handshake: '
            'sendWatchRequest alone advertises for 10 seconds.');
    // And it must stay far below the minutes-to-hours staleness it exists to
    // reject, or it stops doing anything.
    expect(seconds, lessThanOrEqualTo(120),
        reason: 'A window this long re-admits the stale advertisements this '
            'guard exists to reject.');
  });

  test('it is computed from the scan result timestamp, not wall clock alone',
      () {
    expect(
      RegExp(r'heardRecently\s*=\s*\n?\s*DateTime\.now\(\)\.difference\('
              r'r\.timeStamp\)')
          .hasMatch(code.replaceAll(RegExp(r'[ \t]+'), ' ')),
      isTrue,
      reason: 'heardRecently must be derived from the ScanResult\'s own '
          'timeStamp. Anything else cannot distinguish a re-delivered '
          'stale entry from a live one, because the name is identical.',
    );
  });

  group('every one-shot handshake branch is gated on freshness', () {
    // Deliberately NOT including HPS: (the idle beacon, which is supposed to
    // be read whenever heard), the chunked prefixes (CM:/CA:/DM:/LNF:, which
    // carry their own message ids and reassembly state), or EMG:/ADM:, which
    // must be acted on whenever heard and have their own dedup — an emergency
    // is the one thing that should never be dropped for being a few seconds
    // stale.
    for (final prefix in ['FR:', 'FA:', 'WR:', 'WA:', 'WX:']) {
      test(prefix, () {
        final branch = RegExp(
          'name\\.startsWith\\("${RegExp.escape(prefix)}"\\)([^)]*)\\)',
        ).firstMatch(code);
        expect(branch, isNotNull,
            reason: 'No dispatch branch found for $prefix at all.');
        expect(branch!.group(1), contains('heardRecently'),
            reason: '$prefix is dispatched without checking heardRecently, '
                'so a stale scan-list entry can re-trigger it. See this '
                'file\'s header.');
      });
    }
  });

  test('a watch request from someone already being watched is ignored', () {
    // The guard that was missing. sendWatchRequest() already refuses the
    // mirror case ("Already watching X"), so the receive side refusing it too
    // is the same rule applied at both ends.
    final guard = RegExp(
      r'!_recentWatchSenders\.contains\(sender\)[\s\S]{0,400}?'
      r'!_watchingBuddies\.contains\(sender\)',
    );
    expect(guard.hasMatch(code), isTrue,
        reason: 'The WR: guard no longer checks _watchingBuddies. Any '
            're-delivery during an established watch will raise a second '
            'request for a watch that is already running.');
  });

  test('learning of a cancel over the radio starts a cooldown', () {
    final body = RegExp(
      r'void _applyWatchCancelled\(String other\)\s*\{([\s\S]*?)\n  \}',
    ).firstMatch(code);
    expect(body, isNotNull, reason: '_applyWatchCancelled not found.');
    expect(body!.group(1), contains('_addRecentWatchSender(other)'),
        reason: 'Both sides that end a watch locally add a cooldown; the side '
            'that learns about it over the radio must too. Removing this '
            'person from _watchingBuddies drops one of the guards that was '
            'suppressing their old request, so without a cooldown a cancel '
            'can immediately raise a fresh request.');
  });

  test('clearing watch state clears BOTH halves of the pair', () {
    final body = RegExp(
      r'void clearAllWatchState\(\)\s*\{([\s\S]*?)\n  \}',
    ).firstMatch(code);
    expect(body, isNotNull, reason: 'clearAllWatchState not found.');
    final src = body!.group(1)!;
    expect(src, contains('_watchingBuddies.clear()'));
    expect(src, contains('_watchedBy.clear()'),
        reason: 'Only half the pair is cleared. _saveWatchState() persists '
            'both lists, so the surviving half is written straight back, and '
            'the signal-strength view stays on screen after a clear that was '
            'meant to remove it.');
  });

  test('the reminded-task-stage set is persisted, not just in memory', () {
    // The fire condition is "threshold passed and task still incomplete",
    // which stays true forever once the deadline goes by. Held only in
    // memory, every launch re-fired every passed threshold.
    expect(code, contains('_remindedTaskStagesPrefsKey'),
        reason: 'Task reminder dedup is no longer persisted. Every app '
            'launch will re-fire every threshold that has already passed.');
    final fire = RegExp(
      r'_remindedTaskStages\.add\(key\);\s*\n\s*_saveRemindedTaskStages\(\);',
    );
    expect(fire.hasMatch(code), isTrue,
        reason: 'A fired reminder stage must be written to disk as it fires, '
            'or a restart before the next write loses it and re-notifies.');
    expect(
      RegExp(r'await _loadRemindedTaskStages\(\);[\s\S]{0,200}?Timer\.periodic')
          .hasMatch(code),
      isTrue,
      reason: 'The persisted set must be loaded BEFORE the sweep timer '
          'starts, or the first sweep races the load and runs against an '
          'empty set — reintroducing the duplicate notifications.',
    );
  });
}
