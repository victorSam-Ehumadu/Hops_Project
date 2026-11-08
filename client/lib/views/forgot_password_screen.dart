import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:client/utils/mesh_crypto.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/utils/password_policy.dart';
import 'package:client/utils/auth_error_messages.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/widgets/password_strength_bar.dart';

// Three steps, one per screen: enter the account email (triggers the OTP
// email via the send-password-reset-otp Edge Function), enter the 6-digit
// code, then choose the new password.
//
// The split between the code and the password is PRESENTATIONAL ONLY.
// There is no server function that verifies a reset code on its own:
// verify_password_reset_otp checks the code and changes the password in one
// atomic call (0018_salted_password_hashing.sql, superseding 0007), which is
// the right design — a verify-only round trip would be a second place the
// attempt counter has to be got right. So "Continue" on the code step only
// checks that six digits were typed, and a wrong code is still only
// reported after the password is submitted. When that happens,
// _submitNewPassword sends the user BACK to the code step with the error
// shown there, because "that code is incorrect" sitting over the password
// fields points at the wrong input. The password controllers keep their
// text across that bounce, so fixing the code does not mean retyping it.
//
// Pops with `true` on success so the caller (auth_screen.dart) knows to
// show a confirmation and land back on Sign In, per the "after the
// password is changed they are taken back to the sign in page" request.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const int _stepEmail = 0;
  static const int _stepCode = 1;
  static const int _stepPassword = 2;

  final PageController _pageController = PageController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = _stepEmail;
  bool _busy = false;
  String? _error;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _newPasswordController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pageController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String _hashOf(String s) => sha256.convert(utf8.encode(s)).toString();

  /// Moves between the three pages. Clears any error on the way, so one
  /// step's complaint is never left sitting over another step's fields —
  /// pass `keepError: true` when the error is the reason for the move.
  void _goToStep(int step, {bool keepError = false}) {
    setState(() {
      _step = step;
      if (!keepError) _error = null;
    });
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _requestCode() async {
    final email = _emailController.text.trim();
    final emailError = validateEmail(email);
    if (emailError != null) {
      setState(() => _error = emailError);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.functions.invoke(
        'send-password-reset-otp',
        body: {'email': email},
      );
      // Always proceeds regardless of whether an account exists for that
      // email — same enumeration-resistance reasoning as the Edge
      // Function itself; a "no account found" message here would defeat
      // the point of that design.
      if (mounted) {
        setState(() => _busy = false);
        // "Resend code" is wired here too. From the code step that is a
        // refresh, not a navigation, so only advance off the email step.
        if (_step == _stepEmail) _goToStep(_stepCode);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeAuthException(e);
      });
    }
  }

  /// Local shape check only — see the header comment for why the code
  /// cannot actually be verified until the new password is submitted.
  void _continueFromCode() {
    if (_otpController.text.trim().length != 6) {
      setState(() => _error = "Enter the 6-digit code from your email.");
      return;
    }
    _goToStep(_stepPassword);
  }

  Future<void> _submitNewPassword() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      // Only reachable if the code was cleared after passing the code step.
      setState(() => _error = "Enter the 6-digit code from your email.");
      _goToStep(_stepCode, keepError: true);
      return;
    }
    final pwError = validatePassword(_newPasswordController.text);
    if (pwError != null) {
      setState(() => _error = pwError);
      return;
    }
    if (_newPasswordController.text != _confirmPasswordController.text) {
      setState(() => _error = "Passwords don't match.");
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // See mesh_crypto.dart's header comment for the salted-hashing
      // scheme — a fresh salt for this new password, same as signup and
      // change-password. The OTP hash itself stays plain sha256 (_hashOf)
      // — it's a random, short-lived, attempt-capped code, not a
      // long-lived credential, so it doesn't need the same protection.
      final newSalt = generatePasswordSalt();
      final ok = await Supabase.instance.client.rpc('verify_password_reset_otp', params: {
        'p_email': _emailController.text.trim(),
        'p_otp_hash': _hashOf(otp),
        'p_new_password_hash': hashSaltedPassword(_newPasswordController.text, newSalt),
        'p_new_password_salt': newSalt,
      }) as bool;

      if (!mounted) return;
      if (!ok) {
        // The only thing the server rejects at this point is the code, so
        // the message belongs on the code step rather than over the
        // password fields the user just filled in correctly.
        setState(() {
          _busy = false;
          _error = "That code is incorrect or has expired — check your email or request a new one.";
        });
        _goToStep(_stepCode, keepError: true);
        return;
      }

      Navigator.of(context).pop(true);
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text("Reset Password", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step > _stepEmail) {
              _goToStep(_step - 1);
            } else {
              Navigator.of(context).pop(false);
            }
          },
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.6, -0.4),
            radius: 1.2,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(
          child: SafeArea(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildEmailStep(colors),
                _buildCodeStep(colors),
                _buildNewPasswordStep(colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmailStep(ColorScheme colors) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mail_lock_outlined, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text("Forgot your password?", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: colors.primary)),
          const SizedBox(height: 8),
          Text(
            "Enter the email you signed up with — we'll send a 6-digit code to reset your password.",
            style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 24),
          if (_error != null) _buildErrorBanner(colors),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            style: TextStyle(fontSize: 14, color: colors.onSurface),
            decoration: InputDecoration(
              labelText: "Email",
              hintText: "you@hops.edu",
              prefixIcon: const Icon(Icons.mail_outline, size: 20),
              filled: true,
              fillColor: colors.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
            onSubmitted: (_) => _busy ? null : _requestCode(),
          ),
          const SizedBox(height: 24),
          _buildPrimaryButton(colors, label: "Send Reset Code", onPressed: _requestCode),
        ],
      ),
    );
  }

  Widget _buildCodeStep(ColorScheme colors) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mark_email_read_outlined, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text("Check your email", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: colors.primary)),
          const SizedBox(height: 8),
          Text(
            "Enter the 6-digit code we sent to ${_emailController.text.trim()}.",
            style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 24),
          if (_error != null) _buildErrorBanner(colors),
          TextField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            textInputAction: TextInputAction.done,
            style: TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.bold, color: colors.primary),
            decoration: InputDecoration(
              counterText: "",
              hintText: "······",
              filled: true,
              fillColor: colors.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onSubmitted: (_) => _busy ? null : _continueFromCode(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _requestCode,
              child: Text("Resend code", style: TextStyle(color: colors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          _buildPrimaryButton(colors, label: "Continue", onPressed: _continueFromCode),
        ],
      ),
    );
  }

  Widget _buildNewPasswordStep(ColorScheme colors) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_reset_outlined, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text("Choose a new password", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: colors.primary)),
          const SizedBox(height: 8),
          Text(
            "This replaces the password on your account — you'll sign in with it next time.",
            style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 24),
          if (_error != null) _buildErrorBanner(colors),
          TextField(
            controller: _newPasswordController,
            obscureText: _obscurePassword,
            style: TextStyle(fontSize: 14, color: colors.onSurface),
            decoration: InputDecoration(
              labelText: "New password",
              prefixIcon: const Icon(Icons.lock_outline, size: 20),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, size: 20),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
              filled: true,
              fillColor: colors.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
          ),
          PasswordStrengthBar(password: _newPasswordController.text),
          const SizedBox(height: 16),
          TextField(
            controller: _confirmPasswordController,
            obscureText: _obscurePassword,
            style: TextStyle(fontSize: 14, color: colors.onSurface),
            decoration: InputDecoration(
              labelText: "Confirm new password",
              prefixIcon: const Icon(Icons.lock_outline, size: 20),
              filled: true,
              fillColor: colors.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
            onSubmitted: (_) => _busy ? null : _submitNewPassword(),
          ),
          const SizedBox(height: 24),
          _buildPrimaryButton(colors, label: "Change Password", onPressed: _submitNewPassword),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton(ColorScheme colors,
      {required String label, required VoidCallback onPressed}) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
        ),
        onPressed: _busy ? null : onPressed,
        child: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildErrorBanner(ColorScheme colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
        ],
      ),
    );
  }
}
