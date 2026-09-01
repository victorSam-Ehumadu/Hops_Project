// Widget tests for the sign-up strength meter
// (lib/widgets/password_strength_bar.dart).
//
// Replaces the generated counter-app smoke test that shipped with the
// project scaffold, which referenced a `MyApp` widget this app has never
// had and so failed to compile — taking the whole `flutter test` run down
// with it.
//
// PasswordStrengthBar is a good widget-level target because it is shared
// between two screens and is purely presentational: it renders whatever
// scorePasswordStrength() returns, with no plugins, no network and no
// platform channels behind it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client/widgets/password_strength_bar.dart';

/// Pumps the bar inside the minimum shell it needs — it reads the ambient
/// ColorScheme for its track colour.
Future<void> pumpBar(WidgetTester tester, String password) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PasswordStrengthBar(password: password),
    ),
  ));
}

void main() {
  testWidgets('renders nothing before the user types', (tester) async {
    await pumpBar(tester, '');

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Password strength'), findsNothing);
  });

  testWidgets('appears as soon as there is a password', (tester) async {
    await pumpBar(tester, 'a');

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('Password strength'), findsOneWidget);
  });

  testWidgets('labels a weak password', (tester) async {
    await pumpBar(tester, 'abc');

    expect(find.text('Password strength: Very weak'), findsOneWidget);
  });

  testWidgets('labels a common password as very weak however it is composed',
      (tester) async {
    // 'password1' satisfies several complexity checks but is blocklisted.
    await pumpBar(tester, 'password1');

    expect(find.text('Password strength: Very weak'), findsOneWidget);
  });

  testWidgets('labels a password meeting every rule as strong', (tester) async {
    await pumpBar(tester, 'Ab1!aaaa');

    expect(find.text('Password strength: Strong'), findsOneWidget);
  });

  testWidgets('rewards extra length beyond the minimum', (tester) async {
    await pumpBar(tester, 'Ab1!aaaaaaaa');

    expect(find.text('Password strength: Very strong'), findsOneWidget);
  });

  testWidgets('fills the bar in proportion to the score', (tester) async {
    await pumpBar(tester, 'Ab1!aaaaaaaa');
    await tester.pumpAndSettle();

    final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(indicator.value, 1.0);
  });

  testWidgets('animates rather than jumping to the new value', (tester) async {
    await pumpBar(tester, 'Ab1!aaaaaaaa');

    // Mid-flight: partway through the 250ms tween, not yet at the target.
    await tester.pump(const Duration(milliseconds: 100));
    final midFlight = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(midFlight.value, greaterThan(0.0));
    expect(midFlight.value, lessThan(1.0));

    await tester.pumpAndSettle();
  });

  testWidgets('updates as the user keeps typing', (tester) async {
    await pumpBar(tester, 'abc');
    await tester.pumpAndSettle();
    expect(find.text('Password strength: Very weak'), findsOneWidget);

    await pumpBar(tester, 'Ab1!aaaaaaaa');
    await tester.pumpAndSettle();

    expect(find.text('Password strength: Very weak'), findsNothing);
    expect(find.text('Password strength: Very strong'), findsOneWidget);
  });

  testWidgets('disappears again if the field is cleared', (tester) async {
    await pumpBar(tester, 'Ab1!aaaa');
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await pumpBar(tester, '');
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
