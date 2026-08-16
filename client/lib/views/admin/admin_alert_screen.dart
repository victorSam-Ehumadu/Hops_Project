// lib/views/admin/admin_alert_screen.dart
//
// Official Alert composer — sends ADM:/ADM_OFF: (moved here from the
// student app entirely; radar_screen.dart/hops_app.dart now only receive
// one).
//
// Was a nav-bar tab paired with a "Listening Post" list. Both are gone:
//
//   * Broadcasting a campus-wide alert is a rare, deliberate act. Giving it
//     a permanent seat in the nav bar spent a fifth of the app's most
//     valuable real estate on something used once a term, and put a
//     one-tap path to a siren next to the tabs people use constantly.
//     It's now reached from the Dashboard, behind a confirmation.
//   * The Listening Post was a pure view over AdminBleHub.liveAlerts and
//     monitored nothing itself — detection, signature verification and the
//     alarm all live in the hub (see its header). Live alerts now surface
//     on the Dashboard, where an admin is actually looking, instead of on
//     a tab someone had to remember to open.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/official_alert_service.dart';

class AdminAlertScreen extends StatefulWidget {
  const AdminAlertScreen({super.key});

  @override
  State<AdminAlertScreen> createState() => _AdminAlertScreenState();
}

class _AdminAlertScreenState extends State<AdminAlertScreen> {
  final _service = OfficialAlertService.instance;
  final _reasonController = TextEditingController();
  String? _myUsername;
  bool _sending = false;
  String? _error;
  Timer? _countdownTimer;
  int _secondsRemaining = 0;

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _service.isActive.addListener(_onActiveChanged);
  }

  @override
  void dispose() {
    _service.isActive.removeListener(_onActiveChanged);
    _countdownTimer?.cancel();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _myUsername = prefs.getString('my_username'));
  }

  void _onActiveChanged() {
    if (!mounted) return;
    if (_service.isActive.value) {
      _secondsRemaining = 30;
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _secondsRemaining = (_secondsRemaining - 1).clamp(0, 30));
        if (_secondsRemaining <= 0) t.cancel();
      });
    } else {
      _countdownTimer?.cancel();
    }
    setState(() {});
  }

  Future<void> _confirmAndSend() async {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = "Enter what the alert is about.");
      return;
    }
    final username = _myUsername;
    if (username == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Issue Official Alert?"),
        content: Text(
          "This sets off an alarm on every nearby Hops device — including "
          "phones that are locked or in a pocket — for 30 seconds, signed as "
          "\"$username\":\n\n\"$reason\"",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("BROADCAST"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _sending = true;
      _error = null;
    });
    final ok = await _service.broadcast(myUsername: username, reason: reason);
    if (mounted) {
      setState(() {
        _sending = false;
        _error = ok ? null : "Failed to start broadcasting — check Bluetooth is on and try again.";
      });
      if (ok) _reasonController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Official Alert", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: _service.isActive,
        builder: (context, active, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: active ? _buildActive() : _buildComposer(colors),
        ),
      ),
    );
  }

  Widget _buildActive() {
    return Card(
      color: Colors.red.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.campaign, color: Colors.white, size: 44),
            const SizedBox(height: 10),
            const Text("Alert is broadcasting",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 4),
            Text("Auto-cancels in ${_secondsRemaining}s",
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _service.cancel(),
                child: const Text("CANCEL ALERT"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.shade900.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.red.shade900.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red.shade900, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "Sets off a full alarm on every Hops device in range for 30 seconds, "
                  "including locked phones. Signed with your admin key so receivers can "
                  "verify it's genuine.",
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: colors.onSurface.withValues(alpha: 0.75)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _reasonController,
          maxLength: 25,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: "What is the alert?",
            hintText: "e.g. Campus lockdown",
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            // 25 characters isn't a design preference — the whole alert has
            // to fit in a BLE advertisement name alongside the prefix and
            // signature. See hops_constants.dart.
            helperText: "Kept short so it fits in a single Bluetooth broadcast",
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: (_sending || _myUsername == null) ? null : _confirmAndSend,
            icon: _sending
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.campaign),
            label: const Text("BROADCAST OFFICIAL ALERT",
                style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.4)),
          ),
        ),
      ],
    );
  }
}
