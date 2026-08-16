import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

class TokenGeneratorWorkspace extends StatefulWidget {
  final Function(String code) onCodeGenerated;
  const TokenGeneratorWorkspace({super.key, required this.onCodeGenerated});
  @override
  State<TokenGeneratorWorkspace> createState() =>
      _TokenGeneratorWorkspaceState();
}

class _TokenGeneratorWorkspaceState extends State<TokenGeneratorWorkspace> {
  static const int _codeLifetimeSeconds = 180;

  late String _code;
  int _timeLeftSeconds = _codeLifetimeSeconds;
  Timer? _tickerTimer;
  bool get _expired => _timeLeftSeconds <= 0;

  @override
  void initState() {
    super.initState();
    _generateNewCode();
  }

  void _generateNewCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    _code =
        List.generate(6, (i) => chars[Random().nextInt(chars.length)]).join();
    _timeLeftSeconds = _codeLifetimeSeconds;
    widget.onCodeGenerated(_code);
    _startCountdown();
  }

  void _startCountdown() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_timeLeftSeconds > 0) {
        setState(() => _timeLeftSeconds--);
      } else {
        // Used to Navigator.pop(context) here — the dialog just vanished
        // with no explanation, which looked like a glitch mid-pairing.
        // Show an expired state instead and let the user decide whether
        // to generate a fresh code or close.
        _tickerTimer?.cancel();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  String get formattedCode =>
      "HPS-${_code.substring(0, 3)}-${_code.substring(3, 6)}";

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    String formattedTime =
        "${(_timeLeftSeconds ~/ 60)}:${(_timeLeftSeconds % 60).toString().padLeft(2, '0')}";
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.confirmation_number_outlined, size: 40, color: colors.primary),
          const SizedBox(height: 12),
          Text("Your Pairing Code",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: colors.onSurface)),
          const SizedBox(height: 16),
          Opacity(
            opacity: _expired ? 0.3 : 1.0,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12)),
                child: SelectableText(
                  formattedCode,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 22,
                      fontFamily: 'monospace',
                      color: colors.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                      decoration: _expired ? TextDecoration.lineThrough : null),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Share this code with your peer.",
            style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.6)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          if (_expired) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer_off_outlined, size: 16, color: colors.onSurface.withValues(alpha: 0.5)),
                const SizedBox(width: 6),
                Text(
                  "This code has expired",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.onSurface.withValues(alpha: 0.6),
                      fontSize: 13),
                ),
              ],
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.timer_outlined,
                    size: 16, color: Colors.redAccent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    "Expires in: $formattedTime",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                        fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "Waiting for peer to connect...",
              style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.45)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 16),
          if (_expired)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text("Generate New Code"),
                onPressed: () => setState(_generateNewCode),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(100))),
              onPressed: () => Navigator.pop(context),
              child: Text(_expired ? "Close" : "Cancel",
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: colors.primary)),
            ),
          ),
        ],
      ),
    );
  }
}
