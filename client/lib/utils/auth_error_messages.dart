// Turns whatever came back from a Supabase call (a raw exception, or a
// PostgrestException carrying one of our RPCs' custom error codes) into
// something a non-technical person can actually act on. Shared by
// root_gatekeeper.dart (sign up/in), account_management_screen.dart
// (change password/email, delete account) and the forgot-password/email-
// verification screens, so the same underlying failure always reads the
// same way no matter which screen it surfaced on.
import 'package:supabase_flutter/supabase_flutter.dart';

String describeAuthException(Object e) {
  final text = e.toString();

  // account_banned carries its reason in the PostgrestException's `details`
  // (see ban_user/signin_hops_user*/get_my_status in
  // supabase/migrations/0008_admin_moderation.sql) — unlike every other
  // branch here, it's safe to be this specific: this is always the account
  // owner's own sign-in/session, not a third party probing whether some
  // other username exists, so naming the reason leaks nothing.
  if (text.contains('account_banned')) {
    final reason = e is PostgrestException && e.details != null && (e.details as String).isNotEmpty
        ? e.details as String
        : null;
    return reason == null
        ? "This account has been suspended by a Hops admin."
        : "This account has been suspended by a Hops admin: $reason";
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
