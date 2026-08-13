// account_management_screen.dart
//
// Replaces the old standalone "Log Out / Destroy Identity" card on the
// profile screen with a dedicated hub for the three things people actually
// mean by "manage my account": change password, log out, delete account.
import 'dart:convert';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:crypto/crypto.dart';
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
import 'package:client/widgets/password_strength_bar.dart';
import 'package:client/views/email_verification_screen.dart';

String _hashPassword(String password) =>
    sha256.convert(utf8.encode(password)).toString();

/// Clears every locally-scoped identity key and the cached sqlite db, then
/// drops the caller onto the gatekeeper. Shared by both "Log Out" and
/// "Delete Account" (deletion also needs the server-side row gone first,
/// which the caller does before calling this).
Future<void> _wipeLocalIdentityAndReturnToGatekeeper(BuildContext context) async {
  // Belt-and-suspenders: HopsApp's own dispose() already stops advertising
  // once pushAndRemoveUntil below tears its route down, but that's an
  // indirect consequence of widget disposal timing, not something this
  // function controls directly. Stopping it explicitly, right here, means
  // the beacon carrying this identity goes off the air immediately and
  // deterministically the moment someone logs out — their dot shouldn't
  // linger on anyone else's radar for even the length of a route
  // transition after they've signed out.
  await BlePeripheral.stopAdvertising();
  await FlutterBluePlus.stopScan();

  // Close our handle before unlinking the file — deleting an open sqlite db
  // can leave it locked/corrupted, and DatabaseHelper's cached connection
  // must be dropped too or every DB call for the rest of this app session
  // keeps talking to the now-deleted file instead of the fresh one a new
  // sign-up expects.
  //
  // Was reconstructing this path by hand via getDatabasesPath() — a
  // *different* directory than the one DatabaseHelper actually opens the
  // database in (see resolveDatabasePath()'s doc comment). That meant this
  // deleteDatabase call was silently a no-op: it deleted a file that never
  // existed, while the real database — every message, task, and vibe
  // record — survived untouched and showed up again under the next
  // account signed into on the same device.
  await DatabaseHelper.instance.close();
  await deleteDatabase(await DatabaseHelper.resolveDatabasePath());

  final prefs = await SharedPreferences.getInstance();
  // Clear every locally-scoped identity key, not just the session token —
  // otherwise a different person signing up on this device inherits the
  // previous account's avatar, nickname, bio and feature toggles.
  await prefs.remove('saved_hops_token');
  await prefs.remove('my_username');
  await prefs.remove('my_hops_id');
  await prefs.remove('my_email');
  await prefs.remove('email_verified');
  await prefs.remove('avatar_path');
  await prefs.remove('nickname');
  await prefs.remove('bio');
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
  await const FlutterSecureStorage().delete(key: 'private_key');
  await const FlutterSecureStorage().delete(key: 'rotating_id_seed');

  if (context.mounted) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()),
      (route) => false,
    );
  }
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
    await _wipeLocalIdentityAndReturnToGatekeeper(context);
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
      color: destructive ? Colors.red.withOpacity(0.05) : null,
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
          style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.6)),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withOpacity(0.4)),
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
  bool _busy = false;
  String? _error;

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
    super.dispose();
  }

  Future<void> _submit() async {
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
      _busy = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) throw Exception('Not signed in');

      final ok = await Supabase.instance.client.rpc('change_hops_password', params: {
        'p_hops_token': token,
        'p_old_password_hash': _hashPassword(current),
        'p_new_password_hash': _hashPassword(next),
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
                  color: Colors.red.withOpacity(0.08),
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
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text("Update Password"),
            ),
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
    final emailError = validateEmail(newEmail);

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

      final ok = await Supabase.instance.client.rpc('change_hops_email', params: {
        'p_hops_token': token,
        'p_password_hash': _hashPassword(password),
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
                style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.6)),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
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

      final ok = await Supabase.instance.client.rpc('delete_hops_user', params: {
        'p_hops_token': token,
        'p_password_hash': _hashPassword(password),
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
      await _wipeLocalIdentityAndReturnToGatekeeper(context);
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
                color: Colors.red.withOpacity(0.08),
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
