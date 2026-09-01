// lib/views/hops_splash_screen.dart
//
// The animation shown once per cold start, after Android's own launch
// screen (the static tinted logo) hands off to Flutter.
//
// It shows a mesh assembling: the Hops mark appears, sends out a discovery
// pulse, peers fade in around it, and links draw between them until the
// network is whole. That's the app's actual behaviour on launch — a device
// waking up and finding the peers around it — rather than decoration
// borrowed from somewhere else.
//
// ── Why this screen is built defensively ───────────────────────────────
//
// A splash is the one screen that can lock someone out of the whole app.
// If it never finishes, nothing is reachable: no chat, no contacts, no
// emergency flare. So finishing is guaranteed by something other than the
// animation:
//
//   * A watchdog timer ends it regardless of what the animation is doing.
//     If the ticker never fires — disabled TickerMode subtree, an OS
//     throttling the process, a stall on first frame — the app still opens.
//   * Devices with "remove animations" enabled skip it rather than sitting
//     on a frozen frame.
//   * Tapping anywhere skips it.
//   * It reports completion through a callback instead of navigating.
//     Pushing a hard-coded destination from here would route around
//     main.dart's signed-in/signed-out decision and drop a signed-out user
//     straight into the app.
//   * Everything is drawn with canvas primitives. The only image is the
//     centre mark, and a missing asset falls back to an icon.
//
// Worst case on a device that can't render any of this is a plain themed
// screen for a moment, not a hang.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// Which app is starting. The two share all the machinery and differ only
/// in what the animation is *saying*: the student app is a device joining a
/// mesh, the admin app is a device watching one. Same screen so the safety
/// guarantees below can't drift apart between the two entry points.
enum HopsSplashVariant { student, admin }

class HopsSplashScreen extends StatefulWidget {
  /// Called exactly once when the splash is done — by the animation
  /// finishing, the watchdog firing, a tap, or reduced-motion skipping it.
  final VoidCallback onFinished;

  final HopsSplashVariant variant;

  const HopsSplashScreen({
    super.key,
    required this.onFinished,
    this.variant = HopsSplashVariant.student,
  });

  @override
  State<HopsSplashScreen> createState() => _HopsSplashScreenState();
}

class _HopsSplashScreenState extends State<HopsSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _startTimer;
  Timer? _watchdog;
  bool _finished = false;

  // Four seconds end to end, including the lead-in. Long enough to watch
  // the mesh assemble and read the line underneath it rather than catching
  // half of it — the phase windows further down were re-cut to match, so
  // the wordmark lands early and holds instead of appearing just before
  // the screen disappears.
  static const Duration _duration = Duration(milliseconds: 3800);
  static const Duration _startDelay = Duration(milliseconds: 200);

  // Comfortably past _startDelay + _duration. This is the promise that the
  // app opens; the animation is only the nice version of it. Raised with
  // the duration above — a watchdog shorter than the animation would cut
  // the splash off early on every single launch.
  static const Duration _watchdogTimeout = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finish();
      });

    _startTimer = Timer(_startDelay, () {
      if (mounted) _controller.forward();
    });
    _watchdog = Timer(_watchdogTimeout, _finish);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Accessibility "remove animations", and what emulators and battery
    // savers often report too. Post-frame because this runs during build.
    if (MediaQuery.of(context).disableAnimations && !_finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
    }
  }

  /// Idempotent: several paths race to end the splash and whichever gets
  /// there first wins.
  void _finish() {
    if (_finished) return;
    _finished = true;
    _startTimer?.cancel();
    _watchdog?.cancel();
    widget.onFinished();
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _watchdog?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool get _isAdmin => widget.variant == HopsSplashVariant.admin;

  /// Admin runs on alert red rather than the theme's accent. A provisioned
  /// device sitting on a desk should be identifiable as the admin app from
  /// across a room, and red is already this app's language for "this is the
  /// serious one" (flares, official alerts, bans).
  Color _accent(ColorScheme colors) =>
      _isAdmin ? Colors.red.shade700 : colors.primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      // Themed, not hard-coded: Hops ships a catalog of themes including
      // dark ones (theme/app_theme.dart).
      backgroundColor: colors.surface,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _finish,
        child: SizedBox.expand(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Painting area, not MediaQuery.size — the latter includes
              // system bars and would shift everything down by the status
              // bar's height.
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              final centre =
                  Offset(size.width * _kCentreX, size.height * _kCentreY);
              final markSize = min(size.width, size.height) * 0.16;

              return AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _MeshBootPainter(
                            progress: t,
                            accent: _accent(colors),
                            // The sweep is the admin app's tell: the student
                            // app shows a device being discovered, the admin
                            // app shows one doing the watching.
                            showSweep: _isAdmin,
                          ),
                        ),
                      ),
                      _buildCentreMark(centre, markSize, t, colors),
                      _buildWordmark(size, centre, markSize, t, colors),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// The Hops mark at the centre of the mesh — scales up from nothing as
  /// the device "comes online", then holds.
  Widget _buildCentreMark(
      Offset centre, double markSize, double t, ColorScheme colors) {
    final appear = Curves.easeOutBack.transform(_window(t, 0.00, 0.30));
    // easeOutBack overshoots past 1 and can dip below 0 at the very start;
    // scale must never go negative or the transform flips the image.
    final scale = appear.clamp(0.0, 1.4);
    final opacity = _window(t, 0.00, 0.18);
    final accent = _accent(colors);

    return Positioned(
      left: centre.dx - markSize / 2,
      top: centre.dy - markSize / 2,
      width: markSize,
      height: markSize,
      child: Opacity(
        opacity: opacity,
        child: Transform.scale(
          scale: scale,
          // A shield, not the bunny: the admin app isn't the friendly one,
          // and the two splashes need to be distinguishable at a glance on
          // a shared test device.
          child: _isAdmin
              ? Icon(Icons.shield, size: markSize, color: accent)
              : Image.asset(
            'assets/images/hops_bunny.png',
            fit: BoxFit.contain,
            // The artwork is near-black line art (average RGB ~30) drawn
            // for a white background; on the dark themes it would be a
            // black mark on a near-black screen. srcIn keeps the silhouette
            // and anti-aliased edges while replacing the colour, which
            // works because the art is effectively monochrome.
            color: accent,
            colorBlendMode: BlendMode.srcIn,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.cruelty_free, size: markSize, color: accent),
          ),
        ),
      ),
    );
  }

  /// "Hops" plus the status line, below the mesh. Positioned relative to
  /// the mesh rather than centred on screen, so the network never draws
  /// over the type.
  Widget _buildWordmark(
      Size size, Offset centre, double markSize, double t, ColorScheme colors) {
    final radius = _maxRadius(size);
    final top = centre.dy + radius + markSize * 0.45;

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Brought forward from 0.30–0.55 when the run stretched to 4s.
          // Fading the type in near the end meant it was fully legible for
          // well under a second before the screen went away; now it settles
          // around the 1-second mark and holds for the rest.
          Opacity(
            opacity: _window(t, 0.18, 0.34),
            child: Text(
              _isAdmin ? "Hops Admin" : "Hops",
              style: TextStyle(
                fontSize: _isAdmin ? 32 : 40,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: _accent(colors),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Opacity(
            opacity: _window(t, 0.34, 0.50),
            child: Text(
              _isAdmin ? "Listening for flares…" : "Finding devices near you…",
              style: TextStyle(
                fontSize: 14,
                color: colors.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Layout constants, shared by the painter and the widget layer ────────

/// Mesh centre, as a fraction of the paint area. Above true centre to
/// leave room for the wordmark underneath.
const double _kCentreX = 0.5;
const double _kCentreY = 0.38;

double _maxRadius(Size size) => min(size.width, size.height) * 0.32;

/// Progress of `t` through the window [start, end], clamped to 0..1.
/// Lets one controller drive overlapping phases without a controller each.
double _window(double t, double start, double end) {
  if (end <= start) return t >= end ? 1.0 : 0.0;
  return ((t - start) / (end - start)).clamp(0.0, 1.0);
}

/// A discovered peer. Fixed layout rather than random: a splash that looks
/// different every launch reads as broken, not lively. Angles are radians,
/// `radius` is a fraction of the mesh radius, `delay` is when it appears.
class _Peer {
  final double angle;
  final double radius;
  final double delay;
  const _Peer(this.angle, this.radius, this.delay);
}

// Deliberately uneven angles and radii — an even ring looks like a clock
// face, not a room full of phones.
const List<_Peer> _kPeers = [
  _Peer(-2.75, 0.86, 0.16),
  _Peer(-1.95, 0.60, 0.26),
  _Peer(-1.05, 0.95, 0.20),
  _Peer(-0.25, 0.70, 0.34),
  _Peer(0.62, 0.90, 0.24),
  _Peer(1.48, 0.58, 0.38),
  _Peer(2.40, 0.80, 0.30),
];

/// Peer-to-peer links, by index into [_kPeers]. Only neighbours — a link
/// from every peer to every other is a scribble, and it isn't what a real
/// mesh looks like anyway.
const List<List<int>> _kPeerLinks = [
  [0, 1],
  [1, 2],
  [2, 3],
  [4, 5],
  [5, 6],
  [6, 0],
];

class _MeshBootPainter extends CustomPainter {
  final double progress;
  final Color accent;
  final bool showSweep;

  const _MeshBootPainter({
    required this.progress,
    required this.accent,
    this.showSweep = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width * _kCentreX, size.height * _kCentreY);
    final radius = _maxRadius(size);

    final points = _kPeers
        .map((p) => centre +
            Offset(cos(p.angle), sin(p.angle)) * (radius * p.radius))
        .toList(growable: false);

    if (showSweep) _paintSweep(canvas, centre, radius);
    _paintPulses(canvas, centre, radius);
    _paintSpokes(canvas, centre, points);
    _paintPeerLinks(canvas, points);
    _paintNodes(canvas, points);
  }

  /// Admin only: a radar sweep circling the mesh, plus the ring it runs on.
  /// Two full turns over the animation — fast enough to read as active
  /// monitoring rather than as something slowly loading.
  void _paintSweep(Canvas canvas, Offset centre, double radius) {
    final fade = _window(progress, 0.05, 0.35);
    if (fade <= 0) return;
    final ring = radius * 1.12;
    final rect = Rect.fromCircle(center: centre, radius: ring);

    canvas.drawCircle(
      centre,
      ring,
      Paint()
        ..color = accent.withValues(alpha: 0.18 * fade)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    final head = progress * 2 * 2 * pi;
    canvas.drawArc(
      rect,
      head,
      0.9, // trailing wedge, in radians
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: head,
          endAngle: head + 0.9,
          colors: [accent.withValues(alpha: 0.0), accent.withValues(alpha: 0.20 * fade)],
          transform: GradientRotation(head),
        ).createShader(rect),
    );
  }

  /// Discovery pulses rippling outward from the centre — the visual for
  /// "this device is scanning", which is literally what the app starts
  /// doing the moment this screen goes away.
  void _paintPulses(Canvas canvas, Offset centre, double radius) {
    const starts = [0.02, 0.30, 0.58];
    const life = 0.52;

    for (final start in starts) {
      final t = _window(progress, start, start + life);
      if (t <= 0 || t >= 1) continue;
      final eased = Curves.easeOutCubic.transform(t);
      canvas.drawCircle(
        centre,
        eased * radius * 1.25,
        Paint()
          // Fades as it expands, so the ring dissolves instead of hitting
          // the edge and vanishing on a frame boundary.
          ..color = accent.withValues(alpha: 0.33 * (1 - t))
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// Links from this device out to each peer, drawn as they're found.
  void _paintSpokes(Canvas canvas, Offset centre, List<Offset> points) {
    for (var i = 0; i < points.length; i++) {
      final peer = _kPeers[i];
      final t = Curves.easeOutCubic
          .transform(_window(progress, peer.delay, peer.delay + 0.26));
      if (t <= 0) continue;
      canvas.drawLine(
        centre,
        Offset.lerp(centre, points[i], t)!,
        Paint()
          ..color = accent.withValues(alpha: 0.55)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// Peer-to-peer links, drawn last — the moment it stops being a star and
  /// becomes a mesh.
  void _paintPeerLinks(Canvas canvas, List<Offset> points) {
    for (var i = 0; i < _kPeerLinks.length; i++) {
      final pair = _kPeerLinks[i];
      // Guards a mistyped index in the const table above from crashing the
      // launch screen.
      if (pair.length != 2) continue;
      if (pair[0] >= points.length || pair[1] >= points.length) continue;

      final start = 0.46 + i * 0.045;
      final t = Curves.easeOutCubic.transform(_window(progress, start, start + 0.22));
      if (t <= 0) continue;

      final a = points[pair[0]];
      final b = points[pair[1]];
      canvas.drawLine(
        a,
        Offset.lerp(a, b, t)!,
        Paint()
          // Fainter than the spokes: these are links between other people,
          // not this device's own connections.
          ..color = accent.withValues(alpha: 0.22)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// The peers themselves, popping in as they're discovered.
  void _paintNodes(Canvas canvas, List<Offset> points) {
    for (var i = 0; i < points.length; i++) {
      final peer = _kPeers[i];
      final appear = Curves.easeOutBack
          .transform(_window(progress, peer.delay, peer.delay + 0.30));
      if (appear <= 0) continue;
      // easeOutBack undershoots below zero early on; a negative radius
      // throws.
      final scale = appear.clamp(0.0, 1.25);

      canvas.drawCircle(
        points[i],
        9 * scale,
        Paint()..color = accent.withValues(alpha: 0.16),
      );
      canvas.drawCircle(
        points[i],
        4.5 * scale,
        Paint()..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MeshBootPainter old) =>
      old.progress != progress || old.accent != accent || old.showSweep != showSweep;
}
