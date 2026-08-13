import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';

class NotificationService {
  static const int _emgNotificationId = 0; // fixed — used by show AND cancel

  // Fixed ids for the routine notification kinds below — each kind reuses
  // its own id so a second occurrence updates/replaces the first rather
  // than piling up (e.g. two friend requests in a row show as one
  // notification with the latest sender, not two separate notifications).
  // Chat is the one exception — it's bucketed per-peer so messages from
  // different people don't overwrite each other.
  static const int _friendRequestNotificationId = 200;
  static const int _friendAcceptedNotificationId = 201;
  static const int _watchRequestNotificationId = 202;
  static const int _watchAcceptedNotificationId = 203;
  static const int _watchMeAlertNotificationId = 204;
  static const int _adminRequestSubmittedNotificationId = 205;
  static const int _adminRequestApprovedNotificationId = 206;
  static const int _fileReceivedNotificationId = 207;
  static const int _taskReminderNotificationId = 208;
  static const int _chatNotificationIdBase = 90000;

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

  // Safety-adjacent but not a full alarm — a disappeared/weak-signal Watch
  // Me buddy deserves to cut through more than a routine notification, but
  // shouldn't hijack the screen with a full-screen intent + siren the way
  // an actual Emergency Flare does.
  static final AndroidNotificationChannel _watchMeChannel =
  const AndroidNotificationChannel(
    'watch_me_alert',
    'Watch Me Alerts',
    description: 'Buddy safety alerts from Watch Me',
    importance: Importance.high,
    enableVibration: true,
  );

  // Everything routine — chat messages, friend/watch requests and
  // accepts, file transfers, admin-request activity, task reminders.
  // Deliberately one shared channel: these are all "something happened,
  // no rush" events, and giving every kind its own channel would just be
  // extra notification-settings clutter for the user with no real benefit.
  static final AndroidNotificationChannel _activityChannel =
  const AndroidNotificationChannel(
    'general_activity',
    'Hops Activity',
    description: 'Messages, requests, and other Hops activity',
    importance: Importance.high,
  );

  static AudioPlayer? _alertPlayer;

  static Future<void> init() async {
    final android = AndroidFlutterLocalNotificationsPlugin();
    await android.requestNotificationsPermission();
    await android.createNotificationChannel(_emergencyChannel);
    await android.createNotificationChannel(_watchMeChannel);
    await android.createNotificationChannel(_activityChannel);

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

  // ── Generic routine notification ──────────────────────────────────────────
  // Backing implementation for every "something happened" notification
  // below — the emergency/official-alert flows above stay separate since
  // they have real special-case behavior (looping audio, verification
  // upgrades, full-screen intent) that would just clutter a shared helper.
  static Future<void> _showActivity({
    required int id,
    required String title,
    required String body,
    AndroidNotificationChannel? channel,
  }) async {
    final ch = channel ?? _activityChannel;
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          ch.id,
          ch.name,
          channelDescription: ch.description,
          importance: ch.importance,
          priority: Priority.high,
        ),
      ),
    );
  }

  // ── Chat (bucketed per-peer so different conversations don't clobber
  // each other's notification) ────────────────────────────────────────────
  static Future<void> showChatMessageNotification({
    required String peerUsername,
    required String message,
  }) {
    final id = _chatNotificationIdBase + (peerUsername.hashCode.abs() % 9000);
    return _showActivity(id: id, title: peerUsername, body: message);
  }

  // Fired when a CHT: ping (see hops_app.dart) arrives from someone who
  // has a chat open with you right now but isn't connected yet — they're
  // not in the same nearby_connections session, so there's no message
  // payload to show yet, just an invite to go open the conversation so
  // the two sides can actually connect. Bucketed with the same id scheme
  // as a real chat message so this and an eventual real message from the
  // same peer replace each other instead of piling up.
  static Future<void> showChatInviteNotification({required String sender}) {
    final id = _chatNotificationIdBase + (sender.hashCode.abs() % 9000);
    return _showActivity(
      id: id,
      title: sender,
      body: "Wants to chat — open your conversation with them to connect",
    );
  }

  static Future<void> showFriendRequestNotification({required String sender}) =>
      _showActivity(
        id: _friendRequestNotificationId,
        title: "Friend request",
        body: "$sender wants to add you",
      );

  static Future<void> showFriendAcceptedNotification({required String username}) =>
      _showActivity(
        id: _friendAcceptedNotificationId,
        title: "Friend added",
        body: "$username accepted your friend request",
      );

  static Future<void> showWatchRequestNotification({required String sender}) =>
      _showActivity(
        id: _watchRequestNotificationId,
        title: "Watch Me request",
        body: "$sender wants you to watch their safety signal",
      );

  static Future<void> showWatchAcceptedNotification({required String username}) =>
      _showActivity(
        id: _watchAcceptedNotificationId,
        title: "Watch Me request accepted",
        body: "$username accepted your watch request",
      );

  // Fires alongside (not instead of) the existing in-app alert dialog —
  // the dialog only ever helped while Watch Me happened to be the screen
  // on top; this is what actually reaches someone who's elsewhere in the
  // app or has it backgrounded.
  static Future<void> showWatchMeAlertNotification({required String message}) =>
      _showActivity(
        id: _watchMeAlertNotificationId,
        title: "⚠️ Watch Me Alert",
        body: message,
        channel: _watchMeChannel,
      );

  static Future<void> showFileReceivedNotification({
    required String sender,
    required String fileName,
  }) =>
      _showActivity(
        id: _fileReceivedNotificationId,
        title: "File received",
        body: "$fileName from $sender",
      );

  // Admin-only — see hops_app.dart's periodic admin-request poll. There's
  // no push-notification infrastructure in this app (no FCM — it's a
  // peer-to-peer BLE mesh with a minimal Supabase backend), so this can
  // only ever reflect what a periodic pull found, not a true instant push.
  static Future<void> showAdminRequestSubmittedNotification({required int pendingCount}) =>
      _showActivity(
        id: _adminRequestSubmittedNotificationId,
        title: "Admin access requested",
        body: pendingCount == 1
            ? "1 request is waiting for review"
            : "$pendingCount requests are waiting for review",
      );

  static Future<void> showAdminRequestApprovedNotification() => _showActivity(
        id: _adminRequestApprovedNotificationId,
        title: "Admin access granted",
        body: "You can now issue Official Alerts — see your Profile.",
      );

  static Future<void> showTaskReminderNotification({required String taskTitle}) =>
      _showActivity(
        id: _taskReminderNotificationId,
        title: "Task due",
        body: "'$taskTitle' is due now",
      );

  // ── Show (called when an EMG: advertisement is first received) ────────────

  static Future<void> showEmergencyNotification({
    required String sender,
    required String reason,
  }) async {
    // Stop any previous alert still playing before starting a new one
    await _stopAlertSound();

    // Start looping alarm sound. Track success separately from whether
    // _alertPlayer is null — it's assigned unconditionally below, so
    // `_alertPlayer == null` was never true here even when setAsset/play
    // threw, which meant the "fall back to the channel's own sound"
    // branch a few lines down could never actually trigger and a failed
    // asset load meant a silent (vibrate-only) emergency alert.
    _alertPlayer = AudioPlayer();
    bool customSoundPlaying = false;
    try {
      await _alertPlayer!.setAsset('assets/sounds/alert.wav');
      await _alertPlayer!.setLoopMode(LoopMode.one);
      await _alertPlayer!.play();
      customSoundPlaying = true;
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
          playSound: !customSoundPlaying, // fallback if our player failed
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

  // ── Verification upgrade (called once a flare's signature chunks have
  // fully arrived and been checked against the sender's public key — see
  // hops_app.dart's _verifyFlareSignature) ──────────────────────────────────
  // Re-shows the same notification id with an updated title only; doesn't
  // touch _alertPlayer, so the already-looping alarm sound isn't
  // interrupted just to relabel the alert a few seconds later.

  static Future<void> updateEmergencyVerificationStatus({
    required String sender,
    required String reason,
    required bool verified,
  }) async {
    final title = verified
        ? '✅ Verified Emergency from $sender'
        : '⚠️ Unverified Emergency from $sender';
    await _plugin.show(
      _emgNotificationId,
      title,
      reason.isNotEmpty ? reason : 'Emergency alert!',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _emergencyChannel.id,
          _emergencyChannel.name,
          channelDescription: _emergencyChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          enableVibration: false, // already vibrated on the initial show
          playSound: false, // audio is already looping from the initial show
          category: AndroidNotificationCategory.alarm,
          ongoing: true,
          autoCancel: false,
          actions: [
            const AndroidNotificationAction(
              'dismiss',
              'Deactivate',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  // ── Official Alert (admin-only tier, ADM:/ADM_OFF:) ───────────────────────
  // Reuses the same notification id/channel/audio player as a personal
  // Emergency Flare rather than duplicating that whole plumbing — the two
  // are extremely unlikely to be simultaneously active (Official Alerts are
  // gated to a small, trusted admin group), and if they ever do overlap,
  // showing whichever is most recent isn't an unreasonable behavior anyway.

  static Future<void> showOfficialAlertNotification({
    required String sender,
    required String reason,
    String? adminTitle,
  }) async {
    await _stopAlertSound();

    _alertPlayer = AudioPlayer();
    bool customSoundPlaying = false;
    try {
      await _alertPlayer!.setAsset('assets/sounds/alert.wav');
      await _alertPlayer!.setLoopMode(LoopMode.one);
      await _alertPlayer!.play();
      customSoundPlaying = true;
    } catch (_) {}

    await _plugin.show(
      _emgNotificationId,
      '🔴 OFFICIAL ALERT — ${adminTitle ?? sender} (unverified)',
      reason.isNotEmpty ? reason : 'Official campus alert',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _emergencyChannel.id,
          _emergencyChannel.name,
          channelDescription: _emergencyChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          enableVibration: true,
          playSound: !customSoundPlaying,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,
          autoCancel: false,
          actions: [
            const AndroidNotificationAction(
              'dismiss',
              'Deactivate',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  // Called once an Official Alert's signature has been checked AND the
  // signer's cached role confirmed to be 'admin'. Unlike a personal SOS,
  // an Official Alert that fails verification isn't downgraded to
  // "Unverified" — it's cancelled outright, since an unverified claim of
  // officialdom is actively misleading in a way an unverified personal
  // report isn't.
  static Future<void> updateOfficialAlertVerificationStatus({
    required String sender,
    required String reason,
    String? adminTitle,
    required bool verified,
  }) async {
    if (!verified) {
      await cancelEmergencyNotification();
      return;
    }
    await _plugin.show(
      _emgNotificationId,
      '✅ OFFICIAL ALERT — ${adminTitle ?? sender}',
      reason.isNotEmpty ? reason : 'Official campus alert',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _emergencyChannel.id,
          _emergencyChannel.name,
          channelDescription: _emergencyChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          enableVibration: false,
          playSound: false,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,
          autoCancel: false,
          actions: [
            const AndroidNotificationAction(
              'dismiss',
              'Deactivate',
              showsUserInterface: true,
              cancelNotification: false,
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