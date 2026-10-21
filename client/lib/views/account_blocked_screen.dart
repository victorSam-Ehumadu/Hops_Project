// The barrier shown when the signed-in account is suspended or banned.
//
// Replaces what used to happen, which was nothing visible: the poll that
// noticed a ban called wipeLocalIdentityAndReturnToGatekeeper and the user
// was simply back at the sign-in page with no explanation, while a
// suspension did not even manage that. Telling someone why they cannot get
// in is not a courtesy here — without it the only available reading is
// "the app is broken", which is both wrong and the kind of thing that gets
// reported as a bug instead of appealed.
//
// Two jobs beyond explaining:
//
//   * It takes the radio down on the way in. A moderated account must stop
//     broadcasting its presence beacon and must stop relaying, and that has
//     to happen whether or not the user cooperates with any button on this
//     screen.
//   * A suspension lifts itself. The expiry is known locally (see
//     account_standing.dart), so a ticking countdown is honest and the
//     screen can let the user back in the moment it lapses, with no
//     network round trip. A ban has no expiry and offers only Sign out and
//     Check again — the latter because an unban is real and the user
//     should not have to guess when it has happened.
import 'dart:async';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/services/account_standing.dart';
import 'package:client/services/bluetooth_name_guard.dart';
import 'package:client/views/account_management_screen.dart'
    show wipeLocalIdentityAndReturnToGatekeeper;
import 'package:client/widgets/hops_background_pattern.dart';

class AccountBlockedScreen extends StatefulWidget {
  final AccountStanding standing;

  /// Called when the block has lifted — either the countdown lapsed or a
  /// re-check came back clean. The caller decides where to go next, since
  /// this screen is reachable both from the launch path and from inside a
  /// running HopsApp.
  final VoidCallback onCleared;

  const AccountBlockedScreen({
    super.key,
    required this.standing,
    required this.onCleared,
  });

  @override
  State<AccountBlockedScreen> createState() => _AccountBlockedScreenState();
}

class _AccountBlockedScreenState extends State<AccountBlockedScreen> {
  late AccountStanding _standing;
  Timer? _countdown;
  bool _checking = false;
  String? _checkResult;

  @override
  void initState() {
    super.initState();
    _standing = widget.standing;
    _silenceRadio();
    if (_standing.kind == AccountStandingKind.suspended) {
      // One tick a second only to keep the remaining-time text honest;
      // the lapse check itself is what matters.
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (!_standing.blocksUse) {
          _countdown?.cancel();
          AccountStandingStore.instance.clear().then((_) {
            if (mounted) widget.onCleared();
          });
          return;
        }
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  /// Off the air, and the adapter name put back. Best-effort by design:
  /// every call here can legitimately fail on a device with Bluetooth
  /// switched off, and none of those failures should stop the barrier
  /// rendering.
  Future<void> _silenceRadio() async {
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await BluetoothNameGuard.restore();
    } catch (_) {}
  }

  Future<void> _recheck() async {
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) {
      // No session left to ask about — nothing to re-check, and signing
      // out is the only coherent action from here.
      if (mounted) {
        setState(() {
          _checking = false;
          _checkResult = "You're signed out on this device.";
        });
      }
      return;
    }
    final result = await AccountStandingStore.instance.refresh(token);
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _checking = false;
        _checkResult = "Couldn't reach the server — check your connection.";
      });
      return;
    }
    if (!result.blocksUse) {
      widget.onCleared();
      return;
    }
    setState(() {
      _standing = result;
      _checking = false;
      _checkResult = result.kind == AccountStandingKind.banned
          ? "This account is still banned."
          : "This account is still suspended.";
    });
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sign out?"),
        content: const Text(
          "This removes the account and its messages, tasks and vibe "
          "records from this phone. It does not undo the moderator's "
          "decision.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Sign out")),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AccountStandingStore.instance.clear();
    if (!mounted) return;
    await wipeLocalIdentityAndReturnToGatekeeper(context);
  }

  String get _remaining {
    final until = _standing.until;
    if (until == null) return '';
    final left = until.difference(DateTime.now().toUtc());
    if (left.isNegative) return 'any moment now';
    if (left.inDays >= 1) {
      final days = left.inDays;
      final hours = left.inHours % 24;
      return '$days ${days == 1 ? 'day' : 'days'}'
          '${hours > 0 ? ', $hours ${hours == 1 ? 'hour' : 'hours'}' : ''}';
    }
    if (left.inHours >= 1) {
      final hours = left.inHours;
      final mins = left.inMinutes % 60;
      return '$hours ${hours == 1 ? 'hour' : 'hours'}'
          '${mins > 0 ? ', $mins min' : ''}';
    }
    if (left.inMinutes >= 1) return '${left.inMinutes} min';
    return 'less than a minute';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final banned = _standing.kind == AccountStandingKind.banned;

    // Back-navigation closed off: this is a barrier, not a page. Without
    // this, the system back gesture on the in-app route would reveal
    // whatever was underneath.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: colors.surface,
        body: HopsBackgroundPattern(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        banned ? Icons.gavel_rounded : Icons.timer_off_rounded,
                        size: 56,
                        color: banned ? colors.error : colors.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        banned
                            ? "This account has been banned"
                            : "This account is suspended",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        banned
                            ? "A moderator has permanently removed access for "
                                "this account. Hops can't be used while it is "
                                "banned."
                            : "A moderator has temporarily removed access for "
                                "this account. It unlocks on its own when the "
                                "suspension ends — you don't need to do "
                                "anything.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: colors.onSurface.withValues(alpha: 0.78),
                        ),
                      ),
                      if (!banned) ...[
                        const SizedBox(height: 20),
                        _infoTile(
                          colors,
                          label: "Time remaining",
                          value: _remaining,
                        ),
                      ],
                      if (_standing.reason != null) ...[
                        const SizedBox(height: 12),
                        _infoTile(
                          colors,
                          label: "Reason given",
                          value: _standing.reason!,
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (_checkResult != null) ...[
                        Text(
                          _checkResult!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: colors.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      FilledButton.icon(
                        onPressed: _checking ? null : _recheck,
                        icon: _checking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(_checking ? "Checking…" : "Check again"),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _signOut,
                        child: const Text("Sign out of this device"),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        "Emergency Flares from other people are not received "
                        "while an account is blocked. If you are in danger, "
                        "call campus security or your local emergency number.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: colors.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoTile(ColorScheme colors,
      {required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
