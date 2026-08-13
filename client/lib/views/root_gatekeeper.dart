import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypton/crypton.dart';
import 'package:crypto/crypto.dart';
import 'package:client/views/auth_screen.dart';
import 'package:client/views/hops_app.dart';
import 'package:client/views/terms_screen.dart';
import 'package:client/views/walkthrough_screen.dart';
import 'package:client/views/email_verification_screen.dart';
import 'package:client/utils/auth_error_messages.dart';
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

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.camera,
    ].request();

    if (statuses[Permission.location]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted) {
      return true;
    } else {
      setState(() => authEngineStatus = "Err: Permissions Denied");
      return false;
    }
  }

  Map<String, String> _generateLocalMeshKeys() {
    RSAKeypair keypair = RSAKeypair.fromRandom();
    return {
      'public': keypair.publicKey.toString(),
      'private': keypair.privateKey.toString(),
    };
  }

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
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
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Generating Crypto Keys...");
      final meshKeys = _generateLocalMeshKeys();

      setState(() => authEngineStatus = "Registering Identity...");
      final passwordHash = _hashPassword(password);

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
      print("❌ SIGNUP EXCEPTION: ${e.message}");
      if (e.message.contains('username_taken')) {
        setState(() => authEngineStatus = "Err: That username is already taken — try another one.");
      } else if (e.message.contains('email_taken')) {
        setState(() => authEngineStatus = "Err: An account already exists with that email address.");
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
      print("❌ SIGNUP EXCEPTION: $e");
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
      final response = await Supabase.instance.client.rpc(
        'signin_hops_user_by_email',
        params: {
          'p_email': targetedEmail,
          'p_password_hash': _hashPassword(password),
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
        final keys = _generateLocalMeshKeys();
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
          print("⚠️ Failed to push refreshed public key: $e");
        }
      }

      setState(() => authEngineStatus = "Session Secured!");

      if (mounted) {
        _showTermsAcceptanceDialog(response['username']);
      }
    } on PostgrestException catch (e) {
      print("❌ SIGNIN EXCEPTION: ${e.message}");
      if (e.code == 'PGRST202' || (e.message.contains('function') && e.message.contains('does not exist'))) {
        setState(() => authEngineStatus =
            "Err: Server not set up yet — run the Supabase migrations (see supabase/migrations/) then try again.");
      } else {
        setState(() => authEngineStatus = "Err: ${describeAuthException(e)}");
      }
    } catch (e) {
      print("❌ SIGNIN EXCEPTION: $e");
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
    // Requires actually scrolling through the terms before the checkbox
    // can be checked at all — previously it was enabled the instant the
    // dialog opened, so "I agree" didn't mean much. maxScrollExtent is 0
    // when the content already fits without scrolling (e.g. a very large
    // display), which counts as "reached the bottom" trivially.
    bool reachedBottom = false;
    final scrollController = ScrollController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final colors = Theme.of(context).colorScheme;

            // Safety net for the scroll-gate below: if the terms content
            // ever fits within the dialog's fixed height without needing
            // to scroll at all (e.g. a very tall/large display), no scroll
            // notification would ever fire to unlock the checkbox — check
            // directly once this frame's laid out instead of relying only
            // on the listener.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!reachedBottom &&
                  scrollController.hasClients &&
                  scrollController.position.maxScrollExtent <= 0) {
                setDialogState(() => reachedBottom = true);
              }
            });

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
                height: 300,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    final metrics = notification.metrics;
                    // >= maxScrollExtent - 4: a couple of px of slack for
                    // floating-point rounding at the very end of the list,
                    // same idea as the tolerance used elsewhere for "did
                    // this scroll view bottom out."
                    if (!reachedBottom &&
                        metrics.pixels >= metrics.maxScrollExtent - 4) {
                      setDialogState(() => reachedBottom = true);
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: RichText(
                      text: TextSpan(children: spans),
                    ),
                  ),
                ),
              ),
              actions: [
                if (!reachedBottom)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(Icons.arrow_downward, size: 14, color: colors.onSurface.withOpacity(0.5)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "Scroll down to read the full terms before agreeing",
                            style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.6), fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Checkbox(
                      value: agreed,
                      // Locked to unchecked (and unresponsive) until the
                      // scroll listener above confirms the bottom's been
                      // reached — checking "I agree" before that point
                      // wouldn't mean the user actually read anything.
                      onChanged: !reachedBottom
                          ? null
                          : (val) {
                              setDialogState(() => agreed = val ?? false);
                            },
                      activeColor: colors.primary,
                    ),
                    Expanded(
                      child: Text(
                        "I agree to the Terms and Conditions",
                        style: TextStyle(
                          fontSize: 12,
                          color: reachedBottom ? null : colors.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: agreed ? colors.primary : Colors.grey,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: agreed ? () async {
                    await prefs.setBool('terms_accepted', true);
                    Navigator.of(context).pop();
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
        final result = await Navigator.of(context).push(
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