// Reproduction harness for the red screen reported on the Home-screen
// Emergency Flare button:
//
//   'package:flutter/src/widgets/framework.dart': Failed assertion:
//   line 6268 pos 12: '_dependents.isEmpty': is not true
//
// That assert lives in InheritedElement.debugDeactivated(), so it only ever
// fires in a debug build — which is also why a widget test can see it at all
// and the release APK cannot. It means an InheritedWidget was deactivated
// while widgets still depended on it.
//
// The first suspect was Tooltip: its default triggerMode on touch is
// longPress, so a Tooltip wrapped around a long-press control bound the same
// gesture twice. That is fixed (triggerMode: manual, which RawTooltip
// handles with a bare `break`, registering no recognizer). The crash was
// still reported afterwards, so this exercises the gesture directly to find
// out what else is in play.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/views/radar_screen.dart';

void main() {
  setUp(() {
    // RadarScreen reads prefs in initState (avatar path, cosmetics).
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Builds RadarScreen the way HopsApp does: as the body of a Scaffold
  /// under a MaterialApp, so ScaffoldMessenger and the root Navigator are
  /// both present. The flare hint uses the first and the confirm dialog
  /// the second.
  Widget harness({
    required VoidCallback onFlare,
    required VoidCallback onCancel,
    bool active = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: RadarScreen(
          radarStream: const Stream.empty(),
          onSendFriendRequest: (_) async {},
          pendingRequests: const [],
          onAcceptRequest: (_) {},
          onDeclineRequest: (_) {},
          friendUsernames: const {},
          onEmergencyFlare: onFlare,
          onCancelEmergencyFlare: onCancel,
          isFlareActive: active,
        ),
      ),
    );
  }

  Finder flareButton() => find.byTooltip('Hold to raise an Emergency Flare');

  testWidgets('the flare button is present and is not a tap target', (t) async {
    var flares = 0;
    await t.pumpWidget(harness(onFlare: () => flares++, onCancel: () {}));
    await t.pump(const Duration(milliseconds: 100));

    expect(flareButton(), findsOneWidget,
        reason: 'The Home app-bar flare button is gone.');

    await t.tap(flareButton());
    await t.pump();
    expect(flares, 0,
        reason: 'A tap must never raise a flare — it only shows the hint.');
    expect(find.textContaining('Hold the button'), findsOneWidget,
        reason: 'A tap must say which gesture is needed rather than doing '
            'nothing, or the control reads as broken.');
    expect(t.takeException(), isNull);
  });

  testWidgets('a long press raises exactly one flare and throws nothing',
      (t) async {
    var flares = 0;
    await t.pumpWidget(harness(onFlare: () => flares++, onCancel: () {}));
    await t.pump(const Duration(milliseconds: 100));

    await t.longPress(flareButton());
    // Settle past the tooltip's own timers and any snackbar animation, which
    // is the window the original double-binding blew up in.
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 4));

    expect(flares, 1,
        reason: 'A hold must invoke the flare callback exactly once. Two '
            'would mean something is still double-binding the gesture.');
    expect(t.takeException(), isNull,
        reason: 'A hold must not throw. This is the assertion the red '
            'screen reported.');
  });

  testWidgets('while active, a long press stands down instead of raising',
      (t) async {
    var flares = 0;
    var cancels = 0;
    await t.pumpWidget(harness(
      onFlare: () => flares++,
      onCancel: () => cancels++,
      active: true,
    ));
    await t.pump(const Duration(milliseconds: 100));

    final active = find.byTooltip('Hold to stand down the emergency flare');
    expect(active, findsOneWidget,
        reason: 'While a flare is up the button must present as the '
            'stand-down.');

    await t.longPress(active);
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 4));

    expect(cancels, 1);
    expect(flares, 0,
        reason: 'Holding an active flare button must not raise a second one.');
    expect(t.takeException(), isNull);
  });

  testWidgets('holding repeatedly does not throw on teardown', (t) async {
    // The reported crash also appeared on the dialog's Cancel, i.e. on
    // teardown rather than on the gesture. Pumping the widget away after a
    // hold is the closest a unit test gets to that.
    var flares = 0;
    await t.pumpWidget(harness(onFlare: () => flares++, onCancel: () {}));
    await t.pump(const Duration(milliseconds: 100));

    for (var i = 0; i < 3; i++) {
      await t.longPress(flareButton());
      await t.pump(const Duration(milliseconds: 600));
    }
    expect(flares, 3);

    // Replace the whole tree — this deactivates every element, which is
    // when InheritedElement.debugDeactivated() runs its assert.
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await t.pump(const Duration(seconds: 1));

    expect(t.takeException(), isNull,
        reason: 'Tearing the screen down after holding the button must not '
            'trip the _dependents.isEmpty assertion.');
  });
}
