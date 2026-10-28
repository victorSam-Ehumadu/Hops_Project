// account_management_screen.dart
//
// Replaces the old standalone "Log Out / Destroy Identity" card on the
// profile screen with a dedicated hub for the things people actually mean
// by "manage my account": change password, change email, export a backup
// of your local data, log out, delete account.
import 'dart:convert';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/utils/auth_error_messages.dart';
import 'package:client/utils/password_policy.dart';
import 'package:client/utils/mesh_crypto.dart';
import 'package:client/widgets/password_strength_bar.dart';
import 'package:client/views/email_verification_screen.dart';
import 'package:client/services/avatar_path_notifier.dart';
import 'package:client/services/account_standing.dart';
import 'package:client/services/bluetooth_name_guard.dart';

/// Clears every locally-scoped identity key and the cached sqlite db, then
/// drops the caller onto the gatekeeper. Shared by both "Log Out" and
/// "Delete Account" (deletion also needs the server-side row gone first,
/// which the caller does before calling this).
/// Stops this device broadcasting the signed-in identity.
///
/// Called by every teardown path. Explicit rather than relying on
/// HopsApp.dispose() firing when its route is torn down: that is an
/// indirect consequence of widget disposal timing, and the beacon
/// carrying this identity should go off the air deterministically the
/// moment the session ends, not a route transition later. Someone's dot
/// should not linger on anyone else's radar after they are signed out.
Future<void> _silenceIdentityRadio() async {
  await BlePeripheral.stopAdvertising();
  await FlutterBluePlus.stopScan();
}

/// Deletes the local sqlite database — every message, task and vibe record.
///
/// Close our handle before unlinking the file: deleting an open sqlite db
/// can leave it locked/corrupted, and DatabaseHelper's cached connection
/// must be dropped too, or every DB call for the rest of this app session
/// keeps talking to the now-deleted file instead of the fresh one a new
/// sign-up expects.
///
/// This used to reconstruct the path by hand via getDatabasesPath() — a
/// *different* directory than the one DatabaseHelper actually opens the
/// database in (see resolveDatabasePath()'s doc comment). That made the
/// delete silently a no-op: it removed a file that never existed, while
/// the real database survived untouched and showed up again under the next
/// account signed into on the same device.
Future<void> deleteLocalDatabase() async {
  await DatabaseHelper.instance.close();
  await deleteDatabase(await DatabaseHelper.resolveDatabasePath());
}

/// Clears every account-scoped key in SharedPreferences, not just the
/// session token — otherwise a different person signing in on this device
/// inherits the previous account's avatar, nickname, bio and feature
/// toggles.
Future<void> clearAccountScopedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_hops_token');
  await prefs.remove('my_username');
  await prefs.remove('my_hops_id');
  await prefs.remove('my_email');
  await prefs.remove('email_verified');
  await prefs.remove('nickname');
  await prefs.remove('bio');
  await prefs.remove('thinking_status');
  await prefs.remove('enabledFeatureIds');
  await prefs.remove('pinned_feature_ids');
  await prefs.remove('feature_order');
  await prefs.remove('watchingBuddies');
  await prefs.remove('discoverable_mode');
  await prefs.remove('terms_accepted');
  await prefs.remove('walkthrough_seen');
  await prefs.remove('pending_help_hint');
  await prefs.remove('my_role');
  await prefs.remove('my_admin_title');
  await prefs.remove('avatar_path');
  avatarPathRevision.value++;
  await const FlutterSecureStorage().delete(key: 'private_key');
  await const FlutterSecureStorage().delete(key: 'rotating_id_seed');
}

/// Clears every locally-scoped identity key and the cached sqlite db, then
/// drops the caller onto the gatekeeper. Shared by "Log Out", "Delete
/// Account" (deletion also needs the server-side row gone first, which the
/// caller does before calling this) and a ban.
Future<void> wipeLocalIdentityAndReturnToGatekeeper(BuildContext context) async {
  await _silenceIdentityRadio();
  await deleteLocalDatabase();
  await clearAccountScopedPrefs();

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()),
      (route) => false,
    );
  }
}

/// Ends the session immediately because the account was suspended or
/// banned, and lands the user on the sign-in page.
///
/// The session genuinely ends — `saved_hops_token` is removed, so there is
/// nothing left for the launch path to re-enter HopsApp with, and nothing
/// the user can navigate back to. An earlier attempt held the session and
/// covered the app with a barrier screen instead; that left a live token
/// in place, which is not what "their session is terminated" means.
///
/// Ban and suspension differ in exactly one respect, and only in what is
/// left on the device:
///
///   * A ban is permanent, so there is nothing to come back to and this is
///     the full teardown — identical to Log Out.
///   * A suspension expires. Deleting the sqlite database for a three-day
///     timeout would destroy every message, task and vibe record
///     irreversibly, which is well beyond what the moderator chose, so the
///     data stays and only the session goes. `my_hops_id` is deliberately
///     left behind as the marker that says who that data belongs to —
///     discardLocalDataForAccountSwitch() below is what stops anyone else
///     inheriting it.
Future<void> endSessionForModeration(
  BuildContext context,
  AccountStanding standing,
) async {
  await _silenceIdentityRadio();
  await BluetoothNameGuard.restore();

  if (standing.kind == AccountStandingKind.banned) {
    if (!context.mounted) return;
    await wipeLocalIdentityAndReturnToGatekeeper(context);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_hops_token');

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
    MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()),
    (route) => false,
  );
}

/// Wipes local data when a *different* account signs in on this device.
///
/// Normally unnecessary: every ordinary sign-out already deletes the
/// database, so there is nothing to inherit. A suspension is the exception
/// — it leaves the database in place so the user gets their messages back
/// when the suspension lifts (see endSessionForModeration). That is the
/// one state in which the next person to sign in could otherwise inherit
/// someone else's threads, so sign-in calls this with the id it just
/// authenticated.
///
/// [signedInHopsId] is the id the server just returned. Returns true if
/// local data was discarded.
Future<bool> discardLocalDataForAccountSwitch(String? signedInHopsId) async {
  final prefs = await SharedPreferences.getInstance();
  final previous = prefs.getString('my_hops_id');
  if (previous == null || signedInHopsId == null || previous == signedInHopsId) {
    return false;
  }
  await deleteLocalDatabase();
  await clearAccountScopedPrefs();
  return true;
}

class AccountManagementScreen extends StatefulWidget {
  const AccountManagementScreen({super.key});

  @override
  State<AccountManagementScreen> createState() => _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  bool _busy = false;

  Future<void> _confirmLogOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Log out?"),
        content: const Text(
            "You'll need your username and password to sign back in on this device."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Log Out")),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await wipeLocalIdentityAndReturnToGatekeeper(context);
  }

  Future<void> _openChangePassword() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _ChangePasswordScreen()),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Password changed.")),
      );
    }
  }

  Future<void> _openChangeEmail() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _ChangeEmailScreen()),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Email updated.")),
      );
    }
  }

  // Exports every locally-stored row (messages, tasks, vibe reports,
  // contact profiles) to one JSON file the user saves wherever they like —
  // see DatabaseHelper.exportAllData's header comment for why this exists:
  // this app keeps no cloud copy of any of it by design, so this is the
  // one way to get a copy that survives something happening to this
  // specific phone. Uses the same file_picker "save to a chosen location"
  // flow received_files_page.dart's Download button already established,
  // rather than silently writing somewhere the user can't find without
  // digging through app-private storage.
  Future<void> _exportMyData() async {
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('my_username') ?? 'hops_user';

      final data = await DatabaseHelper.instance.exportAllData();
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));

      final timestamp = DateTime.now();
      final stamp = '${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}'
          '${timestamp.day.toString().padLeft(2, '0')}';
      final fileName = 'hops_data_export_${username}_$stamp.json';

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save your Hops data export',
        fileName: fileName,
        bytes: bytes,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedPath != null ? "Saved $fileName" : "Export cancelled"),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't export your data: $e")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDeleteAccount() async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _DeleteAccountScreen()),
    );
    if (deleted == true) {
      // _DeleteAccountScreen already wiped local state and navigated to
      // the gatekeeper itself (deletion needs its own busy/local-wipe
      // sequence) — nothing left to do here.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text("Account Management", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _ManagementTile(
              icon: Icons.lock_outline,
              iconColor: colors.primary,
              title: "Change Account Password",
              subtitle: "Update the password you sign in with",
              onTap: _openChangePassword,
            ),
            const SizedBox(height: 12),
            _ManagementTile(
              icon: Icons.alternate_email,
              iconColor: colors.primary,
              title: "Change Email",
              subtitle: "Update the email you sign in with",
              onTap: _openChangeEmail,
            ),
            const SizedBox(height: 12),
            _ManagementTile(
              icon: Icons.download_for_offline_outlined,
              iconColor: colors.primary,
              title: "Export My Data",
              subtitle: "Save a backup of your messages, tasks & contacts to a file",
              onTap: _busy ? null : _exportMyData,
            ),
            const SizedBox(height: 12),
            _ManagementTile(
              icon: Icons.logout,
              iconColor: colors.primary,
              title: "Log Out",
              subtitle: "Sign out of Hops on this device",
              onTap: _busy ? null : _confirmLogOut,
            ),
            const SizedBox(height: 12),
            _ManagementTile(
              icon: Icons.delete_forever_outlined,
              iconColor: Colors.redAccent,
              title: "Delete Account",
              subtitle: "Permanently erase your identity — this can't be undone",
              destructive: true,
              onTap: _openDeleteAccount,
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManagementTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  const _ManagementTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: destructive ? Colors.red.withValues(alpha: 0.05) : null,
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: destructive ? Colors.redAccent : colors.primary,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withValues(alpha: 0.4)),
        onTap: onTap,
      ),
    );
  }
}

// ── Change password ─────────────────────────────────────────────────────
class _ChangePasswordScreen extends StatefulWidget {
  const _ChangePasswordScreen();

  @override
  State<_ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<_ChangePasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  final _otpController = TextEditingController();
  bool _busy = false;
  String? _error;
  // Two steps: fill in the passwords, then confirm a code sent to the
  // account's email — a second factor so a stolen/unlocked phone with a
  // live session alone isn't enough to lock the real owner out. Nothing is
  // actually changed until the code checks out (see _verifyAndSubmit).
  bool _otpStep = false;
  bool _sendingCode = false;

  @override
  void initState() {
    super.initState();
    _newController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<String?> _requireToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('saved_hops_token');
  }

  // Step 1 → 2: validates the password fields locally, then sends the
  // confirmation code. Reuses the exact same Edge Function signup/change-
  // email already use (send-verification-email) — it always mails whatever
  // email is on file for this token right now, which for this flow is
  // simply "the account's current, already-established email."
  Future<void> _sendCode() async {
    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;

    if (current.isEmpty) {
      setState(() => _error = "Enter your current password.");
      return;
    }
    final pwError = validatePassword(next);
    if (pwError != null) {
      setState(() => _error = pwError);
      return;
    }
    if (next != confirm) {
      setState(() => _error = "New password and confirmation don't match.");
      return;
    }

    setState(() {
      _sendingCode = true;
      _error = null;
    });

    try {
      final token = await _requireToken();
      if (token == null) throw Exception('Not signed in');

      final res = await Supabase.instance.client.functions.invoke(
        'send-verification-email',
        body: {'hops_token': token},
      );
      final ok = (res.data is Map) ? (res.data['ok'] as bool? ?? false) : false;
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _sendingCode = false;
          // "try again in a moment" was wrong for two of the three
          // failures: a quota needs longer than a moment, and a missing
          // sending domain never resolves by retrying at all.
          _error = describeEmailSendFailure(
              (res.data is Map) ? res.data['error'] : null);
        });
        return;
      }
      setState(() {
        _sendingCode = false;
        _otpStep = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingCode = false;
        _error = describeAuthException(e);
      });
    }
  }

  // Step 2: checks the typed code, and only on success actually applies
  // the password change — everything from here down is what _submit used
  // to do unconditionally.
  Future<void> _verifyAndSubmit() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _error = "Enter the 6-digit code from your email.");
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final token = await _requireToken();
      if (token == null) throw Exception('Not signed in');

      final otpOk = await Supabase.instance.client.rpc('verify_account_otp', params: {
        'p_hops_token': token,
        'p_otp_hash': hashPassword(otp),
      }) as bool;

      if (!mounted) return;
      if (!otpOk) {
        setState(() {
          _busy = false;
          _error = "That code is incorrect or has expired — check your email or go back and resend.";
        });
        return;
      }

      // See mesh_crypto.dart's header comment for the salted-hashing
      // scheme — the OLD password is checked against whatever salt this
      // account already has on file; the NEW password gets a fresh one.
      final oldSalt = await fetchMyPasswordSalt(token);
      final newSalt = generatePasswordSalt();
      final ok = await Supabase.instance.client.rpc('change_hops_password', params: {
        'p_hops_token': token,
        'p_old_password_hash': hashSaltedPassword(_currentController.text, oldSalt),
        'p_new_password_hash': hashSaltedPassword(_newController.text, newSalt),
        'p_new_password_salt': newSalt,
      }) as bool;

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = "Current password is incorrect, or your session expired — try logging out and back in.";
        });
        return;
      }

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeAuthException(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Change Password", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!_otpStep) ...[
              TextField(
                controller: _currentController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Current password'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _newController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
              ),
              PasswordStrengthBar(password: _newController.text),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm new password'),
                onSubmitted: (_) => _sendingCode ? null : _sendCode(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _sendingCode ? null : _sendCode,
                child: _sendingCode
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text("Send Confirmation Code"),
              ),
            ] else ...[
              Text(
                "Enter the 6-digit code we just emailed you to confirm this change.",
                style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.7)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, letterSpacing: 6),
                decoration: const InputDecoration(labelText: 'Confirmation code', counterText: ''),
                onSubmitted: (_) => _busy ? null : _verifyAndSubmit(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _sendingCode ? null : _sendCode,
                  child: const Text("Resend code"),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _busy ? null : _verifyAndSubmit,
                child: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text("Confirm & Update Password"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Change email ─────────────────────────────────────────────────────────
class _ChangeEmailScreen extends StatefulWidget {
  const _ChangeEmailScreen();

  @override
  State<_ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<_ChangeEmailScreen> {
  final _passwordController = TextEditingController();
  final _newEmailController = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _currentEmail;

  @override
  void initState() {
    super.initState();
    _loadCurrentEmail();
  }

  Future<void> _loadCurrentEmail() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _currentEmail = prefs.getString('my_email'));
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _newEmailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    final newEmail = _newEmailController.text.trim();
    // Same rule as signup: this sets the account's address, so it must
    // be an institutional one. Otherwise the signup restriction would
    // be trivially bypassable by signing up and changing it after.
    final emailError = validateAccountEmail(newEmail);

    if (password.isEmpty) {
      setState(() => _error = "Enter your password to confirm.");
      return;
    }
    if (emailError != null) {
      setState(() => _error = emailError);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) throw Exception('Not signed in');

      // See mesh_crypto.dart's header comment for the salted-hashing scheme.
      final salt = await fetchMyPasswordSalt(token);
      final ok = await Supabase.instance.client.rpc('change_hops_email', params: {
        'p_hops_token': token,
        'p_password_hash': hashSaltedPassword(password, salt),
        'p_new_email': newEmail.toLowerCase(),
      }) as bool;

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = "Password is incorrect, or your session expired — try logging out and back in.";
        });
        return;
      }

      await prefs.setString('my_email', newEmail.toLowerCase());
      await prefs.setBool('email_verified', false);

      if (!mounted) return;
      setState(() => _busy = false);
      // Same skippable verification step as signup — the new address
      // needs its own proof of ownership, the old one's verified status
      // doesn't carry over (see change_hops_email in
      // 0007_email_auth_and_otp.sql).
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EmailVerificationScreen(email: newEmail)),
      );
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message.contains('email_taken')
            ? "An account already exists with that email address."
            : describeAuthException(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeAuthException(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Change Email", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_currentEmail != null) ...[
              Text(
                "Current email: $_currentEmail",
                style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _newEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'New email'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm your password'),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text("Update Email"),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Delete account ──────────────────────────────────────────────────────
class _DeleteAccountScreen extends StatefulWidget {
  const _DeleteAccountScreen();

  @override
  State<_DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<_DeleteAccountScreen> {
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = "Enter your password to confirm.");
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) throw Exception('Not signed in');

      // See mesh_crypto.dart's header comment for the salted-hashing scheme.
      final salt = await fetchMyPasswordSalt(token);
      final ok = await Supabase.instance.client.rpc('delete_hops_user', params: {
        'p_hops_token': token,
        'p_password_hash': hashSaltedPassword(password, salt),
      }) as bool;

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = "Password is incorrect, or your session expired — try logging out and back in.";
        });
        return;
      }

      // Server-side row is gone — now wipe everything local and drop back
      // to the gatekeeper, same as logging out.
      await wipeLocalIdentityAndReturnToGatekeeper(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeAuthException(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Delete Account", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.redAccent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "This permanently deletes your Hops identity from the server and wipes everything stored on this device. It cannot be undone.",
                      style: TextStyle(color: Colors.redAccent, fontSize: 12, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm your password'),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text("Permanently Delete Account"),
            ),
          ],
        ),
      ),
    );
  }
}
