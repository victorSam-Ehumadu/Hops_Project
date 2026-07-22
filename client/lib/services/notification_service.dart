import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  static final AndroidNotificationChannel _emergencyChannel =
  const AndroidNotificationChannel(
    'emergency_flare',
    'Emergency Flare',
    description: 'Critical alerts from Hops mesh',
    importance: Importance.max,
    enableVibration: true,
    playSound: false,                // we control sound ourselves
    // sound: RawResourceAndroidNotificationSound('alert'),   // optional custom sound
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
        if (response.actionId == 'dismiss' || response.actionId == null) {
          _stopAlertSound();
          _plugin.cancel(0);
        }
      },
    );
  }

  static Future<void> showEmergencyNotification({
    required String sender,
    required String reason,
  }) async {
    // Stop any previous alert that might still be playing
    _stopAlertSound();

    // Start looping the alarm sound
    _alertPlayer = AudioPlayer();
    try {
      // Use a built‑in alarm sound from the system, or your custom asset
      await _alertPlayer!.setAsset('assets/sounds/alert.wav');
      await _alertPlayer!.setLoopMode(LoopMode.one);
      await _alertPlayer!.play();
    } catch (e) {
      // Fallback: use the default notification sound via the channel
      // (the channel's sound will still play because we'll set playSound: true later)
    }

    await _plugin.show(
      0,
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
          playSound: _alertPlayer == null,   // only fallback if our player failed
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,                      // keep it alive
          autoCancel: false,                  // dismiss only by our action
          actions: [
            const AndroidNotificationAction(
              'dismiss',
              'Deactivate',
              showsUserInterface: true,
              cancelNotification: false,      // we cancel manually
            ),
          ],
        ),
      ),
    );
  }

  static void _stopAlertSound() {
    _alertPlayer?.stop();
    _alertPlayer?.dispose();
    _alertPlayer = null;
  }
}