// Moderation standing for the signed-in account: in good standing,
// suspended until a date, or banned.
//
// WHY THIS EXISTS AS ITS OWN SERVICE
//
// Suspending or banning someone used to have almost no effect on a device
// that was already signed in. The only enforcement was HopsApp's
// 30-second get_my_status poll, and that had three holes:
//
//   1. It needs the network. Hops is offline-first — every peer feature
//      works over Bluetooth with no server involved — so a device can run
//      for days without a successful poll. The poll's catch-all swallowed
//      the failure and the moderated user carried on using the app.
//   2. Nothing was written down. The verdict lived in a local variable, so
//      force-closing the app discarded it.
//   3. Nothing checked at launch. main.dart routed into HopsApp purely on
//      `saved_hops_token != null` (no token validation at startup — see
//      CLAUDE.md), so a restart put the user straight back in and they
//      stayed in until a poll happened to succeed again.
//
// Server-side, 0020 closed the matching hole in the two sign-in functions
// (a suspended account could sign out and back in freely, because
// suspended_until arrived in 0015 and only get_my_status was taught about
// it). This class is the device-side half: it persists the verdict so it
// survives a restart and an offline stretch, and it is what the launch
// path and the poll both consult.
//
// A SUSPENSION LIFTS ITSELF WITHOUT THE NETWORK
//
// Deliberate. The expiry date is known the moment we hear about the
// suspension, so once it passes the device can clear the block on its own
// — otherwise someone whose week-long suspension ended would stay locked
// out until they next had a connection, which is a punishment nobody
// imposed. A ban carries no expiry and cannot self-lift; an unban is only
// discoverable by asking the server, which is the correct asymmetry.
//
// A SUSPENSION DOES NOT WIPE LOCAL DATA
//
// Also deliberate, and the reason this does not simply reuse
// wipeLocalIdentityAndReturnToGatekeeper. That function deletes the sqlite
// database — every message, task and vibe record. For a permanent ban that
// is defensible. For a three-day timeout it is irreversible collateral
// damage well beyond what the moderator chose, so a suspension holds the
// session and blocks the UI instead of tearing the account down.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AccountStandingKind { ok, suspended, banned }

@immutable
class AccountStanding {
  final AccountStandingKind kind;

  /// Moderator-supplied reason, shown to the user. Null when none was given.
  final String? reason;

  /// When a suspension lapses. Always null for [AccountStandingKind.ok] and
  /// for a ban, which has no expiry.
  final DateTime? until;

  const AccountStanding({required this.kind, this.reason, this.until});

  static const AccountStanding ok = AccountStanding(kind: AccountStandingKind.ok);

  /// True when the app must not be usable. A suspension whose expiry has
  /// already passed is NOT blocking — see the header on self-lifting.
  bool get blocksUse {
    switch (kind) {
      case AccountStandingKind.ok:
        return false;
      case AccountStandingKind.banned:
        return true;
      case AccountStandingKind.suspended:
        final u = until;
        if (u == null) return true; // no expiry parsed — fail closed
        return DateTime.now().toUtc().isBefore(u);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AccountStanding &&
      other.kind == kind &&
      other.reason == reason &&
      other.until == until;

  @override
  int get hashCode => Object.hash(kind, reason, until);
}

class AccountStandingStore {
  AccountStandingStore._();
  static final AccountStandingStore instance = AccountStandingStore._();

  static const _kKind = 'account_standing_kind';
  static const _kReason = 'account_standing_reason';
  static const _kUntil = 'account_standing_until';

  /// Last known standing, for widgets that want to rebuild on a change
  /// without holding a Future.
  final ValueNotifier<AccountStanding> current =
      ValueNotifier<AccountStanding>(AccountStanding.ok);

  /// Reads the persisted verdict. Called on the launch path before HopsApp
  /// is built, so a restart cannot shake off a block.
  Future<AccountStanding> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKind);
    if (raw == null) {
      current.value = AccountStanding.ok;
      return AccountStanding.ok;
    }
    final kind = AccountStandingKind.values.firstWhere(
      (k) => k.name == raw,
      orElse: () => AccountStandingKind.ok,
    );
    final untilRaw = prefs.getString(_kUntil);
    final standing = AccountStanding(
      kind: kind,
      reason: prefs.getString(_kReason),
      until: untilRaw == null ? null : DateTime.tryParse(untilRaw),
    );

    // A lapsed suspension clears itself here rather than lingering as a
    // stale record that every later load has to re-evaluate.
    if (standing.kind == AccountStandingKind.suspended && !standing.blocksUse) {
      await clear();
      return AccountStanding.ok;
    }

    current.value = standing;
    return standing;
  }

  Future<void> record(AccountStanding standing) async {
    final prefs = await SharedPreferences.getInstance();
    if (standing.kind == AccountStandingKind.ok) {
      await clear();
      return;
    }
    await prefs.setString(_kKind, standing.kind.name);
    if (standing.reason == null) {
      await prefs.remove(_kReason);
    } else {
      await prefs.setString(_kReason, standing.reason!);
    }
    if (standing.until == null) {
      await prefs.remove(_kUntil);
    } else {
      await prefs.setString(_kUntil, standing.until!.toUtc().toIso8601String());
    }
    current.value = standing;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKind);
    await prefs.remove(_kReason);
    await prefs.remove(_kUntil);
    current.value = AccountStanding.ok;
  }

  /// Asks the server for the current standing and persists the answer.
  ///
  /// Returns null when the question could not be asked — offline, Supabase
  /// unreachable, anything that is not a verdict. A null result must never
  /// be treated as "in good standing": the persisted verdict stands, which
  /// is the whole point of persisting it.
  Future<AccountStanding?> refresh(String token) async {
    try {
      await Supabase.instance.client
          .rpc('get_my_status', params: {'p_hops_token': token}).maybeSingle();
      // No exception raised — the account is in good standing. An expired
      // or unknown token returns an empty result rather than raising, and
      // that is not a moderation verdict, so it clears any stale block
      // too.
      await clear();
      return AccountStanding.ok;
    } on PostgrestException catch (e) {
      final standing = classify(e);
      if (standing == null) return null; // some other Postgrest failure
      await record(standing);
      return standing;
    } catch (_) {
      return null;
    }
  }

  /// Classifies a Postgrest error as a moderation verdict, or null if it is
  /// not one.
  ///
  /// Matches across message AND details rather than just `message`. The
  /// two server paths raise with different SQLSTATEs for the same
  /// condition — 28000 from the sign-in functions, 42501 from
  /// get_my_status — and PostgREST surfaces the raised text in `message`
  /// while the date and reason ride in `details`. Checking both is what
  /// stops a formatting change on either side from silently turning
  /// enforcement off, which is the failure mode that made this bug so hard
  /// to see: the catch-all simply did nothing.
  static AccountStanding? classify(PostgrestException e) {
    final haystack = '${e.message} ${e.details ?? ''} ${e.hint ?? ''}';
    if (haystack.contains('account_banned')) {
      return AccountStanding(
        kind: AccountStandingKind.banned,
        reason: _reasonFrom(e.details),
      );
    }
    if (haystack.contains('account_suspended')) {
      final detail = e.details is String ? e.details as String : null;
      return AccountStanding(
        kind: AccountStandingKind.suspended,
        reason: _reasonFrom(e.details),
        until: _untilFrom(detail),
      );
    }
    return null;
  }

  /// DETAIL is formatted by the server as `YYYY-MM-DD — reason`, or just
  /// `YYYY-MM-DD` when no reason was given (and for a ban, as the bare
  /// reason). Split on the em dash the server uses.
  static String? _reasonFrom(Object? details) {
    if (details is! String) return null;
    final text = details.trim();
    if (text.isEmpty) return null;
    final dash = text.indexOf('—');
    if (dash == -1) {
      // No separator: either a bare ban reason, or a bare suspension date.
      return _looksLikeDate(text) ? null : text;
    }
    final reason = text.substring(dash + 1).trim();
    return reason.isEmpty ? null : reason;
  }

  static DateTime? _untilFrom(String? details) {
    if (details == null) return null;
    final head = details.split('—').first.trim();
    if (!_looksLikeDate(head)) return null;
    // Parsed as a UTC date; the server formats suspended_until, which it
    // stores and compares in UTC.
    return DateTime.tryParse('${head}T00:00:00Z');
  }

  static bool _looksLikeDate(String s) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s);

  /// Test seam — mirrors AccessibilityPrefs.resetForTest.
  @visibleForTesting
  void resetForTest() => current.value = AccountStanding.ok;
}
