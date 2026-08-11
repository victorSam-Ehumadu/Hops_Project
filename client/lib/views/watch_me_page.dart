import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class WatchMePage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Set<String> friendUsernames;
  final Set<String> watchingBuddies;
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

class _WatchMePageState extends State<WatchMePage> {
  String? _selectedBuddy;
  bool _isRequesting = false;
  Timer? _checkTimer;
  StreamSubscription? _scanSub;
  StreamSubscription<List<String>>? _pendingSub;
  StreamSubscription<Set<String>>? _watchingSub;

  String? _monitoredBuddy;
  int _lastRssi = -100;
  DateTime? _lastSeen;
  DateTime? _monitoringStartTime;
  bool _alertActive = false;
  bool _alertCooldown = false;

  List<String> _pendingRequests = [];
  late Set<String> _watchingBuddies;

  @override
  void initState() {
    super.initState();
    _watchingBuddies = Set<String>.from(widget.watchingBuddies);
    _pendingSub = widget.pendingWatchStream
        .listen((requests) => setState(() => _pendingRequests = requests));
    _watchingSub = widget.watchingBuddiesStream.listen((buddies) {
      setState(() {
        _watchingBuddies = buddies;
        if (_monitoredBuddy != null && !buddies.contains(_monitoredBuddy)) {
          _cancelMonitoring();
          _monitoredBuddy = null;
        }
        if (buddies.isNotEmpty && _monitoredBuddy == null) {
          _startWatching(buddies.first);
        }
      });
    });
    if (_watchingBuddies.isNotEmpty && _monitoredBuddy == null) {
      _startWatching(_watchingBuddies.first);
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _checkTimer?.cancel();
    _pendingSub?.cancel();
    _watchingSub?.cancel();
    super.dispose();
  }

  void _cancelMonitoring() {
    _scanSub?.cancel();
    _checkTimer?.cancel();
    _alertActive = false;
    _alertCooldown = false;
    _monitoringStartTime = null;
  }

  void _startWatching(String buddy) {
    _cancelMonitoring();
    _monitoredBuddy = buddy;
    _lastRssi = -100;
    _lastSeen = null;
    _alertActive = false;
    _alertCooldown = false;
    _monitoringStartTime = DateTime.now();

    _scanSub = widget.radarStream.listen((results) {
      for (final r in results) {
        if (r.advertisementData.advName == "HPS:$buddy") {
          _lastRssi = r.rssi;
          _lastSeen = DateTime.now();
          _alertCooldown = false;
        }
      }
      if (mounted) setState(() {});
    });

    _checkTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastSeen == null &&
          _monitoringStartTime != null &&
          now.difference(_monitoringStartTime!).inSeconds >= 15 &&
          !_alertCooldown &&
          !_alertActive) {
        _triggerAlert("Buddy not found – may be out of range or Bluetooth off");
        return;
      }
      if (_lastSeen != null && now.difference(_lastSeen!).inSeconds >= 10) {
        if (!_alertCooldown && !_alertActive)
          _triggerAlert("Buddy disappeared!");
      } else if (_lastRssi < -80 &&
          !_alertActive &&
          !_alertCooldown &&
          _lastSeen != null) {
        _triggerAlert("Buddy's signal is weak — they may be far away, blocked by walls, or on a different floor.");
      }
    });
  }

  void _stopWatching(String buddy) {
    _cancelMonitoring();
    _monitoredBuddy = null;
    widget.onStopWatching(buddy);
  }

  void _triggerAlert(String message) {
    if (_alertActive || !mounted) return;
    _alertActive = true;
    _alertCooldown = true;
    HapticFeedback.heavyImpact();
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
              if (mounted) setState(() => _alertActive = false);
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
  ({String label, String emoji, Color color}) _proximityInfo(int rssi, bool everSeen) {
    if (!everSeen) return (label: "Not seen yet", emoji: "⚪", color: Colors.grey);
    if (rssi >= -60) return (label: "Right next to you", emoji: "🟢", color: Colors.green);
    if (rssi >= -75) return (label: "Nearby", emoji: "🟡", color: Colors.orange);
    return (label: "Far, may be out of sight", emoji: "🔴", color: Colors.red);
  }

  Widget _buildSignalBar(int rssi) {
    final everSeen = _lastSeen != null;
    final proximity = _proximityInfo(rssi, everSeen);
    final ratio = ((rssi + 100) / 70.0).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(proximity.emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                proximity.label,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: proximity.color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          "Signal: $rssi dBm",
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: everSeen ? ratio : 0,
          color: proximity.color,
          backgroundColor: Colors.grey.shade300,
          minHeight: 12,
        ),
        const SizedBox(height: 8),
        Text(
          everSeen
              ? "Last seen: ${_lastSeen!.hour}:${_lastSeen!.minute.toString().padLeft(2, '0')}"
              : "Not seen yet",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          "Rough estimate from Bluetooth signal strength — not an exact distance.",
          style: TextStyle(fontSize: 10, color: Colors.grey.shade500, fontStyle: FontStyle.italic),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
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
          IconButton(
            icon: Icon(
              Icons.delete_sweep,
              color: colors.primary,
            ),
            onPressed: widget.onClearAll,
            tooltip: "Clear all watch history",
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_monitoredBuddy != null) ...[
              Text(
                "Monitoring: $_monitoredBuddy",
                style: const TextStyle(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              _buildSignalBar(_lastRssi),
              const Divider(height: 24),
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
              const Padding(
                padding: EdgeInsets.only(left: 16, top: 4),
                child: Text(
                  "No pending requests",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
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
                            colors.primary.withOpacity(0.1),
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
            if (_watchingBuddies.isNotEmpty) ...[
              const Text(
                "Currently watching:",
                style: TextStyle(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              ..._watchingBuddies.map((b) => ListTile(
                title: Text(
                  b,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: ElevatedButton(
                  onPressed: () => _stopWatching(b),
                  child: const Text("Stop"),
                ),
              )),
              const Divider(),
            ],
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
            DropdownButton<String>(
              value: _selectedBuddy,
              isExpanded: true,
              hint: const Text("Choose a friend"),
              items: widget.friendUsernames
                  .where((f) => !_watchingBuddies.contains(f))
                  .map((f) => DropdownMenuItem(
                value: f,
                child: Text(
                  f,
                  style: TextStyle(color: colors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedBuddy = v),
            ),
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
                setState(() => _isRequesting = true);
                await widget.onSendWatchRequest(_selectedBuddy!);
                setState(() => _isRequesting = false);
                ScaffoldMessenger.of(context).showSnackBar(
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