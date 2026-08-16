// lib/utils/report_content.dart
//
// Shared "Report" action for anything a student might flag for admin
// review — Community Chat messages and Vibe Check community reports today,
// any future reportable content type later without duplicating this sheet.
//
// Submits a snapshot (not a live reference) to content_reports via
// submit_report — see supabase/migrations/0008_admin_moderation.sql for
// why that matters here specifically: Community Chat messages and Vibe
// Check submissions are otherwise transient/device-local only (see
// community_chat.dart, vibe_check_page.dart, database_helper.dart), so
// this snapshot, taken at the moment of reporting, is the *only* copy of
// that content that ever reaches the server. Reporting something doesn't
// remove it from anyone else's device — the sheet says so explicitly so
// this doesn't read as "delete" to whoever's using it.
//
// Reports/warnings are deliberately Supabase-backed, not BLE-mesh-local —
// unlike almost everything else in this app, an admin needs to be able to
// review a report (and a warning needs to reach its target) whenever
// either device next has connectivity, regardless of whether the two
// phones are ever in Bluetooth range of each other. That means a report
// filed while genuinely offline can't go out immediately — see
// queueReport/flushPendingReports below for how that gap is closed instead
// of the report just being silently lost.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const Map<String, String> reportCategories = {
  'spam': 'Spam',
  'harassment': 'Harassment or bullying',
  'inappropriate': 'Inappropriate content',
  'other': 'Something else',
};

/// contentType must be one of content_reports' checked values:
/// 'chat_message', 'vibe_check', 'contact_profile'. targetUsername is
/// nullable — Vibe Check's crowd-density tags carry no sender at all, so
/// there's nothing to attribute a report to for that content type.
/// [contentCreatedAt] is when the reported thing was actually *sent*, which
/// can be far from when it's reported (scrolling back to report an old
/// message). Null when the caller genuinely doesn't know it.
Future<void> showReportContentSheet(
  BuildContext context, {
  required String contentType,
  String? targetUsername,
  required String snapshotText,
  DateTime? contentCreatedAt,
}) async {
  final colors = Theme.of(context).colorScheme;
  String? selectedCategory;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Report content',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: colors.primary),
            ),
            const SizedBox(height: 4),
            Text(
              "Sends a copy of this to Hops admins for review — it won't remove it from anyone else's device.",
              style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_off, size: 13, color: colors.onSurface.withValues(alpha: 0.45)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    "Reports need an internet connection. Offline, yours is saved on this "
                    "device and sent automatically once you're back online.",
                    style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.45)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...reportCategories.entries.map((entry) => RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(entry.value, style: const TextStyle(fontSize: 14)),
                  value: entry.key,
                  // ignore: deprecated_member_use
                  groupValue: selectedCategory,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setSheetState(() => selectedCategory = v),
                )),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: colors.primary.withValues(alpha: 0.3),
                ),
                onPressed: selectedCategory == null
                    ? null
                    : () async {
                        final category = selectedCategory!;
                        Navigator.of(sheetContext).pop();
                        final ok = await _submitReport(
                          contentType: contentType,
                          targetUsername: targetUsername,
                          snapshotText: snapshotText,
                          category: category,
                          contentCreatedAt: contentCreatedAt,
                        );
                        // Offline (or Supabase briefly unreachable) — queue
                        // it locally instead of just losing it. flushPendingReports
                        // retries automatically once there's a connection
                        // again (see hops_app.dart's periodic identity-sync
                        // poll, which calls it alongside its own check).
                        if (!ok) {
                          await queueReport(
                            contentType: contentType,
                            targetUsername: targetUsername,
                            snapshotText: snapshotText,
                            category: category,
                            contentCreatedAt: contentCreatedAt,
                          );
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok
                                ? "Reported. Thanks — an admin will review it."
                                : "You're offline — saved and will be sent automatically once you're back online."),
                          ));
                        }
                      },
                child: const Text('Submit report'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> _submitReport({
  required String contentType,
  String? targetUsername,
  required String snapshotText,
  required String category,
  DateTime? contentCreatedAt,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('saved_hops_token');
  if (token == null) return false;
  try {
    await Supabase.instance.client.rpc('submit_report', params: {
      'p_hops_token': token,
      'p_content_type': contentType,
      'p_target_username': targetUsername,
      'p_snapshot_text': snapshotText,
      'p_category': category,
      // UTC — Postgres stores timestamptz, and sending a local-time string
      // without an offset would be read as whatever the server's timezone
      // is, silently shifting every reported time.
      'p_content_created_at': contentCreatedAt?.toUtc().toIso8601String(),
    });
    return true;
  } catch (_) {
    return false;
  }
}

// ── Offline queue ────────────────────────────────────────────────────────
//
// A report that fails to submit live (no connection at the moment) is
// persisted here instead of just being dropped — same "small local state"
// SharedPreferences convention as everything else in this app (see
// CLAUDE.md's Local persistence section), not a new sqflite table, since
// this is a short-lived queue, not a growing history.
const _pendingReportsPrefsKey = 'pending_reports_v1';

Future<void> queueReport({
  required String contentType,
  String? targetUsername,
  required String snapshotText,
  required String category,
  DateTime? contentCreatedAt,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_pendingReportsPrefsKey) ?? [];
  raw.add(json.encode({
    'contentType': contentType,
    'targetUsername': targetUsername,
    'snapshotText': snapshotText,
    'category': category,
    'contentCreatedAt': contentCreatedAt?.toIso8601String(),
  }));
  await prefs.setStringList(_pendingReportsPrefsKey, raw);
}

/// How many reports are waiting for a connection. Drives the "N waiting to
/// send" hint so a queued report isn't invisible until it happens to go
/// out — see hops_app.dart's Contacts app bar.
Future<int> pendingReportCount() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_pendingReportsPrefsKey) ?? []).length;
}

/// Retries every queued report, removing each one that actually goes
/// through. Safe to call often and from anywhere — a call while still
/// offline (or with nothing queued) is a cheap no-op. See hops_app.dart's
/// _syncIdentityStatus, which calls this alongside its own periodic
/// connectivity check so a queued report doesn't need the student to
/// remember to reopen the exact screen they reported from.
Future<void> flushPendingReports() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_pendingReportsPrefsKey) ?? [];
  if (raw.isEmpty) return;

  final stillPending = <String>[];
  for (final entry in raw) {
    try {
      final j = json.decode(entry) as Map<String, dynamic>;
      final createdAtRaw = j['contentCreatedAt'] as String?;
      final ok = await _submitReport(
        contentType: j['contentType'] as String,
        targetUsername: j['targetUsername'] as String?,
        snapshotText: j['snapshotText'] as String,
        category: j['category'] as String,
        contentCreatedAt:
            createdAtRaw == null ? null : DateTime.tryParse(createdAtRaw),
      );
      if (!ok) stillPending.add(entry);
    } catch (_) {
      // Malformed queue entry (shouldn't happen — written by queueReport
      // itself) — drop it rather than retry it forever.
    }
  }
  await prefs.setStringList(_pendingReportsPrefsKey, stillPending);
}
