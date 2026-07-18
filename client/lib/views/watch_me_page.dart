import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:client/theme/hops_theme.dart';

class WatchMePage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Set<String> friendUsernames;
  final Set<String> watchingBuddies;               // initial set
  final Stream<Set<String>> watchingBuddiesStream; // updates
  final Stream<List<String>> pendingWatchStream;
  final Future<void> Function(String buddy) onSendWatchRequest;
  final void Function(String sender) onAcceptWatchRequest;
  final void Function(String sender) onDeclineWatchRequest;
  final void Function(String buddy) onStopWatching;
  final VoidCallback onClearAll;                   // new

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

  int _lastRssi = -100;
  DateTime? _lastSeen;
  bool _alertActive = false;

  List<String> _pendingRequests = [];
  late Set<String> _watchingBuddies;   // local copy

  @override
  void initState() {
    super.initState();
    _watchingBuddies = Set<String>.from(widget.watchingBuddies); // initial value

    _pendingSub = widget.pendingWatchStream.listen((requests) {
      setState(() => _pendingRequests = requests);
    });
    _watchingSub = widget.watchingBuddiesStream.listen((buddies) {
      setState(() => _watchingBuddies = buddies);
      if (_selectedBuddy != null && !buddies.contains(_selectedBuddy)) {
        _cancelMonitoring();
      }
    });
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
  }

  void _startWatching(String buddy) {
    _cancelMonitoring();
    setState(() {
      _lastRssi = -100;
      _lastSeen = null;
      _alertActive = false;
    });
    _scanSub = widget.radarStream.listen((results) {
      for (final r in results) {
        if (r.advertisementData.advName == "HPS:$buddy") {
          _lastRssi = r.rssi;
          _lastSeen = DateTime.now();
        }
      }
      if (mounted) setState(() {});
    });
    _checkTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastSeen != null && now.difference(_lastSeen!).inSeconds >= 10) {
        _triggerAlert("Buddy disappeared!");
      } else if (_lastRssi < -80 && !_alertActive && _lastSeen != null) {
        _triggerAlert("Signal too weak! RSSI: $_lastRssi dBm");
      }
    });
  }

  void _stopWatching(String buddy) {
    _cancelMonitoring();
    widget.onStopWatching(buddy);
  }

  void _triggerAlert(String message) {
    if (_alertActive || !mounted) return;
    _alertActive = true;
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

  Widget _buildSignalBar(int rssi) {
    final ratio = ((rssi + 100) / 70.0).clamp(0.0, 1.0);
    final color = ratio > 0.6 ? Colors.green : ratio > 0.3 ? Colors.orange : Colors.red;
    return Column(
      children: [
        Text("Signal: $rssi dBm", style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: ratio, color: color, backgroundColor: Colors.grey.shade300, minHeight: 12),
        const SizedBox(height: 8),
        Text(_lastSeen != null
            ? "Last seen: ${_lastSeen!.hour}:${_lastSeen!.minute.toString().padLeft(2, '0')}"
            : "Not seen yet"),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Watch Me", style: TextStyle(fontWeight: FontWeight.bold, color: HopsTheme.primary)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
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
            // Watch Requests
            const Text("Watch Requests", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: HopsTheme.primary)),
            const SizedBox(height: 8),
            if (_pendingRequests.isEmpty)
              const Padding(
                padding: EdgeInsets.only(left: 16, top: 4),
                child: Text("No pending requests", style: TextStyle(color: Colors.grey, fontSize: 13)),
              )
            else
              ..._pendingRequests.map((sender) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(radius: 16, backgroundColor: HopsTheme.primary.withOpacity(0.1),
                              child: Text(sender[0], style: const TextStyle(fontWeight: FontWeight.bold, color: HopsTheme.primary))),
                          const SizedBox(width: 10),
                          Expanded(child: Text("$sender wants to watch you")),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => widget.onDeclineWatchRequest(sender),
                            child: const Text("Decline", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: HopsTheme.primary, foregroundColor: Colors.white),
                            onPressed: () => widget.onAcceptWatchRequest(sender),
                            child: const Text("Accept"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )),
            const SizedBox(height: 16),

            // Currently Watching
            if (_watchingBuddies.isNotEmpty) ...[
              const Text("Currently watching:", style: TextStyle(fontWeight: FontWeight.w600)),
              ..._watchingBuddies.map((b) => ListTile(
                title: Text(b),
                subtitle: _buildSignalBar(_lastRssi),
                trailing: ElevatedButton(
                  onPressed: () => _stopWatching(b),
                  child: const Text("Stop"),
                ),
              )),
              const Divider(),
            ],

            // Send Watch Request
            const Text("Send watch request to:", style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: _selectedBuddy,
              isExpanded: true,
              hint: const Text("Choose a friend"),
              items: widget.friendUsernames
                  .where((f) => !_watchingBuddies.contains(f))
                  .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedBuddy = v),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text("Send Request"),
              style: ElevatedButton.styleFrom(backgroundColor: HopsTheme.primary, foregroundColor: Colors.white),
              onPressed: _selectedBuddy != null && !_isRequesting
                  ? () async {
                setState(() => _isRequesting = true);
                await widget.onSendWatchRequest(_selectedBuddy!);
                setState(() => _isRequesting = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Request sent to $_selectedBuddy")),
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