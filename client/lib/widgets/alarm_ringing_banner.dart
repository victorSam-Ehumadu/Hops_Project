// lib/widgets/alarm_ringing_banner.dart
//
// "This is ringing — stop it for me" banner. Shown at the top of both
// HopsApp and AdminShell whenever NotificationService.isAlarmRinging is
// true, which covers every case an alarm can be sounding on this device:
// this device's own Emergency Flare, someone else's flare received nearby,
// or an Official Alert.
//
// The notification itself already carries a "Stop for me" action button
// that does exactly this (see notification_service.dart) — that's local-
// only, tied to whichever device is physically ringing, and was already
// correct. What it lacked was discoverability: it only helps if you think
// to pull down the notification shade, which isn't the obvious first move
// with a phone blaring in your hand. This is the same action surfaced
// somewhere you're already looking.
//
// Deliberately not the same thing as cancelling a flare for everyone — a
// student's own SnackBar "CANCEL" action on the flare they just triggered
// (see hops_app.dart's _broadcastEmergencyFlare) still does that, still
// broadcasts EMG_OFF, and stays exactly as it was. This banner only ever
// calls NotificationService.cancelEmergencyNotification(), which touches
// no radio and tells nobody else anything.
import 'package:flutter/material.dart';
import 'package:client/services/notification_service.dart';

class AlarmRingingBanner extends StatelessWidget {
  const AlarmRingingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NotificationService.isAlarmRinging,
      builder: (context, ringing, _) {
        if (!ringing) return const SizedBox.shrink();
        return SafeArea(
          bottom: false,
          child: Material(
            color: Colors.red.shade900,
            child: InkWell(
              onTap: () => NotificationService.cancelEmergencyNotification(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: Colors.white, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        "An alarm is ringing on this device",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () => NotificationService.cancelEmergencyNotification(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.15),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text("Stop for me", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
