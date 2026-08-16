// lib/views/admin/admin_sign_in_screen.dart
//
// Admin app's only auth screen — sign-in only, deliberately no sign-up.
// Admin privilege is provisioned out-of-band (see profiles.role in
// supabase/migrations/0008_admin_moderation.sql): whoever holds Supabase
// access runs `update profiles set role = 'admin' where ...` against an
// account that already exists (created the normal way, through the
// student app, or directly in the database), then hands over a device
// already signed in with those credentials. This screen's job is narrow:
// authenticate, confirm the account is actually an admin, refuse anything
// that isn't with a clear reason, and get out of the way.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/utils/auth_error_messages.dart';
import 'package:client/utils/mesh_crypto.dart';
import 'package:client/views/admin/admin_shell.dart';

class AdminSignInScreen extends StatefulWidget {
  const AdminSignInScreen({super.key});

  @override
  State<AdminSignInScreen> createState() => _AdminSignInScreenState();
}

class _AdminSignInScreenState extends State<AdminSignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = "Enter both email and password.");
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Needed for the Listening Post scan and Official Alert broadcast —
      // asked up front rather than deferring to whichever screen first
      // needs it, same reasoning as _requestMeshPermissionsGate in
      // root_gatekeeper.dart.
      await [
        Permission.location,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();

      final response = await Supabase.instance.client.rpc(
        'signin_hops_user_by_email',
        params: {
          'p_email': email,
          'p_password_hash': hashPassword(password),
        },
      ).maybeSingle();

      if (response == null) {
        setState(() => _error = "That email and password don't match any Hops account.");
        return;
      }

      final role = response['role'] as String? ?? 'student';
      if (role != 'admin') {
        // Deliberately not signed in at all — no token is saved. A
        // correct, non-admin account trying this app should be told
        // plainly why it doesn't work, not left guessing.
        setState(() => _error =
            "This account doesn't have admin access. Admin privilege is granted by an existing admin, not requested — this isn't the app for a regular Hops account.");
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', response['hops_token'] as String);
      await prefs.setString('my_hops_id', response['id'] as String);
      await prefs.setString('my_username', response['username'] as String);
      await prefs.setString('my_email', email);
      await prefs.setString('my_role', role);
      final adminTitle = response['admin_title'] as String?;
      if (adminTitle != null) {
        await prefs.setString('my_admin_title', adminTitle);
      } else {
        await prefs.remove('my_admin_title');
      }

      // Same first-sign-in-on-a-fresh-device keypair bootstrap as
      // root_gatekeeper.dart's handleMeshSignIn — needed here too since
      // Official Alerts are signed with this device's private key
      // (hops_app.dart's _startSignatureCycle), and a device that's never
      // had this account signed in before has no local key to sign with.
      String? privateKey = await _secureStorage.read(key: 'private_key');
      if (privateKey == null) {
        final keys = generateLocalMeshKeys();
        await _secureStorage.write(key: 'private_key', value: keys['private']);
        try {
          await Supabase.instance.client.rpc('refresh_public_key', params: {
            'p_hops_token': response['hops_token'],
            'p_public_key': keys['public'],
          });
        } catch (e) {
          // Best-effort — see the matching comment in root_gatekeeper.dart.
          // A stale server-side key only affects how *others* verify this
          // device's Official Alerts, not this sign-in.
        }
      }

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AdminShell()),
          (route) => false,
        );
      }
    } on PostgrestException catch (e) {
      // Same reasoning as root_gatekeeper.dart's sign-in: describeAuthException
      // deliberately hides technical detail from the on-screen message, so
      // the raw error needs to land somewhere (flutter run's console /
      // logcat) or a real failure becomes undiagnosable from the outside.
      debugPrint("❌ ADMIN SIGNIN EXCEPTION: ${e.message} (code: ${e.code})");
      setState(() => _error = describeAuthException(e));
    } catch (e) {
      debugPrint("❌ ADMIN SIGNIN EXCEPTION: $e");
      setState(() => _error = describeAuthException(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield, size: 56, color: colors.primary),
                const SizedBox(height: 12),
                Text(
                  "Hops Admin",
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: colors.primary),
                ),
                const SizedBox(height: 4),
                Text(
                  "Sign in with a provisioned admin account",
                  style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: "Email",
                    prefixIcon: Icon(Icons.alternate_email),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _busy ? null : _signIn(),
                  decoration: InputDecoration(
                    labelText: "Password",
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text("Sign in"),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
