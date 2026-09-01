import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:client/services/bluetooth_permissions.dart';
import 'package:client/views/auth_screen.dart';
import 'package:client/views/hops_app.dart';
import 'package:client/views/terms_screen.dart';
import 'package:client/views/walkthrough_screen.dart';
import 'package:client/views/email_verification_screen.dart';
import 'package:client/utils/auth_error_messages.dart';
import 'package:client/services/hops_engine.dart' show isReservedUsername;
import 'package:client/utils/mesh_crypto.dart';
import 'dart:convert';
import 'dart:math';

class HopsRootGatekeeper extends StatefulWidget {
  const HopsRootGatekeeper({super.key});

  @override
  State<HopsRootGatekeeper> createState() => _HopsRootGatekeeperState();
}

class _HopsRootGatekeeperState extends State<HopsRootGatekeeper> {
  String authEngineStatus = "System Ready";
  final _secureStorage = const FlutterSecureStorage();

  // ---------- Text styles for Terms (mirroring TermsScreen) ----------
  static const TextStyle _titleStyle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.bold,
    height: 1.4,
  );
  static const TextStyle _headingStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    height: 1.4,
  );
  static const TextStyle _bodyStyle = TextStyle(
    fontSize: 14,
    height: 1.5,
  );

  Future<bool> _requestMeshPermissionsGate() async {
    setState(() => authEngineStatus = "Awaiting System Permissions...");

    // Version-aware — see services/bluetooth_permissions.dart. This gate
    // used to require bluetoothScan to be granted, which is impossible
    // below Android 12: the permission does not exist there, so
    // permission_handler reports it denied with no dialog and no setting
    // the user can change. That failed sign-up and sign-in outright on
    // those handsets, with "Err: Permissions Denied" and no way forward.
    final bluetoothGranted = await BluetoothPermissions.request();

    // Camera is only for the QR pairing flow, not for sign-in, so it is
    // requested alongside but never gates the result.
    await Permission.camera.request();

    if (bluetoothGranted) {
      return true;
    } else {
      setState(() => authEngineStatus = "Err: Permissions Denied");
      return false;
    }
  }

  // The private, never-transmitted secret behind the rotating "HPS:<token>"
  // presence beacon (see hops_constants.dart's computeRotatingToken) — kept
  // in secure storage next to private_key, generated once per identity.
  // [forceNew] is used on sign-up, where there's by definition nothing to
  // reuse yet; sign-in only generates one if secure storage came back empty
  // (fresh install/new device), same trigger that regenerates private_key.
  Future<void> _ensureRotatingIdSeed({bool forceNew = false}) async {
    if (!forceNew) {
      final existing = await _secureStorage.read(key: 'rotating_id_seed');
      if (existing != null) return;
    }
    final random = Random.secure();
    final seedBytes = List<int>.generate(24, (_) => random.nextInt(256));
    await _secureStorage.write(key: 'rotating_id_seed', value: base64Encode(seedBytes));
  }

  Future<void> handleMeshSignUp({
    required String email,
    required String password,
    required String username,
  }) async {
    try {
      // Checked before anything else happens — key generation, permission
      // prompts and a network round trip are all wasted work if the name
      // can't be used, and this one is knowable offline. The server
      // enforces it too (0014_reserve_bot_usernames.sql); this is purely
      // so the person finds out immediately.
      if (isReservedUsername(username)) {
        setState(() => authEngineStatus =
            "Err: That name is reserved for the built-in Hops assistant — please pick another.");
        return;
      }

      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Generating Crypto Keys...");
      final meshKeys = generateLocalMeshKeys();

      setState(() => authEngineStatus = "Registering Identity...");
      // See mesh_crypto.dart's header comment for the salted-hashing
      // scheme this is part of — a brand-new password gets a brand-new
      // salt, generated locally rather than asking the server for one,
      // since there's no existing account yet to look one up from.
      final passwordSalt = generatePasswordSalt();
      final passwordHash = hashSaltedPassword(password, passwordSalt);

      await _secureStorage.write(key: 'private_key', value: meshKeys['private']);
      await _ensureRotatingIdSeed(forceNew: true);

      // Server-side RPC, not a direct insert — public.profiles no longer
      // grants anon/authenticated direct table access (see
      // supabase/migrations/0001_lockdown_profiles.sql). The function
      // generates the row's id and hops_token itself and hands back only
      // that safe subset. p_email is new (0007_email_auth_and_otp.sql) —
      // sign-in is now email-based, so this is the first time the email
      // typed at signup actually gets persisted anywhere.
      final response = await Supabase.instance.client.rpc(
        'signup_hops_user',
        params: {
          'p_username': username,
          'p_email': email.trim().toLowerCase(),
          'p_public_key': meshKeys['public'],
          'p_password_hash': passwordHash,
          'p_password_salt': passwordSalt,
        },
      ).single();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', response['hops_token'] as String);
      await prefs.setString('my_hops_id', response['id'] as String);
      await prefs.setString('my_username', username);
      await prefs.setString('my_email', email.trim().toLowerCase());
      await prefs.setBool('email_verified', false);
      // New accounts always start as students — signup_hops_user's RPC
      // enforces this server-side too (role defaults 'student'), this is
      // just keeping the locally-cached copy consistent from the start.
      await prefs.setString('my_role', 'student');
      await prefs.remove('my_admin_title');

      setState(() => authEngineStatus = "Registration Complete!");

      if (mounted) {
        // Suggested-form email verification: send the code and offer to
        // confirm it right away, but this is skippable (see
        // EmailVerificationScreen's header comment) — either way, signup
        // continues on to the usual terms/walkthrough flow afterward.
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => EmailVerificationScreen(email: email.trim())),
        );
        if (mounted) _showTermsAcceptanceDialog(username);
      }
    } on PostgrestException catch (e) {
      debugPrint("❌ SIGNUP EXCEPTION: ${e.message}");
      if (e.message.contains('username_taken')) {
        setState(() => authEngineStatus = "Err: That username is already taken — try another one.");
      } else if (e.message.contains('email_taken')) {
        setState(() => authEngineStatus = "Err: An account already exists with that email address.");
      } else if (e.message.contains('username_reserved')) {
        // Only reachable if the local list above has drifted from the
        // server's — kept so the drift surfaces as a clear message rather
        // than the generic fallback.
        setState(() => authEngineStatus =
            "Err: That name is reserved for the built-in Hops assistant — please pick another.");
      } else if (e.message.contains('invalid_username')) {
        setState(() => authEngineStatus = "Err: Username must be 3-20 characters.");
      } else if (e.message.contains('invalid_email')) {
        setState(() => authEngineStatus = "Err: That doesn't look like a valid email address.");
      } else if (e.code == '23505') {
        setState(() => authEngineStatus = "Err: That username or email is already taken.");
      } else if (e.code == 'PGRST202' || e.message.contains('function') && e.message.contains('does not exist')) {
        // The signup_hops_user RPC itself is missing — almost always means
        // the Supabase migrations (supabase/migrations/*.sql) haven't been
        // run against this project yet, not a problem with what was typed.
        setState(() => authEngineStatus =
            "Err: Server not set up yet — run the Supabase migrations (see supabase/migrations/) then try again.");
      } else {
        setState(() => authEngineStatus = "Err: ${describeAuthException(e)}");
      }
    } catch (e) {
      debugPrint("❌ SIGNUP EXCEPTION: $e");
      setState(() => authEngineStatus = "Err: ${describeAuthException(e)}");
    }
  }

  Future<void> handleMeshSignIn({
    required String email,
    required String password,
  }) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Verifying Credentials...");
      // Sign-in is email-based now (0007_email_auth_and_otp.sql) — easier
      // to remember/recover than a username, and lines up with the
      // forgot-password flow, which necessarily needs an email to send a
      // reset code to anyway.
      final String targetedEmail = email.trim().toLowerCase();

      // Server-side RPC, not a direct select+update — public.profiles no
      // longer grants anon/authenticated direct table access (see
      // supabase/migrations/0001_lockdown_profiles.sql). password_hash is
      // compared inside the function and never sent to this client at all.
      // It also returns an empty result for "no such account" and "wrong
      // password" alike, so the two error branches this used to have
      // collapse into one generic message on purpose — that used to leak
      // which emails exist.
      // Salt has to be fetched before the hash can even be computed — see
      // mesh_crypto.dart's header comment. fetchPasswordSaltForEmail
      // returns an indistinguishable-looking value for an email with no
      // account, so this round trip alone reveals nothing.
      final salt = await fetchPasswordSaltForEmail(targetedEmail);
      final response = await Supabase.instance.client.rpc(
        'signin_hops_user_by_email',
        params: {
          'p_email': targetedEmail,
          'p_password_hash': hashSaltedPassword(password, salt),
        },
      ).maybeSingle();

      if (response == null) {
        setState(() => authEngineStatus = "Err: That email and password don't match any Hops account.");
        return;
      }

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', response['hops_token'] as String);
      await prefs.setString('my_hops_id', response['id'] as String);
      await prefs.setString('my_username', response['username'] as String);
      await prefs.setString('my_email', targetedEmail);
      await prefs.setBool('email_verified', response['email_verified'] as bool? ?? false);
      // Refreshed on every sign-in — an admin_requests approval elsewhere
      // shouldn't require a reinstall to take effect locally, just a
      // fresh login.
      await prefs.setString('my_role', response['role'] as String? ?? 'student');
      final adminTitle = response['admin_title'] as String?;
      if (adminTitle != null) {
        await prefs.setString('my_admin_title', adminTitle);
      } else {
        await prefs.remove('my_admin_title');
      }

      String? privateKey = await _secureStorage.read(key: 'private_key');
      if (privateKey == null) {
        // No local private key (reinstall, new device) — a fresh keypair
        // is useless to anyone unless the server-side directory (used to
        // verify Emergency Flare signatures) is updated to match it. This
        // used to only happen locally and silently drift the two out of
        // sync — see supabase/migrations/0003_refresh_public_key.sql.
        final keys = generateLocalMeshKeys();
        await _secureStorage.write(key: 'private_key', value: keys['private']);
        await _ensureRotatingIdSeed();
        try {
          await Supabase.instance.client.rpc('refresh_public_key', params: {
            'p_hops_token': response['hops_token'],
            'p_public_key': keys['public'],
          });
        } catch (e) {
          // Best-effort — the new keypair still works locally, and a
          // stale server-side key only affects how *others* verify this
          // device's flares, not this sign-in.
          debugPrint("⚠️ Failed to push refreshed public key: $e");
        }
      }

      setState(() => authEngineStatus = "Session Secured!");

      if (mounted) {
        _showTermsAcceptanceDialog(response['username']);
      }
    } on PostgrestException catch (e) {
      debugPrint("❌ SIGNIN EXCEPTION: ${e.message}");
      if (e.code == 'PGRST202' || (e.message.contains('function') && e.message.contains('does not exist'))) {
        setState(() => authEngineStatus =
            "Err: Server not set up yet — run the Supabase migrations (see supabase/migrations/) then try again.");
      } else {
        setState(() => authEngineStatus = "Err: ${describeAuthException(e)}");
      }
    } catch (e) {
      debugPrint("❌ SIGNIN EXCEPTION: $e");
      setState(() => authEngineStatus = "Err: ${describeAuthException(e)}");
    }
  }

  // Terms acceptance dialog with rich-text styled terms
  void _showTermsAcceptanceDialog(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final hasAccepted = prefs.getBool('terms_accepted') ?? false;

    if (hasAccepted) {
      _navigateToDashboard();
      return;
    }

    bool agreed = false;

    // Guarded because the SharedPreferences read above is an await, and
    // sign-up can be abandoned in that window.
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final colors = Theme.of(context).colorScheme;

            // Build rich-text spans from the raw terms text
            final lines = TermsScreen.termsText.split('\n');
            final spans = <TextSpan>[];
            for (int i = 0; i < lines.length; i++) {
              final line = lines[i];
              if (line.trim().isEmpty) {
                spans.add(const TextSpan(text: '\n'));
                continue;
              }
              if (i == 0) {
                // Main title
                spans.add(TextSpan(
                  text: line.trim(),
                  style: _titleStyle.copyWith(color: colors.primary),
                ));
                spans.add(const TextSpan(text: '\n\n'));
                continue;
              }
              final headingPattern = RegExp(r'^\d+\.\s');
              if (headingPattern.hasMatch(line.trim())) {
                // Section heading
                spans.add(const TextSpan(text: '\n\n'));
                spans.add(TextSpan(
                  text: line.trim(),
                  style: _headingStyle.copyWith(color: colors.primary),
                ));
                spans.add(const TextSpan(text: '\n\n'));
                continue;
              }
              // Body text — theme-aware so it stays readable against the
              // dialog's own background instead of assuming it's white.
              spans.add(TextSpan(
                text: line.trim().isEmpty ? '\n' : '${line.trim()} ',
                style: _bodyStyle.copyWith(color: colors.onSurface),
              ));
            }

            return AlertDialog(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Text(
                "Welcome, $username!",
                style: TextStyle(
                    color: colors.primary, fontWeight: FontWeight.bold),
              ),
              content: SizedBox(
                height: 340,
                width: double.maxFinite,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.arrow_downward, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "Scroll to the bottom to check the box and continue",
                            style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.6), fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RichText(text: TextSpan(children: spans)),
                            // The checkbox lives INSIDE the scrollable
                            // content, as the very last thing in it — not
                            // pinned in the dialog's action bar. A widget
                            // below the fold of a SingleChildScrollView
                            // can't be tapped until it's actually scrolled
                            // into view, so this makes "read to the
                            // bottom" a physical requirement rather than a
                            // scroll-position check that has to be kept in
                            // sync with it.
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Checkbox(
                                  value: agreed,
                                  onChanged: (val) {
                                    setDialogState(() => agreed = val ?? false);
                                  },
                                  activeColor: colors.primary,
                                ),
                                Expanded(
                                  child: Text(
                                    "I agree to the Terms and Conditions",
                                    style: TextStyle(fontSize: 12, color: colors.onSurface),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: agreed ? colors.primary : Colors.grey,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: agreed ? () async {
                    // Captured before the write: this closure's context
                    // belongs to the dialog route, which is exactly what's
                    // about to be popped.
                    final navigator = Navigator.of(context);
                    await prefs.setBool('terms_accepted', true);
                    navigator.pop();
                    if (!mounted) return;
                    _navigateToDashboard();
                  }
                      : null,
                  child: const Text("Proceed to Hops"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _navigateToDashboard() async {
    final prefs = await SharedPreferences.getInstance();
    final walkthroughSeen = prefs.getBool('walkthrough_seen') ?? false;

    if (mounted) {
      if (walkthroughSeen) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HopsApp()),
        );
      } else {
        // Show walkthrough, then go to dashboard
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const WalkthroughScreen(showOnboarding: true),
          ),
        );
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HopsApp()),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreen(
      currentStatus: authEngineStatus,
      onSignUpTrigger: handleMeshSignUp,
      onSignInTrigger: handleMeshSignIn,
    );
  }
}