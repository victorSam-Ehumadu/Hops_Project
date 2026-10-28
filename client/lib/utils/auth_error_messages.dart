// Turns whatever came back from a Supabase call (a raw exception, or a
// PostgrestException carrying one of our RPCs' custom error codes) into
// something a non-technical person can actually act on. Shared by
// root_gatekeeper.dart (sign up/in), account_management_screen.dart
// (change password/email, delete account) and the forgot-password/email-
// verification screens, so the same underlying failure always reads the
// same way no matter which screen it surfaced on.
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/utils/password_policy.dart';

/// `details` is typed dynamic on PostgrestException and is not always a
/// String — a blind `as String` cast throws a TypeError from inside the
/// very handler that exists to produce a readable message.
String? _detailOf(Object e) {
  if (e is! PostgrestException) return null;
  final d = e.details;
  if (d is! String) return null;
  final trimmed = d.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String describeAuthException(Object e) {
  final text = e.toString();

  // Both moderation outcomes carry their detail in the
  // PostgrestException's `details` — see ban_user/suspend_user,
  // signin_hops_user*/get_my_status in 0008/0015/0020. Unlike every other
  // branch here it's safe to be this specific: this is always the account
  // owner's own sign-in/session, not a third party probing whether some
  // other username exists, so naming the reason leaks nothing.
  //
  // Ban and suspension are deliberately worded as the different things
  // they are. This used to describe a BAN as "suspended", which was both
  // wrong and actively misleading once real suspensions existed — a
  // permanent removal reading as a temporary one invites the user to wait
  // it out instead of appealing.
  if (text.contains('account_banned')) {
    final reason = _detailOf(e);
    return reason == null
        ? "This account has been banned by a Hops admin."
        : "This account has been banned by a Hops admin: $reason";
  }
  // Raised by get_my_status since 0015 and by both sign-in functions since
  // 0020. Before 0020 sign-in didn't check suspension at all, so this
  // string had nothing to match and a suspended user signing in fell
  // through to the generic "something went wrong" below — indistinguishable
  // from a server fault, which is how a working suspension looked like a
  // broken app.
  //
  // DETAIL is formatted `YYYY-MM-DD — reason`, or just the bare date when
  // no reason was recorded.
  if (text.contains('account_suspended')) {
    final detail = _detailOf(e);
    if (detail == null) {
      return "This account is temporarily suspended by a Hops admin.";
    }
    final parts = detail.split('—');
    final until = parts.first.trim();
    final reason = parts.length > 1 ? parts.sublist(1).join('—').trim() : '';
    final when = until.isEmpty ? "" : " until $until";
    return reason.isEmpty
        ? "This account is suspended$when."
        : "This account is suspended$when: $reason";
  }
  if (text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable')) {
    return "No internet connection — you'll need one for this step, but everything else in Hops still works offline.";
  }
  if (text.contains('TimeoutException')) {
    return "That took too long — check your connection and try again.";
  }
  if (text.contains('username_taken')) {
    return "That username is already taken — try another one.";
  }
  // Reserved for the built-in assistant — see
  // 0014_reserve_bot_usernames.sql. Worth its own message rather than
  // folding into "already taken": nobody holds it, so "try another one"
  // without saying why reads as the server being wrong.
  if (text.contains('username_reserved')) {
    return "That name is reserved for the built-in Hops assistant — please pick another.";
  }
  // Raised by signup_hops_user / change_hops_email since 0021. The client
  // checks this too (password_policy.dart's validateAccountEmail), so
  // reaching here means either an older build or a direct RPC call — the
  // server is the real gate, since signup is granted to `anon`.
  if (text.contains('email_domain_not_allowed')) {
    return "Use your Richfield student email (ending in "
        "$kInstitutionalEmailDomain) to create a Hops account.";
  }
  if (text.contains('email_taken')) {
    return "An account already exists with that email address.";
  }
  if (text.contains('invalid_otp') || text.contains('otp_expired')) {
    return "That code is incorrect or has expired — request a new one and try again.";
  }
  if (text.contains('invalid_session')) {
    return "Your session has expired — please sign in again.";
  }
  if (text.contains('function') && text.contains('does not exist')) {
    return "Hops' server isn't set up yet — this is a setup issue, not something you did wrong.";
  }

  // Fall back to a generic, still-non-technical message rather than
  // dumping a raw exception string — better to say less than to show
  // something like "PostgrestException(message: ..., code: 23505, ...)".
  return "Something went wrong on our end — please try again in a moment.";
}
