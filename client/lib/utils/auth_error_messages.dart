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

/// Turns the `error` code an email Edge Function returns alongside
/// `{ok: false}` into something a user can act on.
///
/// These three states deserve different wording because they call for
/// different actions, and lumping them together already cost real
/// debugging time: SendGrid's quota exhaustion surfaced as "the mail
/// server rejected it", which points at the sender, so the DNS and the
/// From address were audited at length while both were perfectly correct.
///
/// See supabase/functions/_shared/send_email.ts for where each code comes
/// from. [skipHint] appends the "you can skip this" sentence, which is
/// true for email verification but not for a password reset.
String describeEmailSendFailure(Object? errorCode, {String skipHint = ''}) {
  final code = errorCode is String ? errorCode : '';
  switch (code) {
    case 'quota_exceeded':
      // Resolves by itself, so say so — otherwise this reads as broken.
      return "The daily email limit has been reached, so the code couldn't "
          "be sent. Try again later.$skipHint";
    // The session codes reach here when the function answered 200 with
    // {ok:false}; the throwing path is handled in describeAuthException.
    case 'missing_session':
      return "This device isn't signed in, so the code couldn't be sent.";
    case 'unknown_session':
      return "This device's sign-in is no longer recognised — sign in again.";
    case 'no_email_on_file':
      return "There's no email address on this account, so a code can't be "
          "sent.$skipHint";
    case 'sender_not_verified':
    case 'email_not_configured':
      // A real setup fault, and not one the user can fix.
      return "Email isn't set up on the server yet, so the code couldn't be "
          "sent. This is a setup issue, not something you did wrong."
          "$skipHint";
    default:
      return "Couldn't send the code just now.$skipHint";
  }
}

/// WHY "wrong password" AND "no such account" STAY COLLAPSED
///
/// Several branches below answer both with the same sentence. That is
/// deliberate and should not be "improved" into two messages, however much
/// more helpful two would feel.
///
/// Distinguishing them turns the sign-in form into an account-existence
/// oracle: anyone can type an email and learn from the wording whether
/// that person has a Hops account. On a campus safety app that is a real
/// disclosure — it reveals who is using it — and it is cheap to automate.
///
/// The server is built the same way on purpose: signin_hops_user_by_email
/// returns an identical empty result for "no such email" and "wrong
/// password" (0008/0009), and get_password_salt_by_email returns a
/// real-looking fake salt for an unknown address (0018/0023) so even the
/// pre-authentication lookup cannot be used to probe. Splitting the client
/// message would throw that away at the last step.
///
/// Everything that is NOT about credentials is made as specific as
/// possible, which is where the real complaint lay: a wrong email used to
/// report a server fault.
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
  // Ordered BEFORE invalid_session deliberately: 'missing_session' and
  // 'unknown_session' both contain "session", and an earlier broad match
  // would swallow them. send-verification-email used to answer
  // "invalid_session" for all three, so every one of these read as "your
  // session has expired" — wrong for two of them, and the advice it gave
  // ("sign in again") fixed neither.
  if (text.contains('missing_session')) {
    return "This device isn't signed in, so that couldn't be sent. Sign in "
        "and try again.";
  }
  if (text.contains('unknown_session')) {
    return "This device's sign-in is no longer recognised — sign in again.";
  }
  if (text.contains('no_email_on_file')) {
    return "There's no email address on this account, so a code can't be "
        "sent. Add one in Account Management.";
  }
  if (text.contains('invalid_session')) {
    return "Your session has expired — please sign in again.";
  }
  if (text.contains('function') && text.contains('does not exist')) {
    return "Hops' server isn't set up yet — this is a setup issue, not something you did wrong.";
  }

  // ── Cases that used to fall through to the generic message ──────────
  //
  // "Something went wrong on our end" is the right thing to say about an
  // actual server fault and the wrong thing to say about anything the user
  // can fix. It tells them to retry something that will keep failing, and
  // gives no hint that the problem is their input. Each branch below
  // existed as a real failure that reported itself that way.

  // A TypeError or cast failure from parsing an unexpected response shape.
  // fetchPasswordSaltForEmail used to throw exactly this when the salt
  // lookup returned null — on a wrong email, which is the single most
  // common sign-in mistake there is.
  if (text.contains('is not a subtype of type') ||
      text.contains('type \'Null\'')) {
    return "That email and password don't match any Hops account.";
  }
  if (text.contains('invalid_username')) {
    return "Usernames must be 3–20 characters, letters, numbers and "
        "underscores only.";
  }
  if (text.contains('invalid_email')) {
    return "That doesn't look like a valid email address.";
  }
  if (text.contains('invalid_credentials') ||
      text.contains('28000') ||
      text.contains('28P01')) {
    return "That email and password don't match any Hops account.";
  }
  if (text.contains('not_authorized') || text.contains('42501')) {
    return "You don't have permission to do that.";
  }
  if (text.contains('invalid_session')) {
    return "Your session has expired — please sign in again.";
  }
  if (text.contains('rate limit') ||
      text.contains('429') ||
      text.contains('too many')) {
    return "Too many attempts — wait a minute and try again.";
  }
  if (text.contains('ClientException') ||
      text.contains('Connection closed') ||
      text.contains('Connection reset') ||
      text.contains('HandshakeException')) {
    return "The connection dropped — check your signal and try again.";
  }

  // Fall back to a generic, still-non-technical message rather than
  // dumping a raw exception string — better to say less than to show
  // something like "PostgrestException(message: ..., code: 23505, ...)".
  return "Something went wrong on our end — please try again in a moment.";
}
