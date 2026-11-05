// Turning a failed admin RPC into a message that says what actually went
// wrong, rather than blaming the network for everything.
//
// Lived in admin_moderation_tab.dart, which meant only the moderation
// actions benefited. Every other admin screen reported "check your
// connection" for every failure — including the Dashboard, where it cost
// real time: a server-side error reported as a connectivity problem sent
// someone looking at their wifi while the actual cause was an RPC
// rejecting the call.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns a failed admin RPC into something that actually says what went
/// wrong. Every moderation action used to report the same
/// "Failed — check your connection", which was actively misleading: the
/// most common real cause has nothing to do with connectivity. The RPCs
/// raise named exceptions (see 0008/0010 migrations) precisely so the
/// client can tell these apart.
String describeModerationError(Object e) {
  if (e is PostgrestException) {
    final msg = e.message;
    if (msg.contains('user_not_found')) {
      return "No account by that name exists. If the message shows a sender like "
          "\"ab12?\", that sender couldn't be matched to a real account — the "
          "reporting device hadn't synced the user directory when it filed the report.";
    }
    if (msg.contains('no_attributable_sender')) {
      return "This report has no sender attached (Vibe Check tags are anonymous), so there's nobody to warn.";
    }
    if (msg.contains('report_not_open')) {
      return "This report was already resolved — refresh to update the list.";
    }
    if (msg.contains('report_not_found')) {
      return "This report no longer exists — refresh to update the list.";
    }
    if (msg.contains('not_authorized')) {
      return "Your admin session isn't valid anymore. Sign out and back in.";
    }
    if (msg.contains('cannot_delete_admin')) {
      return "You can't delete an admin account — demote it first.";
    }
    // A missing function surfaces as PGRST202 — almost always means a
    // migration hasn't been applied to this Supabase project yet, which
    // is worth saying outright rather than blaming the network.
    if (e.code == 'PGRST202' || msg.contains('does not exist')) {
      return "This action isn't available on the server yet — the latest database migration hasn't been applied.";
    }
    return "Server rejected the action: $msg";
  }
  return "Couldn't reach the server — check your connection.";
}

/// Describes a failed admin *load* (a screen that could not fetch), naming
/// [fallbackSubject] when the cause really is connectivity.
///
/// Separate from [describeModerationError] only in its wording: a failed
/// action and a failed load want different sentences, but the diagnosis is
/// identical, so the diagnosis is shared.
///
/// Always debugPrints the raw error. The whole reason "Couldn't load stats
/// — check your connection" survived so long is that the real exception
/// was discarded at the catch site, so there was nothing in logcat to go
/// on either. An admin reading the screen gets the friendly line; whoever
/// is holding a USB cable gets the truth.
String describeAdminError(Object e, {required String fallbackSubject}) {
  debugPrint('Admin load failed ($fallbackSubject): $e');
  if (e is PostgrestException) {
    // A missing function is PGRST202 and almost always means a migration
    // has not been applied to this Supabase project. Saying so outright
    // is the difference between a five-minute fix and an afternoon.
    if (e.code == 'PGRST202' || e.message.contains('does not exist')) {
      return "The server is missing a function this screen needs — the "
          "latest database migration hasn't been applied. Run "
          "supabase/check-applied-migrations.sql to see which.";
    }
    if (e.message.contains('not_authorized')) {
      return "Your admin session isn't valid anymore. Sign out and back in.";
    }
    if (e.code == '42501') {
      return "The server refused this request: your account isn't an admin, "
          "or its session has expired. Sign out and back in.";
    }
    return "The server rejected the request: ${e.message}"
        "${e.code != null ? ' (${e.code})' : ''}";
  }
  if (e is AuthException) {
    return "Your admin session isn't valid anymore. Sign out and back in.";
  }
  return "Couldn't reach the server to load $fallbackSubject — check your "
      "connection. ($e)";
}
