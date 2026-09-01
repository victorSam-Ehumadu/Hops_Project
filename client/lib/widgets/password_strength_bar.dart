import 'package:flutter/material.dart';
import 'package:client/utils/password_policy.dart';

// Shared between the sign-up form (auth_screen.dart) and the in-app
// "Change Password" screen (account_management_screen.dart). Purely a
// visual nudge toward a stronger-than-minimum password — the actual pass/
// fail gate is validatePassword() in password_policy.dart, not this.
class PasswordStrengthBar extends StatelessWidget {
  final String password;
  const PasswordStrengthBar({super.key, required this.password});

  (String, Color, double) _display(ColorScheme colors, PasswordStrength s) {
    switch (s) {
      case PasswordStrength.veryWeak:
        return ("Very weak", Colors.red, 0.2);
      case PasswordStrength.weak:
        return ("Weak", Colors.deepOrange, 0.4);
      case PasswordStrength.fair:
        return ("Fair", Colors.amber.shade700, 0.6);
      case PasswordStrength.strong:
        return ("Strong", Colors.lightGreen.shade700, 0.8);
      case PasswordStrength.veryStrong:
        return ("Very strong", Colors.green.shade700, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final strength = scorePasswordStrength(password);
    final (label, color, fraction) = _display(colors, strength);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(100),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction),
              duration: const Duration(milliseconds: 250),
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 5,
                backgroundColor: colors.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Password strength: $label",
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
