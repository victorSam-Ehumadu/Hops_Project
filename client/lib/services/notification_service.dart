import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';

class NotificationService {
  static const int _emgNotificationId = 0; // fixed — used by show AND cancel

  static final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  static final AndroidNotificationChannel _emergencyChannel =
  const AndroidNotificationChannel(
    'emergency_flare',
    'Emergency Flare',
    description: 'Critical alerts from Hops mesh',
    importance: Importance.max,
    enableVibration: true,
    playSound: false, // we control sound ourselves
  );

  static AudioPlayer? _alertPlayer;

  static Future<void> init() async {
    final android = AndroidFlutterLocalNotificationsPlugin();
    await android.requestNotificationsPermission();
    await android.createNotificationChannel(_emergencyChannel);

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

    await _plugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // User tapped "Deactivate" on the notification itself
        if (response.actionId == 'dismiss' || response.actionId == null) {
          cancelEmergencyNotification();
        }
      },
    );
  }

  // ── Show (called when an EMG: advertisement is first received) ────────────

  static Future<void> showEmergencyNotification({
    required String sender,
    required String reason,
  }) async {
    // Stop any previous alert still playing before starting a new one
    await _stopAlertSound();

    // Start looping alarm sound
    _alertPlayer = AudioPlayer();
    try {
      await _alertPlayer!.setAsset('assets/sounds/alert.wav');
      await _alertPlayer!.setLoopMode(LoopMode.one);
      await _alertPlayer!.play();
    } catch (_) {
      // Audio failed — notification channel sound acts as fallback
    }

    await _plugin.show(
      _emgNotificationId,
      '🚨 Emergency from $sender',
      reason.isNotEmpty ? reason : 'Emergency alert!',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _emergencyChannel.id,
          _emergencyChannel.name,
          channelDescription: _emergencyChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          enableVibration: true,
          playSound: _alertPlayer == null, // fallback if our player failed
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,     // keeps the notification alive
          autoCancel: false, // only dismissed by our cancel call
          actions: [
            const AndroidNotificationAction(
              'dismiss',
              'Deactivate',
              showsUserInterface: true,
              cancelNotification: false, // we cancel manually below
            ),
          ],
        ),
      ),
    );
  }

  // ── Cancel (called when EMG_OFF: is received OR user taps Deactivate) ─────
  // Stops the looping audio AND removes the persistent notification.

  static Future<void> cancelEmergencyNotification() async {
    await _stopAlertSound();
    await _plugin.cancel(_emgNotificationId);
  }

  // ── Internal audio helper ─────────────────────────────────────────────────

  static Future<void> _stopAlertSound() async {
    await _alertPlayer?.stop();
    await _alertPlayer?.dispose();
    _alertPlayer = null;
  }
}