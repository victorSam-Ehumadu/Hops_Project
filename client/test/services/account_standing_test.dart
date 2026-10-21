// Moderation standing: classifying the server's error into a verdict, and
// deciding whether that verdict currently blocks the app.
//
// Worth testing closely because every failure in this area is silent. The
// original bug was a handler that matched the wrong string and therefore
// did nothing at all, which is indistinguishable from "the admin action
// didn't work" — and the only other way to exercise it is to ban a real
// account on a real device and watch.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:client/services/account_standing.dart';

/// The two shapes the server actually sends. get_my_status raises with
/// SQLSTATE 42501 and the sign-in functions with 28000, for the very same
/// two conditions — so nothing here may depend on the code.
PostgrestException _banned({String? detail, String code = '42501'}) =>
    PostgrestException(message: 'account_banned', code: code, details: detail);

PostgrestException _suspended({String? detail, String code = '42501'}) =>
    PostgrestException(
        message: 'account_suspended', code: code, details: detail);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountStandingStore.instance.resetForTest();
  });

  group('classify', () {
    test('returns null for an error that is not a moderation verdict', () {
      // The poll runs every 30 seconds and most of its failures are just
      // "offline". Treating one of those as a verdict would lock a user
      // out of an offline-first app for having no signal.
      expect(
        AccountStandingStore.classify(
            PostgrestException(message: 'relation does not exist')),
        isNull,
      );
    });

    test('recognises a ban from either SQLSTATE', () {
      for (final code in ['42501', '28000']) {
        final s = AccountStandingStore.classify(_banned(code: code));
        expect(s, isNotNull, reason: 'code $code should still classify');
        expect(s!.kind, AccountStandingKind.banned);
      }
    });

    test('recognises a suspension from either SQLSTATE', () {
      for (final code in ['42501', '28000']) {
        final s = AccountStandingStore.classify(_suspended(code: code));
        expect(s, isNotNull, reason: 'code $code should still classify');
        expect(s!.kind, AccountStandingKind.suspended);
      }
    });

    test('reads a ban reason out of details', () {
      final s = AccountStandingStore.classify(_banned(detail: 'Harassment'));
      expect(s!.reason, 'Harassment');
      expect(s.until, isNull, reason: 'a ban has no expiry');
    });

    test('splits a suspension date from its reason', () {
      final s =
          AccountStandingStore.classify(_suspended(detail: '2026-11-04 — Spam'));
      expect(s!.until, DateTime.utc(2026, 11, 4));
      expect(s.reason, 'Spam');
    });

    test('handles a suspension with a date and no reason', () {
      final s = AccountStandingStore.classify(_suspended(detail: '2026-11-04'));
      expect(s!.until, DateTime.utc(2026, 11, 4));
      expect(s.reason, isNull,
          reason: 'a bare date is not a reason — it must not be shown as one');
    });

    test('survives details being absent or a non-String', () {
      // `details` is typed dynamic. A blind cast here used to be able to
      // throw a TypeError from inside the handler whose whole job is to
      // stop the app ignoring a ban.
      expect(AccountStandingStore.classify(_banned(detail: null))!.kind,
          AccountStandingKind.banned);
      expect(
        AccountStandingStore.classify(PostgrestException(
                message: 'account_suspended', details: {'not': 'a string'}))!
            .kind,
        AccountStandingKind.suspended,
      );
    });

    test('still classifies when the marker arrives only in details', () {
      // Defence against the exact failure that hid this bug: matching on
      // one field and silently doing nothing when the text moves.
      final s = AccountStandingStore.classify(
          PostgrestException(message: 'unexpected', details: 'account_banned'));
      expect(s?.kind, AccountStandingKind.banned);
    });
  });

  group('blocksUse', () {
    test('good standing never blocks', () {
      expect(AccountStanding.ok.blocksUse, isFalse);
    });

    test('a ban always blocks', () {
      expect(
        const AccountStanding(kind: AccountStandingKind.banned).blocksUse,
        isTrue,
      );
    });

    test('a suspension blocks while its expiry is in the future', () {
      final s = AccountStanding(
        kind: AccountStandingKind.suspended,
        until: DateTime.now().toUtc().add(const Duration(days: 2)),
      );
      expect(s.blocksUse, isTrue);
    });

    test('a lapsed suspension stops blocking without any server contact', () {
      // The point of storing the expiry. Someone whose week is up must not
      // stay locked out waiting for a connection to tell them so — that is
      // a punishment no moderator chose.
      final s = AccountStanding(
        kind: AccountStandingKind.suspended,
        until: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      );
      expect(s.blocksUse, isFalse);
    });

    test('a suspension with no parsed expiry fails closed', () {
      // If the date could not be read, blocking is the safe direction:
      // a re-check can always lift it, whereas guessing "not blocked"
      // silently discards the moderator's decision.
      expect(
        const AccountStanding(kind: AccountStandingKind.suspended).blocksUse,
        isTrue,
      );
    });
  });

  group('persistence', () {
    test('a recorded verdict survives being reloaded', () async {
      // This is what makes a restart re-apply the block instead of
      // shaking it off, which was the whole launch-path hole.
      final until = DateTime.now().toUtc().add(const Duration(days: 3));
      await AccountStandingStore.instance.record(AccountStanding(
        kind: AccountStandingKind.suspended,
        reason: 'Spam',
        until: until,
      ));

      final loaded = await AccountStandingStore.instance.load();
      expect(loaded.kind, AccountStandingKind.suspended);
      expect(loaded.reason, 'Spam');
      expect(loaded.blocksUse, isTrue);
      expect(loaded.until!.difference(until).inSeconds.abs(), lessThan(2));
    });

    test('a ban survives being reloaded', () async {
      await AccountStandingStore.instance.record(
        const AccountStanding(kind: AccountStandingKind.banned, reason: 'Abuse'),
      );
      final loaded = await AccountStandingStore.instance.load();
      expect(loaded.kind, AccountStandingKind.banned);
      expect(loaded.reason, 'Abuse');
      expect(loaded.blocksUse, isTrue);
    });

    test('loading a lapsed suspension clears it', () async {
      await AccountStandingStore.instance.record(AccountStanding(
        kind: AccountStandingKind.suspended,
        until: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      ));
      final loaded = await AccountStandingStore.instance.load();
      expect(loaded.kind, AccountStandingKind.ok);
      // And it is gone from storage, not merely ignored on the way out.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('account_standing_kind'), isNull);
    });

    test('recording good standing clears a stored block', () async {
      await AccountStandingStore.instance.record(
        const AccountStanding(kind: AccountStandingKind.banned),
      );
      await AccountStandingStore.instance.record(AccountStanding.ok);
      expect((await AccountStandingStore.instance.load()).kind,
          AccountStandingKind.ok);
    });

    test('nothing stored reads as good standing', () async {
      expect((await AccountStandingStore.instance.load()).kind,
          AccountStandingKind.ok);
    });
  });
}
