// radar_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
// HapticFeedback, for the flare button's long-press confirmation.
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/services/avatar_path_notifier.dart';
import 'package:client/theme/radar_icons.dart';
import 'package:client/views/profile_screen.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/widgets/hops_tip_carousel.dart';

// Approximate resting height of HopsTipCarousel (icon + up to 3 lines of
// 12px text + its own vertical padding) — only used to place the friend-
// request tray's default (collapsed) position right below it, so being a
// few pixels off just means a small gap/overlap rather than anything
// broken; the tray is drag-adjustable regardless.
const double _kTipCarouselHeight = 72;

class RadarScreen extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  // Targets whoever is *currently* broadcasting [targetToken] — no longer a
  // username, since a not-yet-resolved stranger's beacon doesn't carry one
  // (see hops_constants.dart's rotating-ID scheme). Works uniformly for
  // both strangers and already-known contacts.
  final Future<void> Function(String targetToken) onSendFriendRequest;
  final List<String> pendingRequests;
  final void Function(String sender) onAcceptRequest;
  final void Function(String sender) onDeclineRequest;
  final Set<String> friendUsernames;
  // Known contacts' rotating-ID seeds (learned via first chat, see
  // chat_terminal.dart) — used to resolve an observed "HPS:<token>" beacon
  // back to a real name. Absent entries just render as anonymous.
  final Map<String, List<int>> contactSeeds;
  // The Official Alert has no trigger on this screen — composing one moved
  // to the separate Admin app (lib/services/official_alert_service.dart).
  //
  // The personal Emergency Flare DOES have one again, in the app bar, and
  // it is the slot the Hops Shop briefly occupied. It was removed once for
  // two stated reasons; both are addressed rather than ignored:
  //
  //   * "easy to set off by accident" — it is LONG-PRESS, restoring the
  //     gesture the original button used (29e5265). Checked rather than
  //     assumed: that button was `onLongPress` and it opened the confirm
  //     dialog, so "hold-to-fire" was never an accurate description of it.
  //     Raising a flare now takes a deliberate hold, then a confirmation,
  //     then a typed reason. A tap cannot do it, and says so.
  //   * "useless in the situation it exists for" — true as an argument that
  //     it is not SUFFICIENT, and it isn't the primary trigger: the Quick
  //     Settings tile and app-icon shortcut still exist for the
  //     phone-in-pocket case. This is additive, for when the app is
  //     already open and in your hand, which is also the case during a
  //     demo.
  //
  // Receiving either kind of alert is unaffected — handled in hops_app.dart.
  final VoidCallback? onEmergencyFlare;
  // Stands a flare down. The active-flare SnackBar already carries a CANCEL,
  // but a SnackBar can be swiped away or time out, and then there is no way
  // back to it — so while a flare is up this button becomes the persistent
  // stand-down instead of a second way to raise one.
  final VoidCallback? onCancelEmergencyFlare;
  final bool isFlareActive;
  final VoidCallback? onRescan;
  final int nearbyBleCount;
  // Discoverable mode — see hops_constants.dart's kDiscoverableProtocolMarker.
  // Off by default; when on, broadcasts myUsername in the clear alongside
  // the anonymous beacon so a friend physically standing nearby can
  // actually tell which dot to tap, instead of only ever seeing anonymous
  // blips until after a request's already gone through blind.
  final bool isDiscoverable;
  final ValueChanged<bool>? onSetDiscoverable;

  const RadarScreen({
    super.key,
    required this.radarStream,
    required this.onSendFriendRequest,
    required this.pendingRequests,
    required this.onAcceptRequest,
    required this.onDeclineRequest,
    required this.friendUsernames,
    this.contactSeeds = const {},
    this.onEmergencyFlare,
    this.onCancelEmergencyFlare,
    this.isFlareActive = false,
    this.onRescan,
    this.nearbyBleCount = 0,
    this.isDiscoverable = false,
    this.onSetDiscoverable,
  });

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with TickerProviderStateMixin {
  final Map<String, ScanResult> _devices = {};
  StreamSubscription<List<ScanResult>>? _sub;
  late AnimationController _radarController;
  late AnimationController _pulseController;

  Color _bleMeshColor(int count) {
    if (count >= 50) return Colors.green;
    if (count >= 20) return const Color(0xFFF9A825); // amber
    if (count >= 5) return Colors.orange;
    return Colors.red;
  }

  /// Told to the user when they tap the flare button instead of holding it.
  ///
  /// Short, and it names the gesture rather than scolding. Uses the same
  /// red as the button so it reads as coming from that control.
  void _showFlareHoldHint(bool active) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFFD32F2F),
        content: Text(
          active
              ? 'Hold the button to stand the flare down.'
              : 'Hold the button to raise an Emergency Flare.',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  /// The app-bar Emergency Flare control.
  ///
  /// Two states, and the swap matters: while a flare is up this is the
  /// stand-down, not a second way to raise one. Raising a flare you already
  /// raised does nothing useful, whereas cancelling is the thing you
  /// urgently want and the SnackBar that offered it may well be gone.
  ///
  /// LONG PRESS, not tap, and it still never sends on its own — the gesture
  /// only opens hops_app.dart's confirm dialog, which then asks for a reason
  /// before anything is broadcast. So raising a flare takes a deliberate
  /// hold, a confirmation and a typed reason.
  ///
  /// A plain tap is handled too, and deliberately does not fall through to
  /// the dialog: it says what gesture is needed instead. A control that
  /// ignores taps silently reads as broken, and someone poking at a red
  /// button in an emergency needs to be told what to do, not left guessing.
  ///
  /// Both states use the same gesture. Cancelling is not the urgent half —
  /// the SnackBar's CANCEL is still there for that — and an accidentally
  /// cancelled flare is its own quiet failure, so it gets the same guard.
  Widget _buildFlareButton() {
    final active = widget.isFlareActive;
    // Fixed red in both states — see the call site for why this one control
    // does not follow the theme.
    const flare = Color(0xFFD32F2F);
    return Tooltip(
      message: active
          ? 'Hold to stand down the emergency flare'
          : 'Hold to raise an Emergency Flare',
      // MANUAL, and this is load-bearing. Tooltip's default triggerMode on
      // touch is TooltipTriggerMode.longPress (tooltip.dart's
      // _defaultTriggerMode), so a Tooltip wrapped around a long-press
      // control binds the SAME gesture twice: the tooltip inserts an
      // overlay entry while this button's handler pushes a dialog, and
      // tearing those down together threw
      //   'package:flutter/src/widgets/framework.dart':
      //   Failed assertion: '_dependents.isEmpty': is not true
      // the moment anyone actually held the button. Manual keeps the
      // message for mouse hover on the Windows build — hover is handled
      // separately from triggerMode — while leaving the long press to us.
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        label: active
            ? 'Stand down emergency flare. Press and hold.'
            : 'Emergency Flare. Press and hold, then confirm and give a reason.',
        child: GestureDetector(
          onLongPress: () {
            // Confirms the hold registered before any dialog paints. In the
            // situation this exists for, the user is not watching the
            // screen closely.
            HapticFeedback.heavyImpact();
            final handler = active
                ? widget.onCancelEmergencyFlare
                : widget.onEmergencyFlare;
            handler?.call();
          },
          onTap: () => _showFlareHoldHint(active),
          child: Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Solid while active so the app bar reflects that something
              // is actually on the air; a tint otherwise, matching the
              // weight of the other controls in this bar.
              color: active ? flare : flare.withValues(alpha: 0.12),
              border: active
                  ? null
                  : Border.all(color: flare.withValues(alpha: 0.45)),
            ),
            child: Icon(
              active ? Icons.stop_rounded : Icons.sos_rounded,
              color: active ? Colors.white : flare,
              size: active ? 22 : 20,
            ),
          ),
        ),
      ),
    );
  }

  String _bleMeshLabel(int count) {
    if (count >= 50) return 'Rich';
    if (count >= 20) return 'Decent';
    if (count >= 5) return 'Limited';
    return 'Sparse';
  }

  // Friend-request tray drag state — lets the tray be pulled up over the
  // radar for more room once there are more requests than the collapsed
  // height comfortably shows. _trayDragTop is the live finger-follow
  // position while actively dragging (null the rest of the time, in which
  // case the resting position is derived from _trayExpanded instead).
  bool _trayExpanded = false;
  double? _trayDragTop;

  // Timers for cleanup
  Timer? _cleanupTimer;

  // The "tap a dot to add them" hint below the radar. It teaches a gesture
  // that isn't discoverable otherwise, so it has to appear — but it sits
  // over the radar and only says one thing, so it has no reason to stay
  // there for the whole session. Shown for _kRadarHintDuration from the
  // moment the first dot appears, then faded out for good.
  //
  // Deliberately not shown again once it has gone: it is a first-run
  // teaching aid, and a hint that keeps coming back reads as an error
  // message rather than guidance.
  static const Duration _kRadarHintDuration = Duration(seconds: 30);
  static const Duration _kRadarHintFade = Duration(milliseconds: 600);
  bool _showRadarHint = true;
  Timer? _radarHintTimer;

  /// Starts the hint's countdown the first time a dot actually appears.
  /// Anchored to that rather than to initState because a user staring at
  /// an empty radar has not had the chance to read it yet.
  void _startRadarHintTimerIfNeeded() {
    if (_radarHintTimer != null || !_showRadarHint) return;
    _radarHintTimer = Timer(_kRadarHintDuration, () {
      if (!mounted) return;
      setState(() => _showRadarHint = false);
    });
  }

  String? _myAvatarPath;

  // Track last seen time per advertisement name (key = "HPS:username")
  final Map<String, DateTime> _lastSeen = {};

  // Map remote ID → current advertisement name
  final Map<String, String> _remoteToName = {};

  // Map remote ID → self-asserted plaintext username, learned from the
  // Discoverable manufacturer-data broadcast (see hops_constants.dart's
  // kDiscoverableProtocolMarker) — separate from _resolveToken's
  // cryptographically-matched result below, since this one is just
  // whatever the other device claims and isn't verified against anything.
  final Map<String, String> _discoverableNames = {};

  @override
  void initState() {
    super.initState();
    _loadAvatar(); // load avatar on start
    // Also reload on every avatar_path write, from ANYWHERE — the "refresh
    // after returning" call further down only catches the one navigation
    // path that goes through this screen's own Profile button; the
    // app bar's own avatar tap (hops_app.dart) opens Profile via a
    // completely separate route this screen never sees return from, which
    // is why an edited avatar wasn't showing up here specifically.
    avatarPathRevision.addListener(_loadAvatar);
    CosmeticPrefs.instance.load();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    // Sonar-style pulse rings — separate from the sweep's own 2s rotation
    // (a longer, independent cycle reads as "the radar is alive" without
    // the ring expansion racing the sweep line around the dial). See
    // RadarPainter's pulseValue for how this one value draws two rings
    // staggered half a cycle apart, so a new pulse is always mid-expansion
    // rather than there being a visible dead gap between them.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _sub = widget.radarStream.listen((results) {
      setState(() {
        final now = DateTime.now();
        for (var r in results) {
          String name = r.advertisementData.advName;
          if (name.startsWith("HPS:")) {
            final remoteId = r.device.remoteId.toString();

            // If this remote ID was already seen with a different name,
            // remove the old entry to avoid duplicate dots.
            final previousName = _remoteToName[remoteId];
            if (previousName != null && previousName != name) {
              _devices.remove(previousName);
              _lastSeen.remove(previousName);
            }

            // Update current mapping
            _devices[name] = r;
            _lastSeen[name] = now;
            _remoteToName[remoteId] = name;

            // Discoverable name, if this device is currently broadcasting
            // one — rides the scan-response manufacturer data alongside
            // the same HPS: beacon, so it's always available on the exact
            // same ScanResult.
            final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
            final revealed = mfgBytes != null ? decodeDiscoverableName(mfgBytes) : null;
            if (revealed != null && revealed.isNotEmpty) {
              _discoverableNames[remoteId] = revealed;
            } else {
              // No discoverable payload on this scan result — either they
              // never turned it on, or just turned it off. Clear any
              // stale name immediately rather than waiting up to 10s for
              // the general staleness sweep below, so switching
              // Discoverable off is reflected right away on other
              // people's radar.
              _discoverableNames.remove(remoteId);
            }
          }
        }
      });
    });

    // Periodically remove devices not seen for 10 seconds
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        _devices.removeWhere((name, result) {
          final last = _lastSeen[name];
          if (last == null) return true;
          final stale = now.difference(last).inSeconds > 10;
          if (stale) {
            final remoteId = result.device.remoteId.toString();
            _remoteToName.remove(remoteId);
            _discoverableNames.remove(remoteId);
            _lastSeen.remove(name);
            return true;
          }
          return false;
        });
      });
    });

  }

  Future<void> _loadAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _myAvatarPath = prefs.getString('avatar_path');
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cleanupTimer?.cancel();
    _radarHintTimer?.cancel();
    _radarController.dispose();
    _pulseController.dispose();
    avatarPathRevision.removeListener(_loadAvatar);
    super.dispose();
  }

  double _rssiToRadius(int rssi) {
    double clamped = rssi.clamp(-100, -30).toDouble();
    return 0.2 + (1.0 - 0.2) * (clamped + 100) / 70.0;
  }

  // Tries every known contact's seed against an observed token — cheap
  // even for a large contact list (one HMAC per contact per token), and
  // false-positive collisions are astronomically unlikely at 6 HMAC bytes.
  String? _resolveToken(String token) {
    for (final entry in widget.contactSeeds.entries) {
      if (matchesRotatingToken(entry.value, token)) return entry.key;
    }
    return null;
  }

  List<_DeviceBlip> _computeBlips() {
    final blips = _devices.entries.map((entry) {
      final r = entry.value;
      final token = r.advertisementData.advName.substring(4);
      final id = r.device.remoteId.toString();
      final hash = id.hashCode;
      final angle = (hash % 360) * (math.pi / 180.0);
      final radius = _rssiToRadius(r.rssi);
      return _DeviceBlip(
        id: id,
        token: token,
        resolvedUsername: _resolveToken(token),
        discoverableUsername: _discoverableNames[id],
        radius: radius,
        angle: angle,
        rssi: r.rssi,
      );
    }).toList();
    return _deconflictBlips(blips);
  }

  // angle is derived from the device's remoteId hash and radius from raw
  // RSSI — neither one is trying to avoid other blips, so two devices with
  // similar signal strength can land almost exactly on top of each other,
  // reading as a single dot (and only one of them tappable). Runs a few
  // passes of simple pairwise repulsion in normalized (unit-circle) space,
  // nudging any pair closer than _kMinBlipSeparation apart along the line
  // between them, until nothing overlaps or the pass cap is hit — this is
  // a cosmetic layout pass, not physics, so it doesn't need to fully
  // converge, just stop being embarrassing after a bounded amount of work.
  static const double _kMinBlipSeparation = 0.16; // normalized radar-radius units
  List<_DeviceBlip> _deconflictBlips(List<_DeviceBlip> blips) {
    if (blips.length < 2) return blips;
    final positions = blips
        .map((b) => Offset(b.radius * math.cos(b.angle), b.radius * math.sin(b.angle)))
        .toList();

    for (var pass = 0; pass < 12; pass++) {
      bool movedAny = false;
      for (var i = 0; i < positions.length; i++) {
        for (var j = i + 1; j < positions.length; j++) {
          final delta = positions[i] - positions[j];
          final dist = delta.distance;
          if (dist < _kMinBlipSeparation) {
            movedAny = true;
            // Two devices landing on the exact same spot (dist == 0 — e.g.
            // an identical hash) get an arbitrary but stable push
            // direction instead of dividing by zero.
            final push = dist > 0.0001 ? delta / dist : const Offset(1, 0);
            final overlap = (_kMinBlipSeparation - dist) / 2;
            positions[i] += push * overlap;
            positions[j] -= push * overlap;
          }
        }
      }
      if (!movedAny) break;
    }

    return List.generate(blips.length, (i) {
      final b = blips[i];
      var p = positions[i];
      // Keep every blip inside the radar circle even after being pushed —
      // clamp its distance from center back to at most 1.0 instead of
      // letting repulsion shove it past the edge.
      final mag = p.distance;
      if (mag > 1.0) p = p / mag;
      return _DeviceBlip(
        id: b.id,
        token: b.token,
        resolvedUsername: b.resolvedUsername,
        discoverableUsername: b.discoverableUsername,
        radius: p.distance,
        angle: math.atan2(p.dy, p.dx),
        rssi: b.rssi,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final blips = _computeBlips();
    if (blips.isNotEmpty) _startRadarHintTimerIfNeeded();
    final screenSize = MediaQuery.of(context).size;
    final radarSize = math.min(screenSize.width, screenSize.height * 0.55);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
        title: Row(
          children: [
            Icon(Icons.home_outlined, color: colors.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                "Home",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colors.primary,
                    fontSize: 20),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // --- BLE device count chip (radar only) ---
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _bleMeshColor(widget.nearbyBleCount).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Colored mesh-strength dot
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _bleMeshColor(widget.nearbyBleCount),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _bleMeshColor(widget.nearbyBleCount)
                            .withValues(alpha: 0.6),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.nearbyBleCount} Nearby',
                      style: TextStyle(
                        color: _bleMeshColor(widget.nearbyBleCount),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      _bleMeshLabel(widget.nearbyBleCount),
                      style: TextStyle(
                        color: _bleMeshColor(widget.nearbyBleCount)
                            .withValues(alpha: 0.8),
                        fontSize: 8,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),
          // The Emergency Flare, in the slot the Hops Shop had been
          // occupying. The Shop is NOT orphaned by this — it keeps its own
          // labelled pill on the Features tab (hops_app.dart's
          // _buildShopButton), which is where browsing belongs anyway.
          //
          // Same 40x40 circle the Shop used rather than a wide labelled
          // pill: this bar also carries the BLE-density chip and the
          // avatar, and a second pill overflows it on narrow screens.
          //
          // Red is hardcoded here, deliberately, and is the one place in
          // this file that ignores the active theme. Every Hops theme can
          // recolour `primary`, and a flare control that renders mint green
          // under one theme and navy under another stops reading as danger
          // at a glance. It matches the flare SnackBar and notification,
          // which are also fixed red.
          _buildFlareButton(),
          GestureDetector(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (context) => const HopsProfileScreen()),
              );
              _loadAvatar(); // refresh avatar after returning
            },
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: colors.primary,
                backgroundImage: _myAvatarPath != null
                    ? FileImage(File(_myAvatarPath!))
                    : null,
                child: _myAvatarPath == null
                    ? const Icon(Icons.cruelty_free,
                        size: 18, color: Colors.white)
                    : null,
              ),
            ),
          ),
        ],
      ),
      body: HopsBackgroundPattern(child: Builder(builder: (context) {
        // Where the tray rests collapsed (right under the radar + tip
        // carousel, its old fixed spot) vs. pulled all the way up (a
        // small peek gap below the AppBar — body's own coordinate space
        // already starts below it, so no extra status-bar offset needed).
        final collapsedTrayTop = radarSize + _kTipCarouselHeight;
        const expandedTrayTop = 12.0;
        final trayTop = _trayDragTop ??
            (_trayExpanded ? expandedTrayTop : collapsedTrayTop);

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: radarSize,
                  width: double.infinity,
                  child: Stack(
                    children: [
                      // Radar painting + tap detection (unchanged)
                      GestureDetector(
                        onTapUp: (details) {
                          final center = Offset(radarSize / 2, radarSize / 2);
                          final tapPos = details.localPosition - center;
                          const hitThreshold = 30.0;

                          _DeviceBlip? closest;
                          double minDist = double.infinity;
                          for (final blip in blips) {
                            final blipPos = Offset(
                              blip.radius *
                                  (radarSize / 2) *
                                  math.cos(blip.angle),
                              blip.radius *
                                  (radarSize / 2) *
                                  math.sin(blip.angle),
                            );
                            final dist = (tapPos - blipPos).distance;
                            if (dist < hitThreshold && dist < minDist) {
                              closest = blip;
                              minDist = dist;
                            }
                          }
                          if (closest != null) {
                            if (closest.resolvedUsername != null &&
                                widget.friendUsernames
                                    .contains(closest.resolvedUsername)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        "${closest.resolvedUsername} is already your friend")),
                              );
                            } else {
                              widget.onSendFriendRequest(closest.token);
                              // displayName covers both an already-resolved
                              // contact AND a stranger who's currently
                              // Discoverable — either way, naming them here
                              // beats a generic "sent!" now that there's
                              // actually a name to show.
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(closest.displayName != null
                                      ? "Friend request sent to ${closest.displayName}!"
                                      : "Friend request sent!"),
                                ),
                              );
                            }
                          }
                        },
                        child: ValueListenableBuilder<String>(
                          valueListenable: CosmeticPrefs.instance.radarIcon,
                          builder: (context, radarIconId, _) {
                            final blipEmoji = RadarIconOptions.byId(radarIconId).emoji;
                            return AnimatedBuilder(
                              animation: Listenable.merge([_radarController, _pulseController]),
                              builder: (context, child) {
                                return CustomPaint(
                                  painter: RadarPainter(
                                    rotation: _radarController.value * 2 * math.pi,
                                    pulseValue: _pulseController.value,
                                    primaryColor: colors.primary,
                                    blips: blips,
                                    blipEmoji: blipEmoji,
                                  ),
                                  size: Size(radarSize, radarSize),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      // Rescan button – top‑left inside the radar area
                      Positioned(
                        top: 4,
                        left: 4,
                        child: IconButton(
                          icon: Icon(Icons.refresh,
                              color: colors.primary, size: 20),
                          onPressed: widget.onRescan,
                          tooltip: 'Rescan',
                          style: IconButton.styleFrom(
                            backgroundColor: colors.surface.withValues(alpha: 0.6),
                            padding: const EdgeInsets.all(6),
                          ),
                        ),
                      ),
                      // Discoverable toggle – top-right, mirrors the rescan
                      // button. Off by default; filled/solid when on so
                      // it's obvious at a glance you're currently
                      // broadcasting your name to nearby strangers, not
                      // just to already-resolved contacts.
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Tooltip(
                          message: widget.isDiscoverable
                              ? "Discoverable — nearby Hoppers can see your name. Turns off on its own in 10s, or tap to stop now."
                              : "Turn on Discoverable for 10 seconds so a friend nearby can see your name and tap your dot.",
                          child: IconButton(
                            icon: Icon(
                              widget.isDiscoverable
                                  ? Icons.visibility
                                  : Icons.visibility_off_outlined,
                              color: widget.isDiscoverable
                                  ? Colors.white
                                  : colors.primary,
                              size: 20,
                            ),
                            onPressed: () {
                              final next = !widget.isDiscoverable;
                              widget.onSetDiscoverable?.call(next);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 2),
                                  content: Text(next
                                      ? "You're discoverable for 10 seconds — nearby Hoppers can see your name"
                                      : "Discoverable turned off"),
                                ),
                              );
                            },
                            style: IconButton.styleFrom(
                              backgroundColor: widget.isDiscoverable
                                  ? colors.primary
                                  : colors.surface.withValues(alpha: 0.6),
                              padding: const EdgeInsets.all(6),
                            ),
                          ),
                        ),
                      ),
                      // Empty state — the sweep used to just spin over a blank
                      // circle with zero explanation when nobody was nearby,
                      // which reads as broken/frozen rather than "working, just
                      // quiet" to a first-time user. IgnorePointer so this never
                      // steals the tap-to-friend-request gesture above it.
                      // "You" marker — always at the radar's center, regardless
                      // of whether any other device is visible, so the radar
                      // reads as "here's you, relative to everyone else" instead
                      // of the bunny only ever being an empty-state placeholder
                      // that vanishes the moment someone else shows up.
                      // IgnorePointer so it never steals the tap-to-friend-
                      // request gesture from the GestureDetector underneath it.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: colors.primary.withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.cruelty_free,
                                    size: blips.isEmpty ? 32 : 22,
                                    color: colors.primary.withValues(alpha: 
                                        blips.isEmpty ? 0.55 : 0.4),
                                  ),
                                ),
                                if (blips.isEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    "No Hoppers nearby yet",
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: colors.onSurface.withValues(alpha: 0.4),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (blips.isNotEmpty)
                        // Mirrors the empty-state hint above — once there ARE dots
                        // on screen, first-time users had no way to know tapping
                        // one sends a friend request. IgnorePointer for the same
                        // reason: this must never steal the tap-to-friend-request
                        // gesture from the GestureDetector underneath it.
                        //
                        // Fades out after _kRadarHintDuration. The countdown is
                        // started here rather than in initState because it is
                        // only worth running once there is something on screen
                        // for the hint to be about — see
                        // _startRadarHintTimerIfNeeded. Calling it from build is
                        // safe: it is idempotent and schedules rather than
                        // setting state synchronously.
                        Positioned(
                          bottom: 6,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _showRadarHint ? 1.0 : 0.0,
                              duration: _kRadarHintFade,
                              curve: Curves.easeOut,
                                child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: colors.surface.withValues(alpha: 0.85),
                                    borderRadius: BorderRadius.circular(100),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.touch_app_outlined,
                                          size: 13,
                                          color: colors.primary.withValues(alpha: 0.7)),
                                      const SizedBox(width: 5),
                                      Flexible(
                                        child: Text(
                                          "Ask a friend to reveal their username, then tap their dot to add them",
                                          textAlign: TextAlign.center,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: colors.onSurface
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const HopsTipCarousel(),
              ],
            ),
            // Draggable so it can be pulled up over the radar for more
            // room — was a fixed Expanded panel before, which was fine
            // for a couple of requests but cramped once there were more.
            // Snaps to fully collapsed or fully expanded on release based
            // on drag velocity/position, same feel as a bottom sheet.
            AnimatedPositioned(
              duration: _trayDragTop != null
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              top: trayTop,
              left: 0,
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {
                  setState(() {
                    final base = _trayDragTop ??
                        (_trayExpanded ? expandedTrayTop : collapsedTrayTop);
                    _trayDragTop = (base + details.delta.dy)
                        .clamp(expandedTrayTop, collapsedTrayTop);
                  });
                },
                onVerticalDragEnd: (details) {
                  setState(() {
                    final current = _trayDragTop ??
                        (_trayExpanded ? expandedTrayTop : collapsedTrayTop);
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity < -300) {
                      _trayExpanded = true;
                    } else if (velocity > 300) {
                      _trayExpanded = false;
                    } else {
                      final mid = (expandedTrayTop + collapsedTrayTop) / 2;
                      _trayExpanded = current < mid;
                    }
                    _trayDragTop = null;
                  });
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Drag handle — the visual cue that this panel can be
                      // pulled up, since nothing about a normal-looking panel
                      // otherwise suggests it.
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: colors.onSurface.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(100),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.mail_outline,
                              size: 16, color: colors.primary),
                          const SizedBox(width: 6),
                          Text(
                            "Friend Requests",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: colors.primary,
                            ),
                          ),
                          if (widget.pendingRequests.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: colors.primary,
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text(
                                "${widget.pendingRequests.length}",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: widget.pendingRequests.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.mark_email_read_outlined,
                                        size: 28,
                                        color:
                                            colors.onSurface.withValues(alpha: 0.2)),
                                    const SizedBox(height: 6),
                                    Text("No pending requests",
                                        style: TextStyle(
                                            color: colors.onSurface
                                                .withValues(alpha: 0.4),
                                            fontSize: 12)),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 8),
                                itemCount: widget.pendingRequests.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final sender = widget.pendingRequests[index];
                                  return HopsCard(
                                    radius: 16,
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor:
                                              colors.primary.withValues(alpha: 0.12),
                                          child: Text(
                                              sender.isNotEmpty
                                                  ? sender[0].toUpperCase()
                                                  : '?',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: colors.primary,
                                                  fontSize: 15)),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(sender,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 13),
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                              Text("wants to add you",
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: colors.onSurface
                                                          .withValues(alpha: 0.5))),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () =>
                                              widget.onDeclineRequest(sender),
                                          icon: const Icon(Icons.close,
                                              size: 18,
                                              color: Colors.redAccent),
                                          tooltip: 'Decline',
                                          style: IconButton.styleFrom(
                                            backgroundColor: Colors.redAccent
                                                .withValues(alpha: 0.08),
                                            padding: const EdgeInsets.all(8),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        IconButton(
                                          onPressed: () =>
                                              widget.onAcceptRequest(sender),
                                          icon: Icon(Icons.check,
                                              size: 18, color: colors.primary),
                                          tooltip: 'Accept',
                                          style: IconButton.styleFrom(
                                            backgroundColor:
                                                colors.primary.withValues(alpha: 0.1),
                                            padding: const EdgeInsets.all(8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      })),
    );
  }
}

class _DeviceBlip {
  final String id;
  // The raw rotating token as broadcast — this is what addressing a
  // friend request actually targets now, resolved or not.
  final String token;
  // Null until this token matches a known contact's seed.
  final String? resolvedUsername;
  // Null unless this device is currently broadcasting Discoverable — a
  // self-asserted, unverified name (see hops_constants.dart's
  // kDiscoverableProtocolMarker). Distinct from resolvedUsername, which is
  // cryptographically matched against a known contact's seed.
  final String? discoverableUsername;
  final double radius;
  final double angle;
  final int rssi;
  // The best name to show for this blip: a verified contact match wins if
  // there is one, otherwise fall back to whatever they've self-revealed.
  String? get displayName => resolvedUsername ?? discoverableUsername;
  const _DeviceBlip({
    required this.id,
    required this.token,
    required this.resolvedUsername,
    this.discoverableUsername,
    required this.radius,
    required this.angle,
    required this.rssi,
  });
}

class RadarPainter extends CustomPainter {
  final double rotation;
  // 0..1, looping — see initState's comment on _pulseController. Two rings
  // are drawn from this single value, half a cycle out of phase with each
  // other, each expanding from the center out to the dial's edge while
  // fading out, the classic sonar-ping look.
  final double pulseValue;
  final Color primaryColor;
  // _DeviceBlip is an implementation detail of this file and RadarPainter
  // is only ever constructed from inside it. Making the type public purely
  // to satisfy the lint would widen the surface for no caller's benefit.
  // ignore: library_private_types_in_public_api
  final List<_DeviceBlip> blips;
  // null = the original plain dot; otherwise an emoji glyph drawn in place
  // of the dot (see theme/radar_icons.dart).
  final String? blipEmoji;
  RadarPainter({
    required this.rotation,
    required this.pulseValue,
    required this.primaryColor,
    required this.blips,
    this.blipEmoji,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 16;
    final bgPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bgPaint);
    final circlePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(center, radius * i / 4, circlePaint);
    }
    // Sonar pulse — two rings, half a cycle apart, each expanding from the
    // center to the dial's edge while fading to nothing. maxAlpha is
    // highest right as a ring starts (near the center, where it reads as
    // a fresh "ping") and fades to 0 by the time it reaches the edge.
    final pulsePaint = Paint()..style = PaintingStyle.stroke;
    for (final phase in [0.0, 0.5]) {
      final progress = (pulseValue + phase) % 1.0;
      final pulseAlpha = (1 - progress) * 0.35;
      if (pulseAlpha <= 0.01) continue;
      pulsePaint
        ..color = primaryColor.withValues(alpha: pulseAlpha)
        ..strokeWidth = 2;
      canvas.drawCircle(center, radius * progress, pulsePaint);
    }
    final linePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy), linePaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius), linePaint);
    final sweepPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.8)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final sweepEnd = Offset(
      center.dx + radius * math.cos(rotation),
      center.dy + radius * math.sin(rotation),
    );
    canvas.drawLine(center, sweepEnd, sweepPaint);
    final centerDot = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 4, centerDot);
    final blipPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    for (final blip in blips) {
      final x = center.dx + blip.radius * radius * math.cos(blip.angle);
      final y = center.dy + blip.radius * radius * math.sin(blip.angle);
      final blipPos = Offset(x, y);
      canvas.drawCircle(blipPos, 10, blipPaint);
      canvas.drawCircle(
          blipPos,
          12,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      if (blipEmoji != null) {
        // Emoji drawn on top of the same dot+ring rather than replacing it
        // — keeps a consistent, legible "chip" shape across every icon
        // choice instead of a bare glyph floating unanchored on the sweep.
        final emojiPainter = TextPainter(
          text: TextSpan(text: blipEmoji, style: const TextStyle(fontSize: 14)),
          textDirection: TextDirection.ltr,
        );
        emojiPainter.layout();
        emojiPainter.paint(
          canvas,
          Offset(blipPos.dx - emojiPainter.width / 2, blipPos.dy - emojiPainter.height / 2),
        );
      }
      // A resolved contact or a self-revealed Discoverable name is shown
      // as-is; anyone else stays a short, non-identifying tag derived from
      // their already-public rotating token instead of nothing at all, so
      // distinct nearby strangers are still visually distinguishable.
      final label = blip.displayName ??
          '#${blip.token.substring(0, blip.token.length < 4 ? blip.token.length : 4)}';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: primaryColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
          canvas, Offset(blipPos.dx - textPainter.width / 2, blipPos.dy - 25));
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.rotation != rotation ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.blips != blips;
  }
}
