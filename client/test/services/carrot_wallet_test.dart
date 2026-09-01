// Unit tests for the in-app currency (lib/services/carrot_wallet.dart).
//
// Carrots are earned from mini-games and spent on cosmetics only. The rule
// that matters for the report's economy discussion is that a repeatable
// game mode must never pay out — an endlessly replayable puzzle would let
// anyone mint an unbounded balance. These tests cover the wallet's own
// contract; the no-payout rule lives at the call sites.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/carrot_wallet.dart';

/// Indirection so the flag reads as a runtime value at its call site.
bool unlimitedCarrotsEnabled() => CarrotWallet.debugUnlimitedCarrots;

void main() {
  late CarrotWallet wallet;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    wallet = CarrotWallet.instance;
    wallet.resetForTest();
  });

  group('balance', () {
    test('starts empty on a fresh install', () async {
      await wallet.load();
      expect(wallet.balance.value, 0);
      expect(wallet.owned.value, isEmpty);
    });

    test('credits a game reward', () async {
      await wallet.earn(30);
      expect(wallet.balance.value, 30);
    });

    test('accumulates across several rewards', () async {
      await wallet.earn(30);
      await wallet.earn(12);
      expect(wallet.balance.value, 42);
    });

    test('ignores a zero or negative reward', () async {
      await wallet.earn(25);
      await wallet.earn(0);
      await wallet.earn(-100);
      expect(wallet.balance.value, 25);
    });

    test('survives a restart', () async {
      await wallet.earn(75);

      // Same stored preferences, fresh in-memory state.
      wallet.resetForTest();
      await wallet.load();

      expect(wallet.balance.value, 75);
    });

    test('notifies listeners so the app bar updates', () async {
      await wallet.load();
      final seen = <int>[];
      void listener() => seen.add(wallet.balance.value);
      wallet.balance.addListener(listener);
      addTearDown(() => wallet.balance.removeListener(listener));

      await wallet.earn(5);
      await wallet.earn(5);

      expect(seen, [5, 10]);
    });
  });

  group('purchases', () {
    test('grants the item and records ownership', () async {
      await wallet.earn(500);

      expect(await wallet.purchase('midnight_theme', 100), isTrue);
      expect(wallet.owns('midnight_theme'), isTrue);
    });

    test('refuses to sell the same item twice', () async {
      await wallet.earn(500);
      await wallet.purchase('midnight_theme', 100);

      // The Buy button disables itself too — this is the safety net.
      expect(await wallet.purchase('midnight_theme', 100), isFalse);
    });

    test('does not double-charge for an item already owned', () async {
      await wallet.earn(500);
      await wallet.purchase('midnight_theme', 100);
      final afterFirst = wallet.balance.value;

      await wallet.purchase('midnight_theme', 100);

      expect(wallet.balance.value, afterFirst);
    });

    test('keeps unrelated items separate', () async {
      await wallet.earn(500);
      await wallet.purchase('midnight_theme', 100);

      expect(wallet.owns('midnight_theme'), isTrue);
      expect(wallet.owns('sunrise_theme'), isFalse);
    });

    test('owned items survive a restart', () async {
      await wallet.earn(500);
      await wallet.purchase('midnight_theme', 100);

      wallet.resetForTest();
      await wallet.load();

      expect(wallet.owns('midnight_theme'), isTrue);
    });
  });

  group('debug unlimited carrots', () {
    // Read through a function so the branches below are a runtime decision.
    // Comparing against the constant directly would make one branch dead
    // code, and the tests would stop compiling the moment the flag is
    // flipped for a real launch — the one time they most need to run.
    final unlimited = unlimitedCarrotsEnabled();

    test('the flag governs whether the balance actually gates a purchase', () async {
      await wallet.earn(10);
      final purchased = await wallet.purchase('expensive_theme', 9999);

      if (unlimited) {
        // Current build: the economy is bypassed for demo/QA, so an item
        // far beyond the balance still unlocks and nothing is deducted.
        // Flipping the flag off for a real launch flips this expectation.
        expect(purchased, isTrue);
        expect(wallet.balance.value, 10);
        expect(wallet.owns('expensive_theme'), isTrue);
      } else {
        expect(purchased, isFalse);
        expect(wallet.balance.value, 10);
        expect(wallet.owns('expensive_theme'), isFalse);
      }
    });

    test('an affordable purchase behaves the same either way', () async {
      await wallet.earn(500);

      expect(await wallet.purchase('midnight_theme', 100), isTrue);
      expect(wallet.owns('midnight_theme'), isTrue);
      expect(wallet.balance.value, unlimited ? 500 : 400);
    });
  });
}
