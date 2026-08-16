import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/utils/auth_error_messages.dart';
import 'package:client/widgets/hops_background_pattern.dart';

// Shown right after sign-up (and reusable after Account Management >
// Change Email) to confirm the account's email actually belongs to
// whoever's signing up — "a suggested form of email verification" per the
// original ask, implemented as: send a 6-digit code (send-verification-
// email Edge Function), let them enter it (verify_signup_email_otp RPC).
//
// Deliberately skippable — this app works entirely offline once signed
// in, and hard-blocking account creation on an email round-trip would be
// a worse trade-off than just nudging. HopsProfileScreen/Account
// Management can offer "resend verification" later for anyone who skips.
class EmailVerificationScreen extends StatefulWidget {
  final String email;
  const EmailVerificationScreen({super.key, required this.email});

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final _otpController = TextEditingController();
  bool _busy = false;
  bool _sending = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sendCode();
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  String _hashOf(String s) => sha256.convert(utf8.encode(s)).toString();

  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('saved_hops_token');
  }

  Future<void> _sendCode() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final token = await _getToken();
      await Supabase.instance.client.functions.invoke(
        'send-verification-email',
        body: {'hops_token': token},
      );
    } catch (e) {
      if (mounted) setState(() => _error = describeAuthException(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
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
      final token = await _getToken();
      final ok = await Supabase.instance.client.rpc('verify_signup_email_otp', params: {
        'p_hops_token': token,
        'p_otp_hash': _hashOf(otp),
      }) as bool;

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = "That code is incorrect or has expired — try again or resend the code.";
        });
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
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Icon(Icons.mark_email_read_outlined, size: 56, color: colors.primary),
                  const SizedBox(height: 20),
                  Text("Verify your email", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colors.primary)),
                  const SizedBox(height: 10),
                  Text(
                    _sending
                        ? "Sending a code to ${widget.email}…"
                        : "We sent a 6-digit code to ${widget.email}. Enter it below to confirm it's really yours.",
                    style: TextStyle(fontSize: 14, color: colors.onSurface.withValues(alpha: 0.65), height: 1.4),
                  ),
                  const SizedBox(height: 28),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    enabled: !_sending,
                    style: TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.bold, color: colors.primary),
                    decoration: InputDecoration(
                      counterText: "",
                      hintText: "······",
                      filled: true,
                      fillColor: colors.surfaceContainerHighest,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _sending || _busy ? null : _sendCode,
                      child: Text("Resend code", style: TextStyle(color: colors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      ),
                      onPressed: _busy || _sending ? null : _verify,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text("Verify", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                      child: Text("Skip for now", style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
