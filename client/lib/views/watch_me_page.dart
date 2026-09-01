import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/services/accessibility_prefs.dart';

class WatchMePage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Set<String> friendUsernames;
  final Set<String> watchingBuddies;
  // Rotating-ID seeds for known contacts (see hops_constants.dart) — a
  // buddy's beacon no longer carries their plaintext username, so
  // recognizing it requires their seed, learned the same way avatar/bio
  // are: the first time you actually open a chat with them.
  final Map<String, List<int>> contactSeeds;
  final Stream<Set<String>> watchingBuddiesStream;
  final Stream<List<String>> pendingWatchStream;
  final Future<void> Function(String buddy) onSendWatchRequest;
  final void Function(String sender) onAcceptWatchRequest;
  final void Function(String sender) onDeclineWatchRequest;
  final void Function(String buddy) onStopWatching;
  final VoidCallback onClearAll;

  const WatchMePage({
    super.key,
    required this.radarStream,
    required this.friendUsernames,
    required this.watchingBuddies,
    this.contactSeeds = const {},
    required this.watchingBuddiesStream,
    required this.pendingWatchStream,
    required this.onSendWatchRequest,
    required this.onAcceptWatchRequest,
    required this.onDeclineWatchRequest,
    required this.onStopWatching,
    required this.onClearAll,
  });

  @override
  State<WatchMePage> createState() => _WatchMePageState();
}

// Per-buddy signal state — was a handful of bare fields on the State
// object (one buddy at a time); now one of these per currently-watched
// buddy, so Watch Me can track everyone in widget.watchingBuddies at once
// instead of only ever the first one.
class _BuddySignal {
  int lastRssi = -100;
  DateTime? lastSeen;
  DateTime monitoringStartTime = DateTime.now();
  bool alertActive = false;
  bool alertCooldown = false;
}

class _WatchMePageState extends State<WatchMePage> {
  String? _selectedBuddy;
  bool _isRequesting = false;
  Timer? _checkTimer;
  StreamSubscription? _scanSub;
  StreamSubscription<List<String>>? _pendingSub;
  StreamSubscription<Set<String>>? _watchingSub;

  // Keyed by buddy username — every entry here is someone currently being
  // actively monitored. One shared scan subscription and check timer cover
  // all of them (see _syncMonitoring) rather than one pair per buddy,
  // which would mean N parallel listeners all re-scanning the exact same
  // stream for a large watch list.
  final Map<String, _BuddySignal> _monitored = {};

  List<String> _pendingRequests = [];
  late Set<String> _watchingBuddies;

  @override
  void initState() {
    super.initState();
    UnreadTracker.instance.clear(UnreadSource.watchMe);
    _watchingBuddies = Set<String>.from(widget.watchingBuddies);
    _pendingSub = widget.pendingWatchStream
        .listen((requests) => setState(() => _pendingRequests = requests));
    _watchingSub = widget.watchingBuddiesStream.listen((buddies) {
      setState(() {
        _watchingBuddies = buddies;
        _syncMonitoring();
      });
    });
    _syncMonitoring();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _checkTimer?.cancel();
    _pendingSub?.cancel();
    _watchingSub?.cancel();
    super.dispose();
  }

  // Reconciles _monitored against _watchingBuddies — adds a fresh
  // _BuddySignal for anyone newly being watched (so THEIR 15-second "not
  // found yet" grace period starts from when watching actually began, not
  // from whenever the very first buddy was added), drops anyone no longer
  // watched, and makes sure the shared subscription/timer are running
  // whenever there's at least one buddy to track.
  void _syncMonitoring() {
    for (final b in _watchingBuddies) {
      _monitored.putIfAbsent(b, () => _BuddySignal());
    }
    _monitored.removeWhere((b, _) => !_watchingBuddies.contains(b));

    if (_monitored.isEmpty) {
      _scanSub?.cancel();
      _scanSub = null;
      _checkTimer?.cancel();
      _checkTimer = null;
      return;
    }

    _scanSub ??= widget.radarStream.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        if (!name.startsWith("HPS:")) continue;
        final token = name.substring(4);
        for (final entry in _monitored.entries) {
          final seed = widget.contactSeeds[entry.key];
          if (seed == null) continue; // can't recognize their beacon without it — see _buildSignalBar
          if (matchesRotatingToken(seed, token)) {
            entry.value
              ..lastRssi = r.rssi
              ..lastSeen = DateTime.now()
              ..alertCooldown = false;
          }
        }
      }
      if (mounted) setState(() {});
    });

    _checkTimer ??= Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      final now = DateTime.now();
      for (final entry in _monitored.entries) {
        final buddy = entry.key;
        final sig = entry.value;
        if (sig.lastSeen == null &&
            now.difference(sig.monitoringStartTime).inSeconds >= 15 &&
            !sig.alertCooldown &&
            !sig.alertActive) {
          _triggerAlert(buddy, sig, "$buddy not found – may be out of range or Bluetooth off");
          continue;
        }
        if (sig.lastSeen != null && now.difference(sig.lastSeen!).inSeconds >= 10) {
          if (!sig.alertCooldown && !sig.alertActive) {
            _triggerAlert(buddy, sig, "$buddy disappeared!");
          }
        } else if (sig.lastRssi < -80 && !sig.alertActive && !sig.alertCooldown && sig.lastSeen != null) {
          _triggerAlert(buddy, sig,
              "$buddy's signal is weak — they may be far away, blocked by walls, or on a different floor.");
        }
      }
    });
  }

  void _stopWatching(String buddy) {
    _monitored.remove(buddy);
    if (_monitored.isEmpty) {
      _scanSub?.cancel();
      _scanSub = null;
      _checkTimer?.cancel();
      _checkTimer = null;
    }
    widget.onStopWatching(buddy);
  }

  void _triggerAlert(String buddy, _BuddySignal sig, String message) {
    if (sig.alertActive) return;
    sig.alertActive = true;
    sig.alertCooldown = true;
    HapticFeedback.heavyImpact();
    // Fires regardless of whether this screen is even mounted right now —
    // the in-app dialog below only ever helped if Watch Me happened to be
    // the screen on top, which defeats the point of a *safety* alert. This
    // is what actually reaches someone elsewhere in the app or with it
    // backgrounded.
    UnreadTracker.instance.mark(UnreadSource.watchMe);
    NotificationService.showWatchMeAlertNotification(message: message);
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Watch Me Alert"),
        content: Text(message),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (mounted) setState(() => sig.alertActive = false);
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  // RSSI-based proximity — deliberately coarse buckets, not a precise
  // meter figure. Real-world BLE RSSI is noisy (multipath, pocket vs.
  // hand, phone antenna differences, walls) — a fake-precise "4.7 m away"
  // reading would be actively misleading for a safety feature. These
  // thresholds are the same rough zones iBeacon's proximity API uses
  // (Immediate/Near/Far) rather than anything device-calibrated.
  // [colorblind] swaps the red/yellow/green "traffic light" set for a
  // blue/orange/purple one — the standard colorblind-safe substitution
  // (Okabe-Ito palette) for the two most common forms of color blindness,
  // where red and green are the pair that's hardest to tell apart. The
  // emoji dots change with it (🟢🟡🔴 read as color even to someone who
  // can't see the underlying Color value) so the swap is consistent
  // everywhere this shows up, not just in the progress bar's fill color.
  ({String label, String emoji, Color color}) _proximityInfo(int rssi, bool everSeen, bool colorblind) {
    if (!everSeen) return (label: "Not seen yet", emoji: "⚪", color: Colors.grey);
    if (rssi >= -60) {
      return colorblind
          ? (label: "Right next to you", emoji: "🔵", color: const Color(0xFF0072B2))
          : (label: "Right next to you", emoji: "🟢", color: Colors.green);
    }
    if (rssi >= -75) {
      return colorblind
          ? (label: "Nearby", emoji: "🟠", color: const Color(0xFFE69F00))
          : (label: "Nearby", emoji: "🟡", color: Colors.orange);
    }
    return colorblind
        ? (label: "Far, may be out of sight", emoji: "🟣", color: const Color(0xFFCC79A7))
        : (label: "Far, may be out of sight", emoji: "🔴", color: Colors.red);
  }

  Widget _buildSignalBar(String buddy, _BuddySignal sig) {
    return ValueListenableBuilder<bool>(
      valueListenable: AccessibilityPrefs.instance.colorblindMode,
      builder: (context, colorblind, _) => _buildSignalBarContent(buddy, sig, colorblind),
    );
  }

  Widget _buildSignalBarContent(String buddy, _BuddySignal sig, bool colorblind) {
    final colors = Theme.of(context).colorScheme;
    final everSeen = sig.lastSeen != null;
    final proximity = _proximityInfo(sig.lastRssi, everSeen, colorblind);
    final ratio = ((sig.lastRssi + 100) / 70.0).clamp(0.0, 1.0);
    // Before the first sighting, a flat "Not seen yet" reads as frozen —
    // there's no way to tell "just started, still looking" apart from
    // "actually stuck" without this. A small spinner next to the label
    // makes clear this is actively scanning, not stalled, for however
    // long BLE discovery genuinely takes (a real few-second floor —
    // advertising + scan duty cycles on both phones, not something a
    // check-interval on this screen can shrink further).
    final stillLooking = !everSeen &&
        DateTime.now().difference(sig.monitoringStartTime).inSeconds < 15;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (stillLooking)
              const Padding(
                padding: EdgeInsets.only(right: 8, top: 1),
                child: SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(proximity.emoji, style: const TextStyle(fontSize: 18)),
              ),
            Flexible(
              child: Text(
                stillLooking ? "Scanning for $buddy…" : proximity.label,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: proximity.color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          "Signal: ${sig.lastRssi} dBm",
          style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: everSeen ? ratio : 0,
          color: proximity.color,
          backgroundColor: colors.onSurface.withValues(alpha: 0.15),
          minHeight: 12,
        ),
        const SizedBox(height: 8),
        Text(
          everSeen
              ? "Last seen: ${sig.lastSeen!.hour}:${sig.lastSeen!.minute.toString().padLeft(2, '0')}"
              : "Not seen yet",
          style: TextStyle(color: colors.onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          "Rough estimate from Bluetooth signal strength — not an exact distance.",
          style: TextStyle(fontSize: 10, color: colors.onSurface.withValues(alpha: 0.5), fontStyle: FontStyle.italic),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  // Replaces the old DropdownButton — a tap-to-select row of pill chips
  // reads much more like the rest of the app's Elevated Soft UI (and
  // shows every candidate at a glance instead of hiding them behind a
  // closed menu) than a plain platform dropdown does.
  Widget _buildBuddyPicker(ColorScheme colors) {
    final available =
        widget.friendUsernames.where((f) => !_watchingBuddies.contains(f)).toList();
    if (available.isEmpty) {
      return Text(
        "No friends available to watch — add some from the Home tab first.",
        style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 12),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: available.map((f) {
        final selected = _selectedBuddy == f;
        return GestureDetector(
          onTap: () => setState(() => _selectedBuddy = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? colors.primary : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor:
                      selected ? Colors.white.withValues(alpha: 0.25) : colors.primary.withValues(alpha: 0.15),
                  child: Text(
                    f.isNotEmpty ? f[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: selected ? Colors.white : colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  f,
                  style: TextStyle(
                    color: selected ? Colors.white : colors.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Watch Me",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.primary,
        actions: [
          // Was an icon-only IconButton — the tooltip only shows up on a
          // long-press, so what it actually does wasn't visible at a
          // glance. Same TextButton.icon treatment as Hops Share's
          // "Received Files" and Vibe Check's "History" actions.
          TextButton.icon(
            icon: Icon(Icons.delete_sweep, color: colors.primary, size: 20),
            label: Text(
              "Clear All",
              style: TextStyle(color: colors.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: widget.onClearAll,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_monitored.isNotEmpty) ...[
              Text(
                _monitored.length > 1 ? "Watching ${_monitored.length} people" : "Monitoring",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: colors.primary),
              ),
              const SizedBox(height: 8),
              // One card per watched buddy — each tracks and alerts on
              // their OWN signal independently, so watching several people
              // at once means several live signal bars, not just the
              // first buddy you added.
              ..._monitored.entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.key,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _stopWatching(entry.key),
                                  child: const Text("Stop"),
                                ),
                              ],
                            ),
                            if (!widget.contactSeeds.containsKey(entry.key))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  "You haven't chatted with ${entry.key} yet — open a chat with "
                                  "them once so Watch Me can recognize their signal.",
                                  style: TextStyle(
                                      fontSize: 12, color: colors.error, fontStyle: FontStyle.italic),
                                ),
                              ),
                            _buildSignalBar(entry.key, entry.value),
                          ],
                        ),
                      ),
                    ),
                  )),
              const SizedBox(height: 12),
            ],
            Text(
              "Watch Requests",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 8),
            if (_pendingRequests.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text(
                  "No pending requests",
                  style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              ..._pendingRequests.map((sender) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor:
                            colors.primary.withValues(alpha: 0.1),
                            child: Text(sender.isNotEmpty ? sender[0] : '?',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: colors.primary)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "$sender wants to watch you",
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                widget.onDeclineWatchRequest(sender),
                            child: const Text("Decline",
                                style: TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colors.primary,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () =>
                                widget.onAcceptWatchRequest(sender),
                            child: const Text("Accept"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )),
            const SizedBox(height: 16),
            Text(
              "Send watch request to:",
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colors.primary
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            _buildBuddyPicker(colors),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text("Send Request"),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: _selectedBuddy != null && !_isRequesting
                  ? () async {
                final messenger = ScaffoldMessenger.of(context);
                setState(() => _isRequesting = true);
                await widget.onSendWatchRequest(_selectedBuddy!);
                // The request goes out over Bluetooth and can take a while;
                // this screen is closable the whole time.
                if (!mounted) return;
                setState(() => _isRequesting = false);
                messenger.showSnackBar(
                  SnackBar(
                      content:
                      Text("Request sent to $_selectedBuddy")),
                );
              }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}