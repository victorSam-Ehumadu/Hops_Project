// test/views/flare_radio_invariant_test.dart
//
// A source-level guard, not a behavioural test.
//
// hops_app.dart owns the single BLE advertisement slot. Every transient
// advertisement (friend/watch request, vibe or study tag, Lost & Found, a
// DM chunk cycle) schedules a timer to hand that slot back to the idle
// "HPS:" presence beacon once its window closes. Reverting unconditionally
// is a safety bug: if such a timer fires while our OWN Emergency Flare is
// on the air, it takes the flare off the radio — and nothing puts it back
// once the signature cycle has finished, so the UI keeps showing an active
// flare with a running countdown while the device transmits nothing.
//
// The fix is _releaseRadioToPresenceBeacon(), which owns the
// `_isFlareActive || _ownFlareHoldsRadio` check. The bug recurs whenever
// someone adds a feature and writes the revert by hand instead, so this
// test asserts the *shape* of the source rather than waiting for two
// physical devices to catch it — which is the only other way it surfaces
// (nothing BLE is reachable from a unit test; see CLAUDE.md).
//
// If this fails, you almost certainly want _releaseRadioToPresenceBeacon()
// rather than a hand-rolled revert.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Resolved relative to the package root, which is where `flutter test`
/// runs from.
const String _hopsAppPath = 'lib/views/hops_app.dart';

/// The helper is allowed to do the thing it exists to do.
const String _helperName = '_releaseRadioToPresenceBeacon';

void main() {
  late List<String> lines;
  late String source;

  setUpAll(() {
    final file = File(_hopsAppPath);
    expect(file.existsSync(), isTrue,
        reason: 'Expected to find $_hopsAppPath relative to the package root. '
            'If the file moved, update this test rather than deleting it.');
    source = file.readAsStringSync();
    lines = source.split('\n');
  });

  group('the advertisement slot is only handed back through the helper', () {
    test('the helper exists and checks both flare flags', () {
      expect(source, contains('Future<bool> $_helperName()'),
          reason: 'The helper that owns this invariant is gone. Every revert '
              'path now has to re-implement the check by hand, which is the '
              'bug this test exists to prevent.');

      // Find the helper body and assert the guard is still inside it.
      final start = source.indexOf('Future<bool> $_helperName()');
      final body = source.substring(start, start + 400);

      expect(body, contains('_isFlareActive'),
          reason: '$_helperName must refuse to revert while our own flare is '
              'live.');
      expect(body, contains('_ownFlareHoldsRadio'),
          reason: '$_helperName must ALSO check _ownFlareHoldsRadio, which is '
              'deliberately wider than _isFlareActive: it stays true across '
              'the 5s EMG_OFF: stand-down window, so a revert cannot replace '
              'the stand-down and strand phones still ringing on our behalf.');
    });

    test('no hand-rolled "stop advertising, then re-advertise the beacon"',
        () {
      // Walk the file and flag any place that calls stopAdvertising() and
      // then _advertisePresenceBeacon() within a couple of lines, outside
      // the helper itself. That pairing IS the bug.
      final helperLine =
          lines.indexWhere((l) => l.contains('Future<bool> $_helperName()'));
      expect(helperLine, isNot(-1));

      final offenders = <String>[];

      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('stopAdvertising()')) continue;

        // The helper's own body is the one sanctioned place.
        if (i > helperLine && i < helperLine + 8) continue;

        // Look ahead a short way for the matching re-advertise.
        final lookahead = (i + 4 < lines.length) ? i + 4 : lines.length - 1;
        for (var j = i + 1; j <= lookahead; j++) {
          if (lines[j].contains('_advertisePresenceBeacon()')) {
            offenders.add('  line ${i + 1}: ${lines[i].trim()}\n'
                '  line ${j + 1}: ${lines[j].trim()}');
            break;
          }
          // A transient advertisement in between means this stop belongs to
          // something else entirely — not a revert.
          if (lines[j].contains('_advertiseWithName(')) break;
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Found a revert that bypasses $_helperName:\n\n'
            '${offenders.join('\n\n')}\n\n'
            'Call $_helperName() instead. Reverting unconditionally takes '
            'our own Emergency Flare off the air when the timer happens to '
            'fire mid-flare, and the UI goes on claiming the flare is live.',
      );
    });

    test('guards that mention _isFlareActive also mention _ownFlareHoldsRadio',
        () {
      // Any condition narrow enough to check only _isFlareActive will let a
      // revert through during the stand-down window, when _isFlareActive is
      // already false but _ownFlareHoldsRadio is still true.
      final offenders = <String>[];

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!line.contains('_isFlareActive')) continue;
        // Assignments and setState calls are state changes, not guards.
        if (line.contains('_isFlareActive =') ||
            line.contains('_isFlareActive)') && line.contains('setState')) {
          continue;
        }
        if (!line.contains('!_isFlareActive') &&
            !line.contains('|| _isFlareActive')) {
          continue;
        }

        // Multi-line conditions are common here, so look at a small window.
        final from = (i - 3 < 0) ? 0 : i - 3;
        final to = (i + 4 < lines.length) ? i + 4 : lines.length;
        final window = lines.sublist(from, to).join('\n');

        // A guard that re-advertises the beacon must consider both flags.
        if (!window.contains('_advertisePresenceBeacon()')) continue;
        if (window.contains('_ownFlareHoldsRadio')) continue;

        offenders.add('  line ${i + 1}: ${line.trim()}');
      }

      expect(
        offenders,
        isEmpty,
        reason: 'These guards check _isFlareActive but not '
            '_ownFlareHoldsRadio before re-advertising the presence '
            'beacon:\n\n${offenders.join('\n')}\n\n'
            '_isFlareActive goes false the moment the flare is cancelled, '
            'while the EMG_OFF: stand-down is still broadcasting for '
            'another five seconds. Checking only _isFlareActive lets a '
            'revert replace that stand-down, leaving nearby phones ringing '
            'with no way to be told it is over.',
      );
    });
  });
}
