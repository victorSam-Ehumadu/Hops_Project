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
  late String _code;
  int _timeLeftSeconds = 180;
  Timer? _tickerTimer;

  @override
  void initState() {
    super.initState();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    _code =
        List.generate(6, (i) => chars[Random().nextInt(chars.length)]).join();
    widget.onCodeGenerated(_code);
    _startCountdown();
  }

  void _startCountdown() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_timeLeftSeconds > 0) {
        setState(() => _timeLeftSeconds--);
      } else {
        _tickerTimer?.cancel();
        Navigator.pop(context);
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
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    String formattedTime =
        "${(_timeLeftSeconds ~/ 60)}:${(_timeLeftSeconds % 60).toString().padLeft(2, '0')}";
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.qr_code_2, size: 40, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          const Text("Your Pairing Code",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12)),
              child: SelectableText(
                formattedCode,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Share this code with your peer.",
            style: TextStyle(fontSize: 11, color: Colors.black54),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
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
          const Text(
            "Waiting for peer to connect...",
            style: TextStyle(fontSize: 11, color: Colors.black45),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(100))),
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel",
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary)),
            ),
          ),
        ],
      ),
    );
  }
}