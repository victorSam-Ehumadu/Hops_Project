import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/theme/ping_sound_packs.dart';

class NotificationService {
  // ── Emergency/Official alert notification ids ─────────────────────────────
  // Allocated per ALERT, not fixed. There used to be a single id 0 shared by
  // every flare and Official Alert, on the assumption two could never
  // meaningfully overlap. They can, and when they did the results were bad:
  // a second concurrent flare silently overwrote the first (one id = one
  // notification, so the first sender and reason simply vanished), and an
  // EMG_OFF: from EITHER sender cancelled that one shared id — so one person
  // standing down killed a different person's still-active alarm on every
  // device in range.
  //
  // Now each distinct alert — keyed by its full advertisement string, e.g.
  // "EMG:Vic:Fire in Lab", which is already unique per sender+reason and is
  // already what the receive-side dedup sets key on — gets its own id and
  // its own notification. They stack, and each is cancelled independently.
  static const int _emgNotificationIdBase = 1000;
  static const int _emgNotificationIdCount = 100;

  /// Live alerts on THIS device: advertisement string → notification id.
  /// Also the single source of truth for [isAlarmRinging] and for whether
  /// the siren should still be looping.
  static final Map<String, int> _activeAlertIds = {};
  static int _nextAlertId = _emgNotificationIdBase;

  /// Id for [alertKey], allocating one on first use. Ids wrap after
  /// [_emgNotificationIdCount] distinct alerts — far more than can plausibly
  /// be live at once, and by the time it wraps the original holder is long
  /// cancelled. The in-use scan makes that safe even if it somehow isn't:
  /// handing a live alert's id to a second key would let cancelling either
  /// one dismiss both.
  static int _idForAlert(String alertKey) =>
      _activeAlertIds.putIfAbsent(alertKey, () {
        final taken = _activeAlertIds.values.toSet();
        var id = _nextAlertId;
        for (var i = 0; i < _emgNotificationIdCount && taken.contains(id); i++) {
          id = _emgNotificationIdBase +
              ((id + 1 - _emgNotificationIdBase) % _emgNotificationIdCount);
        }
        _nextAlertId = _emgNotificationIdBase +
            ((id + 1 - _emgNotificationIdBase) % _emgNotificationIdCount);
        return id;
      });

  /// How long a received alert stays up on THIS device without being
  /// refreshed before it gives up and dismisses itself.
  ///
  /// An alert is normally cleared by its sender's stand-down (EMG_OFF: /
  /// ADM_OFF:), but that's a BLE broadcast like any other and is perfectly
  /// capable of never arriving — the sender walks out of range, or their
  /// phone dies, in the seconds between. That used to be survivable because
  /// one shared notification id meant the next alert simply overwrote the
  /// orphan. Now that alerts stack, an orphan would sit there ringing
  /// forever, so each one carries its own deadline.
  ///
  /// Sized off the longest sender-side broadcast window (a flare's
  /// kEmergencyFlareDuration; an Official Alert self-cancels at 30s) plus a
  /// wide margin, so this only ever fires when the stand-down genuinely
  /// went missing — never while the emergency is still live.
  static final Duration _alertAutoExpiry =
      kEmergencyFlareDuration + const Duration(seconds: 30);

  static final Map<String, Timer> _alertExpiryTimers = {};

  /// (Re)arms [alertKey]'s self-dismissal deadline. Called on every show, so
  /// an alert that's still actively being re-broadcast keeps pushing its own
  /// deadline out rather than expiring mid-emergency.
  static void _armAlertExpiry(String alertKey) {
    _alertExpiryTimers.remove(alertKey)?.cancel();
    _alertExpiryTimers[alertKey] = Timer(_alertAutoExpiry, () {
      _alertExpiryTimers.remove(alertKey);
      cancelEmergencyNotification(alertKey: alertKey);
    });
  }

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
  static const int _accountBannedNotificationId = 205;
  static const int _adminRequestApprovedNotificationId = 206;
  static const int _fileReceivedNotificationId = 207;
  static const int _taskReminderNotificationId = 208;
  static const int _communityMessageNotificationId = 209;
  static const int _accountSuspendedNotificationId = 210;
  static const int _adminWarningNotificationId = 211;
  static const int _studyInterestNotificationId = 212;
  static const int _chatNotificationIdBase = 90000;

  static final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _emergencyChannel =
  AndroidNotificationChannel(
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
  static const AndroidNotificationChannel _watchMeChannel =
  AndroidNotificationChannel(
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
  static const AndroidNotificationChannel _activityChannel =
  AndroidNotificationChannel(
    'general_activity',
    'Hops Activity',
    description: 'Messages, requests, and other Hops activity',
    importance: Importance.high,
  );

  static AudioPlayer? _alertPlayer;
  /// Whether [_alertPlayer] actually managed to load and play the siren
  /// asset — see _ensureAlarmSounding.
  static bool _customSoundPlaying = false;

  /// True while at least one emergency alarm (a personal Emergency Flare or
  /// an Official Alert — either kind, own or someone else's) is ringing on
  /// THIS device: its notification is up and, if the sound loaded, the siren
  /// is looping.
  ///
  /// Exists so the app can offer an in-app "stop this for me" affordance
  /// (see hops_app.dart/admin_shell.dart's alarm banner) beyond the
  /// notification's own action button — that button only helps if someone
  /// thinks to pull down the notification shade, which isn't obvious mid-
  /// panic with a phone blaring in your hand.
  ///
  /// Derived from [_activeAlertIds] and updated ONLY by [_syncAlarmState],
  /// so "ringing", "the siren is playing", and "there is something to stop"
  /// can never drift apart the way three independently-set flags would.
  static final ValueNotifier<bool> isAlarmRinging = ValueNotifier<bool>(false);

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
        // User tapped "Stop for me" (or the notification body itself).
        // The payload carries the alert key (see the show* methods), so
        // this silences only the alert that was actually tapped — with two
        // concurrent flares up, dismissing one must not silence the other.
        // A null payload means it wasn't one of ours; fall back to
        // cancelling everything rather than doing nothing.
        if (response.actionId == 'dismiss' || response.actionId == null) {
          cancelEmergencyNotification(alertKey: response.payload);
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
    final customSoundPlaying = await _playPingSoundIfSelected();
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
          playSound: !customSoundPlaying, // fallback if our player failed/wasn't selected
        ),
      ),
    );
  }

  /// One-shot playback of the selected ping sound pack (see
  /// theme/ping_sound_packs.dart), if the player picked one and playback
  /// succeeds. Returns true when a custom sound is now playing, so the
  /// caller can suppress the channel's own default sound and avoid a
  /// double-ping. See that catalog file's header comment for why this only
  /// reliably fires while Hops is in the foreground — a real per-pack
  /// system sound would need native Android channels, which this pass
  /// doesn't add.
  static Future<bool> _playPingSoundIfSelected() async {
    await CosmeticPrefs.instance.load();
    final asset = PingSoundOptions.byId(CosmeticPrefs.instance.pingSound.value).asset;
    if (asset == null) return false;
    try {
      final player = AudioPlayer();
      await player.setAsset(asset);
      unawaited(player.play());
      // Short one-shot clips (well under a second) — disposing on a fixed
      // delay instead of chaining off play()'s completion future, since
      // just_audio's play() future semantics aren't guaranteed to resolve
      // promptly once playback actually finishes.
      unawaited(Future.delayed(const Duration(seconds: 2), player.dispose));
      return true;
    } catch (_) {
      return false;
    }
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

  // Fires when someone taps "I'm Interested" on your active Study Bunny
  // Finder tag (see hops_app.dart's SBI: scan handler) — deliberately no
  // sender name in the body, since study tags carry no identity on the
  // wire at all (same anonymity as Vibe Check).
  static Future<void> showStudyInterestNotification({required String subject}) =>
      _showActivity(
        id: _studyInterestNotificationId,
        title: "Study Bunny interest",
        body: "Someone nearby is interested in studying $subject with you",
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

  // There's no push-notification infrastructure in this app (no FCM — it's
  // a peer-to-peer BLE mesh with a minimal Supabase backend), so both of
  // these can only ever reflect what hops_app.dart's periodic identity-sync
  // poll found, not a true instant push.
  static Future<void> showAdminRequestApprovedNotification() => _showActivity(
        id: _adminRequestApprovedNotificationId,
        title: "Admin access granted",
        body: "You can now issue Official Alerts — see your Profile.",
      );

  // Fires when the identity-sync poll discovers this account was banned —
  // see hops_app.dart's _syncIdentityStatus, which shows this then
  // immediately signs the device out locally.
  static Future<void> showAccountBannedNotification() => _showActivity(
        id: _accountBannedNotificationId,
        title: "Account banned",
        body: "A Hops admin has banned this account. You've been signed out.",
      );

  // Same idea as above, for a suspension rather than a ban — see
  // _syncIdentityStatus's 'account_suspended' branch. Distinct wording (and
  // a distinct notification id) so someone who's been both at different
  // times isn't left staring at a stale "banned" toast for what's actually
  // a temporary lockout.
  static Future<void> showAccountSuspendedNotification({String? until}) => _showActivity(
        id: _accountSuspendedNotificationId,
        title: "Account suspended",
        body: until != null
            ? "A Hops admin has suspended this account until $until. You've been signed out."
            : "A Hops admin has suspended this account. You've been signed out.",
      );

  // [reminderKey] identifies which task+stage this is (see
  // hops_app.dart's _maybeFireTaskReminder) so the day-before, 2-hour,
  // 1-hour, and at-time reminders for the SAME task — or reminders for
  // two DIFFERENT tasks landing close together — each get their own
  // notification instead of the newest one silently replacing an
  // still-relevant earlier one. Falls back to the old shared id when no
  // key is given, so nothing else calling this with the old signature
  // breaks.
  static Future<void> showTaskReminderNotification({
    required String taskTitle,
    String? body,
    String? reminderKey,
  }) =>
      _showActivity(
        id: reminderKey == null
            ? _taskReminderNotificationId
            : _taskReminderNotificationId + (reminderKey.hashCode & 0xFFFF),
        title: "Task reminder",
        body: body ?? "'$taskTitle' is due now",
      );

  // Community Alerts is a broadcast everyone nearby receives, so unlike a
  // 1:1 chat this reuses ONE id — several alerts in a row would otherwise
  // stack up a separate notification per message. Latest alert replaces
  // the last.
  static Future<void> showCommunityMessageNotification({
    required String sender,
    required String message,
  }) =>
      _showActivity(
        id: _communityMessageNotificationId,
        title: "Community Alert · $sender",
        body: message,
      );

  // Fired when the identity-sync poll notices the unread count went up (see
  // hops_app.dart's _syncIdentityStatus) — same pull-based stand-in for
  // push that everything else here relies on, so it lands on the next poll
  // rather than instantly.
  //
  // Deliberately neutral wording: this fires for any new item in the
  // inbox, and that's no longer only admin warnings — a "your report was
  // reviewed" confirmation comes through the same count (see
  // 0013_notify_reporter_on_resolution.sql). get_my_status returns a count,
  // not a type, so the notification can't say which without a second round
  // trip, and guessing "warning" would be alarming and often wrong.
  static Future<void> showInboxNotification() => _showActivity(
        id: _adminWarningNotificationId,
        title: "New Hops notification",
        body: "Open Notifications to see it.",
      );

  // ── Show (called when an EMG: advertisement is first received) ────────────

  static Future<void> showEmergencyNotification({
    required String alertKey,
    required String sender,
    required String reason,
  }) async {
    final id = _idForAlert(alertKey);
    _armAlertExpiry(alertKey);
    final customSoundPlaying = await _ensureAlarmSounding();
    _syncAlarmState();

    await _plugin.show(
      id,
      '🚨 Emergency from $sender',
      reason.isNotEmpty ? reason : 'Emergency alert!',
      payload: alertKey,
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
              'Stop for me',
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
    required String alertKey,
    required String sender,
    required String reason,
    required bool verified,
  }) async {
    // Gone already — the sender stood down, or the user dismissed it —
    // so there is nothing to relabel. Re-showing here would resurrect a
    // notification the user has already deliberately silenced, which the
    // old fixed-id version did every time a late signature landed.
    final id = _activeAlertIds[alertKey];
    if (id == null) return;
    final title = verified
        ? '✅ Verified Emergency from $sender'
        : '⚠️ Unverified Emergency from $sender';
    await _plugin.show(
      id,
      title,
      reason.isNotEmpty ? reason : 'Emergency alert!',
      payload: alertKey,
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
              'Stop for me',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  // ── Official Alert (admin-only tier, ADM:/ADM_OFF:) ───────────────────────
  // Shares the channel and the single looping siren with a personal
  // Emergency Flare, but gets its own notification id like any other alert
  // — the two tiers CAN be live at once (an admin broadcasting a campus
  // alert during an incident is exactly when a student is most likely to
  // flare), and the old shared id meant whichever arrived second erased
  // the first.

  static Future<void> showOfficialAlertNotification({
    required String alertKey,
    required String sender,
    required String reason,
    String? adminTitle,
  }) async {
    final id = _idForAlert(alertKey);
    _armAlertExpiry(alertKey);
    final customSoundPlaying = await _ensureAlarmSounding();
    _syncAlarmState();

    await _plugin.show(
      id,
      // "(verifying…)", not "(unverified)" and not "admin".
      //
      // "Unverified" read as an accusation against the admin's own alert
      // and was the reported confusion. But the opposite — labelling it
      // "admin" — would assert something this device has NOT checked yet:
      // the ADM: prefix is just text in an advertisement name, and the
      // only thing separating a real Official Alert from anyone
      // broadcasting the same string is the RSA signature that arrives
      // afterwards in manufacturer data. Claiming officialdom before that
      // check is precisely the forgery this design exists to refuse, which
      // is why an alert that FAILS verification is cancelled outright
      // rather than downgraded.
      //
      // So the pending state says what is actually happening, and
      // relabelOfficialAlertNotification rewrites it the moment the
      // signature lands.
      '🔴 OFFICIAL ALERT — ${adminTitle ?? sender} (verifying…)',
      reason.isNotEmpty ? reason : 'Official campus alert',
      payload: alertKey,
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
              'Stop for me',
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
    required String alertKey,
    required String sender,
    required String reason,
    String? adminTitle,
    required bool verified,
  }) async {
    if (!verified) {
      // Cancels ONLY the spoofed alert. This used to cancel the one shared
      // id, so a rejected fake Official Alert also silenced every genuine
      // flare ringing at the same moment — a trivial way to mute the whole
      // room by broadcasting one bad signature.
      await cancelEmergencyNotification(alertKey: alertKey);
      return;
    }
    final id = _activeAlertIds[alertKey];
    if (id == null) return; // already stood down or dismissed
    await _plugin.show(
      id,
      '✅ OFFICIAL ALERT — ${adminTitle ?? sender}',
      reason.isNotEmpty ? reason : 'Official campus alert',
      payload: alertKey,
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
              'Stop for me',
              showsUserInterface: true,
              cancelNotification: false,
            ),
          ],
        ),
      ),
    );
  }

  // ── Cancel ────────────────────────────────────────────────────────────────
  // Removes one alert's notification, or all of them, and stops the siren
  // once nothing is left ringing.
  //
  // [alertKey] null means "silence everything on this device" — what the
  // in-app alarm banner does, since a user tapping it wants quiet, not a
  // per-alert triage. A non-null key removes just that alert, which is what
  // an EMG_OFF:/ADM_OFF: stand-down and a per-notification "Stop for me"
  // must do: one sender standing down has no business silencing anybody
  // else's still-live emergency.

  /// Dismisses one notification, swallowing a platform failure.
  ///
  /// NOTHING about stopping an alarm may depend on this succeeding. It
  /// already failed once, for every cancel in the app at once: R8 had no
  /// keep rules, so flutter_local_notifications' Gson TypeToken threw on
  /// every `cancel()` in release builds (see android/app/proguard-rules.pro).
  /// Because the throw happened mid-loop and before _syncAlarmStateAsync,
  /// an Emergency Flare's stand-down arrived, removed the alert from the
  /// registry, and then left the siren looping with the notification stuck
  /// on screen until the process was killed.
  ///
  /// The keep rules fix the cause. This makes the *consequence* impossible:
  /// a cancel that cannot dismiss the notification must still silence the
  /// phone, because the sound is the part that cannot be ignored.
  static Future<void> _dismissQuietly(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (e) {
      debugPrint('NotificationService: could not dismiss notification $id '
          '($e) — the alarm is still being stopped.');
    }
  }

  static Future<void> cancelEmergencyNotification({String? alertKey}) async {
    try {
      if (alertKey == null) {
        final ids = _activeAlertIds.values.toList();
        _activeAlertIds.clear();
        for (final timer in _alertExpiryTimers.values) {
          timer.cancel();
        }
        _alertExpiryTimers.clear();
        for (final id in ids) {
          await _dismissQuietly(id);
        }
      } else {
        final id = _activeAlertIds.remove(alertKey);
        if (id == null) return; // not live — nothing to do, and don't touch the siren
        _alertExpiryTimers.remove(alertKey)?.cancel();
        await _dismissQuietly(id);
      }
    } finally {
      // In a finally so the siren stops even if the registry bookkeeping
      // above throws for a reason nobody has thought of yet.
      await _syncAlarmStateAsync();
    }
  }

  /// Cancels every live alert whose key starts with [prefix].
  ///
  /// The stand-down advertisements carry only a sender ("EMG_OFF:<sender>"),
  /// while an alert's key is its full "EMG:<sender>:<reason>" string — so a
  /// stand-down is matched by prefix, and correctly clears that sender's
  /// alert whatever reason they gave. Note the sender tag is truncated to 8
  /// characters on the wire, so two people whose names share those first 8
  /// characters can still cancel each other; that ambiguity is inherent to
  /// the wire format and can't be resolved here.
  static Future<void> cancelAlertsMatching(String prefix) async {
    final matched = _activeAlertIds.keys
        .where((k) => k.startsWith(prefix))
        .toList(growable: false);
    if (matched.isEmpty) return;
    try {
      for (final key in matched) {
        final id = _activeAlertIds.remove(key);
        _alertExpiryTimers.remove(key)?.cancel();
        if (id != null) await _dismissQuietly(id);
      }
    } finally {
      // See _dismissQuietly. This is the exact call that stranded a
      // looping siren after a stand-down had been correctly received.
      await _syncAlarmStateAsync();
    }
  }

  // ── Internal alarm-state helpers ──────────────────────────────────────────

  /// Starts the looping siren if it isn't already going, and reports whether
  /// our own audio is playing (false means the caller should let the
  /// notification channel's own sound act as the fallback).
  ///
  /// Deliberately does NOT restart a siren that's already looping: a second
  /// concurrent alert arriving used to call _stopAlertSound() and build a
  /// fresh player, which cut the first alert's siren for the gap in
  /// between. One alarm sound for any number of alerts is also simply what
  /// you want — two overlapping sirens are less intelligible, not more
  /// urgent.
  static Future<bool> _ensureAlarmSounding() async {
    if (_alertPlayer != null) return _customSoundPlaying;
    // Success is tracked separately from `_alertPlayer != null` because the
    // player is assigned unconditionally — so a thrown setAsset/play used to
    // leave the "fall back to the channel's own sound" branch unreachable,
    // and a failed asset load meant a silent (vibrate-only) emergency.
    final player = AudioPlayer();
    _alertPlayer = player;
    _customSoundPlaying = false;
    try {
      await player.setAsset('assets/sounds/alert.wav');
      await player.setLoopMode(LoopMode.one);
      await player.play();
      _customSoundPlaying = true;
    } catch (_) {
      // Audio failed — notification channel sound acts as fallback.
    }
    return _customSoundPlaying;
  }

  /// Point [isAlarmRinging] at the truth. Synchronous half, for call sites
  /// that only ever add an alert.
  static void _syncAlarmState() {
    isAlarmRinging.value = _activeAlertIds.isNotEmpty;
  }

  /// As [_syncAlarmState], but also stops the siren once the last alert is
  /// gone. Keeping the sound teardown here — rather than at each cancel call
  /// site — is what guarantees the siren can't outlive the notifications or
  /// vice versa.
  static Future<void> _syncAlarmStateAsync() async {
    _syncAlarmState();
    if (_activeAlertIds.isEmpty) await _stopAlertSound();
  }

  static Future<void> _stopAlertSound() async {
    final player = _alertPlayer;
    _alertPlayer = null;
    _customSoundPlaying = false;
    await player?.stop();
    await player?.dispose();
  }
}