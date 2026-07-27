import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:client/views/profile_screen.dart';

class RadarScreen extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Future<void> Function(String username) onSendFriendRequest;
  final List<String> pendingRequests;
  final void Function(String sender) onAcceptRequest;
  final void Function(String sender) onDeclineRequest;
  final Set<String> friendUsernames;
  final ValueChanged<String>? onActivateFlare;

  const RadarScreen({
    super.key,
    required this.radarStream,
    required this.onSendFriendRequest,
    required this.pendingRequests,
    required this.onAcceptRequest,
    required this.onDeclineRequest,
    required this.friendUsernames,
    this.onActivateFlare,
  });

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  final Map<String, ScanResult> _devices = {};
  StreamSubscription<List<ScanResult>>? _sub;
  late AnimationController _radarController;

  // Timers for cleanup
  Timer? _cleanupTimer;

  // Track last seen time per advertisement name (key = "HPS:username")
  final Map<String, DateTime> _lastSeen = {};

  // Map remote ID → current advertisement name
  final Map<String, String> _remoteToName = {};

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
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
            _lastSeen.remove(name);
            return true;
          }
          return false;
        });
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cleanupTimer?.cancel();
    _radarController.dispose();
    super.dispose();
  }

  void _showReasonInputDialog() {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("What is the emergency?"),
        content: TextField(
          controller: reasonController,
          autofocus: true,
          maxLength: 25,
          decoration: const InputDecoration(
            hintText: "e.g., Fire in Lab 3",
          ),
          onSubmitted: (_) {
            final reason = reasonController.text.trim();
            if (reason.isEmpty) return;
            Navigator.pop(ctx);
            widget.onActivateFlare?.call(reason);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              final reason = reasonController.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx);
              widget.onActivateFlare?.call(reason);
            },
            child: const Text("ACTIVATE",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  double _rssiToRadius(int rssi) {
    double clamped = rssi.clamp(-100, -30).toDouble();
    return 0.2 + (1.0 - 0.2) * (clamped + 100) / 70.0;
  }

  List<_DeviceBlip> _computeBlips() {
    return _devices.entries.map((entry) {
      final r = entry.value;
      final username = r.advertisementData.advName.substring(4);
      final id = r.device.remoteId.toString();
      final hash = id.hashCode;
      final angle = (hash % 360) * (math.pi / 180.0);
      final radius = _rssiToRadius(r.rssi);
      return _DeviceBlip(
        id: id,
        username: username,
        radius: radius,
        angle: angle,
        rssi: r.rssi,
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final blips = _computeBlips();
    final screenSize = MediaQuery.of(context).size;
    final radarSize = math.min(screenSize.width, screenSize.height * 0.55);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
        title: Row(
          children: [
            Icon(Icons.radar, color: colors.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                "Radar",
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: colors.tertiaryContainer.withOpacity(0.2),
                borderRadius: BorderRadius.circular(100)),
            child: Row(
              children: [
                Icon(Icons.radar, size: 12, color: colors.tertiaryContainer),
                const SizedBox(width: 6),
                Text("BLE Mesh Active",
                    style: TextStyle(
                        color: colors.tertiaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onLongPress: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Activate Emergency Flare?"),
                  content: const Text(
                      "This will alert all nearby Hops users. Use only in real emergencies."),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text("Cancel"),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showReasonInputDialog();
                      },
                      child: const Text("NEXT",
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            },
            child: Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.only(right: 8),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red,
              ),
              child: const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 22),
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (context) => const HopsProfileScreen())),
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              child: CircleAvatar(
                  radius: 16,
                  backgroundColor: colors.primary,
                  child: const Icon(Icons.person, size: 18, color: Colors.white)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: radarSize,
            width: double.infinity,
            child: GestureDetector(
              onTapUp: (details) {
                final center = Offset(radarSize / 2, radarSize / 2);
                final tapPos = details.localPosition - center;
                const hitThreshold = 30.0;

                _DeviceBlip? closest;
                double minDist = double.infinity;
                for (final blip in blips) {
                  final blipPos = Offset(
                    blip.radius * (radarSize / 2) * math.cos(blip.angle),
                    blip.radius * (radarSize / 2) * math.sin(blip.angle),
                  );
                  final dist = (tapPos - blipPos).distance;
                  if (dist < hitThreshold && dist < minDist) {
                    closest = blip;
                    minDist = dist;
                  }
                }
                if (closest != null) {
                  if (widget.friendUsernames.contains(closest.username)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("${closest.username} is already your friend")),
                    );
                  } else {
                    widget.onSendFriendRequest(closest.username);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Friend request sent to ${closest.username}!")),
                    );
                  }
                }
              },
              child: AnimatedBuilder(
                animation: _radarController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: RadarPainter(
                      rotation: _radarController.value * 2 * math.pi,
                      primaryColor: colors.primary,
                      blips: blips,
                    ),
                    size: Size(radarSize, radarSize),
                  );
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 8.0, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Friend Requests",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: colors.primary,
                ),
              ),
            ),
          ),
          if (widget.pendingRequests.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text("No pending requests",
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
            )
          else
            Expanded(
              child: SizedBox(
                height: 150,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: widget.pendingRequests.length,
                  itemBuilder: (context, index) {
                    final sender = widget.pendingRequests[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                      child: Card(
                        elevation: 1,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        color: Colors.white.withOpacity(0.9),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: colors.primary.withOpacity(0.1),
                                    child: Text(sender[0],
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: colors.primary,
                                            fontSize: 14)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      "$sender wants to add you",
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 2,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () => widget.onDeclineRequest(sender),
                                    child: const Text("Decline",
                                        style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: colors.primary,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(100)),
                                      textStyle: const TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () => widget.onAcceptRequest(sender),
                                    child: const Text("Accept"),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceBlip {
  final String id;
  final String username;
  final double radius;
  final double angle;
  final int rssi;
  const _DeviceBlip({
    required this.id,
    required this.username,
    required this.radius,
    required this.angle,
    required this.rssi,
  });
}

class RadarPainter extends CustomPainter {
  final double rotation;
  final Color primaryColor;
  final List<_DeviceBlip> blips;
  RadarPainter({
    required this.rotation,
    required this.primaryColor,
    required this.blips,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 16;
    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bgPaint);
    final circlePaint = Paint()
      ..color = primaryColor.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(center, radius * i / 4, circlePaint);
    }
    final linePaint = Paint()
      ..color = primaryColor.withOpacity(0.3)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy), linePaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius), linePaint);
    final sweepPaint = Paint()
      ..color = primaryColor.withOpacity(0.8)
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
      canvas.drawCircle(blipPos, 12,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      final textPainter = TextPainter(
        text: TextSpan(
          text: blip.username,
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
      textPainter.paint(canvas,
          Offset(blipPos.dx - textPainter.width / 2, blipPos.dy - 25));
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.rotation != rotation || oldDelegate.blips != blips;
  }
}