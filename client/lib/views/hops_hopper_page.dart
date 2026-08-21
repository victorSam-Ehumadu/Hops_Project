// lib/views/hops_hopper_page.dart
//
// Hops Hopper — a single-player Flappy-Bird-style flyer: tap to flap
// against constant gravity, thread the gaps between incoming pipes. No
// BLE, no Supabase beyond the carrot credit at the end of a run — entirely
// self-contained, which is why it's wired into the feature catalog via a
// plain pageBuilder (see feature_item.dart) rather than being special-cased
// in hops_app.dart's _openFeaturePage the way features needing injected
// radar/contact data are.
//
// Difficulty ramps in discrete LEVELS rather than smoothly — every
// _pointsPerLevel pipes cleared bumps the scroll speed up a step (see
// _level/_speedForLevel) — a level-up should read as a distinct jolt, not
// a gradual creep.
//
// Physics runs off a raw Ticker rather than a game-engine package — no new
// dependency for something this simple, and every other screen in this app
// is plain Flutter widgets. Position is tracked in logical pixels within
// the play area's own measured size (via LayoutBuilder), with velocity in
// px/second and a per-frame delta computed from the Ticker's elapsed
// duration — frame-rate independent, so a dropped frame slows the *tick
// rate*, not the *game speed*. Pipe spacing is tracked in DISTANCE
// traveled (not elapsed time) specifically so a level's higher speed also
// shortens reaction time between pipes, rather than just making the same
// time-gap look busier.
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/carrot_wallet.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/hopper_skins.dart';
import 'package:client/views/hops_shop_page.dart';
import 'package:client/widgets/hops_background_pattern.dart';

enum _RunStatus { ready, countdown, playing, gameOver }

class _Pipe {
  double x; // left edge, in play-area-local px, decreasing over time
  final double gapTop; // y of the top of the gap opening
  final double gapHeight;
  bool scored = false;
  _Pipe({required this.x, required this.gapTop, required this.gapHeight});
}

class HopsHopperPage extends StatefulWidget {
  const HopsHopperPage({super.key});

  @override
  State<HopsHopperPage> createState() => _HopsHopperPageState();
}

class _HopsHopperPageState extends State<HopsHopperPage>
    with TickerProviderStateMixin {
  // TickerProviderStateMixin (plural), NOT SingleTickerProviderStateMixin —
  // the single-ticker variant asserts if createTicker() is ever called a
  // second time over this State's lifetime, even after disposing the
  // previous Ticker instance yourself. _startRun() calls createTicker()
  // fresh on every replay (Play Again, or tapping anywhere while game-over/
  // ready), so with the single-ticker mixin the very first game worked but
  // EVERY subsequent restart threw a FlutterError right after the overlay
  // was dismissed — the screen reset to "playing" but no ticker ever
  // started, so the bunny just sat there. That's what "Play Again does
  // nothing" was: the assertion, not a missing tap handler.
  static const _prefsBestKey = 'hops_hopper_best_score_v1';

  // ── Tunables ──────────────────────────────────────────────────────────
  static const double _bunnySize = 40;
  static const double _bunnyLeft = 56; // fixed horizontal position
  static const double _gravity = 1000; // px/s^2 — was 1500, felt like a brick drop
  static const double _flapVelocity = -400; // px/s, negative = upward
  static const double _pipeWidth = 56;
  static const double _gapHeight = 190;
  static const double _minEdgeMargin = 36; // gap never spawns flush to ceiling/floor

  // Speed ramps by LEVEL, not smoothly — every _pointsPerLevel pipes
  // cleared is one level, and each level is a fixed, noticeable step up.
  static const int _pointsPerLevel = 4;
  static const double _baseSpeed = 165; // px/s, level 1 — was 230, too fast out of the gate
  static const double _speedStepPerLevel = 40; // px/s added per level — was 55
  static const double _maxSpeed = 620; // was 780

  // Pipe spacing is a DISTANCE (px traveled), not a time gap — see file
  // header doc comment for why that matters once speed starts ramping.
  static const double _minPipeSpacing = 230;
  static const double _maxPipeSpacing = 300;

  // How long the "get ready" countdown runs before a run actually starts.
  static const int _countdownSeconds = 5;

  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  final _rng = Random();

  _RunStatus _status = _RunStatus.ready;
  Timer? _countdownTimer;
  int _countdownValue = _countdownSeconds;
  double _bunnyY = 0; // top-of-play-area-relative, px, increases downward
  double _bunnyVelocity = 0;
  final List<_Pipe> _pipes = [];
  double _distanceSinceSpawn = 0;
  double _nextSpawnDistance = 200;
  int _score = 0;
  int _bestScore = 0;
  int _lastReward = 0;

  Size _playSize = Size.zero;

  int get _level => 1 + _score ~/ _pointsPerLevel;
  double get _speed =>
      min(_maxSpeed, _baseSpeed + (_level - 1) * _speedStepPerLevel);

  @override
  void initState() {
    super.initState();
    _loadBest();
    CarrotWallet.instance.load();
    CosmeticPrefs.instance.load();
  }

  Future<void> _loadBest() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _bestScore = prefs.getInt(_prefsBestKey) ?? 0);
  }

  Future<void> _saveBestIfNeeded() async {
    if (_score <= _bestScore) return;
    _bestScore = _score;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsBestKey, _bestScore);
  }

  // "Start"/"Play Again" now only reaches this via the button itself (see
  // build's onPressed) — a bare screen tap used to call _startRun directly
  // through _flap below, which is exactly the "tap anywhere to start/retry"
  // behavior this was changed to stop doing. This runs the _countdownSeconds
  // "get ready" beat first; _startRun (the actual reset+ticker-start) only
  // fires once that reaches zero.
  void _beginCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _status = _RunStatus.countdown;
      _countdownValue = _countdownSeconds;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdownValue <= 1) {
        timer.cancel();
        _startRun();
        return;
      }
      setState(() => _countdownValue--);
    });
  }

  void _startRun() {
    _pipes.clear();
    _bunnyY = _playSize.height > 0 ? _playSize.height / 2 : 200;
    _bunnyVelocity = 0;
    _score = 0;
    _distanceSinceSpawn = 0;
    _nextSpawnDistance = 200;
    _lastElapsed = Duration.zero;
    setState(() => _status = _RunStatus.playing);

    _ticker?.dispose();
    _ticker = createTicker(_onTick)..start();
  }

  // Only flaps mid-run now — starting and retrying are button-only (see
  // _beginCountdown's comment). The play area still has a whole-area
  // GestureDetector for this (tapping anywhere to flap mid-flight is the
  // whole point of the genre), it just no longer doubles as a way to
  // start/restart a run from outside the button.
  void _flap() {
    if (_status != _RunStatus.playing) return;
    _bunnyVelocity = _flapVelocity;
  }

  void _onTick(Duration elapsed) {
    if (_playSize == Size.zero) return; // not laid out yet
    final dtSeconds = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    // Guards against a huge dt from e.g. the app being backgrounded and
    // resumed — one giant physics step would otherwise teleport the bunny
    // through a pipe instead of just skipping a beat.
    final dt = dtSeconds.clamp(0.0, 1 / 20);
    final speed = _speed;

    // Bunny physics — constant gravity, tap gives an upward impulse.
    _bunnyVelocity += _gravity * dt;
    _bunnyY += _bunnyVelocity * dt;

    // Floor/ceiling are both instant-death, same as this game's pipes —
    // keeps the play area's bounds unambiguous rather than letting the
    // bunny "rest" against the top of the screen.
    if (_bunnyY <= 0 || _bunnyY + _bunnySize >= _playSize.height) {
      _endRun();
      return;
    }

    // Pipes: advance, score, cull off-screen ones.
    for (final p in _pipes) {
      p.x -= speed * dt;
      if (!p.scored && p.x + _pipeWidth < _bunnyLeft) {
        p.scored = true;
        _score++;
      }
    }
    _pipes.removeWhere((p) => p.x + _pipeWidth < -10);

    // Spawn — gated on distance traveled, not elapsed time, so a faster
    // level also shortens the player's reaction window between pipes.
    _distanceSinceSpawn += speed * dt;
    if (_distanceSinceSpawn >= _nextSpawnDistance) {
      _distanceSinceSpawn = 0;
      _nextSpawnDistance =
          _minPipeSpacing + _rng.nextDouble() * (_maxPipeSpacing - _minPipeSpacing);
      final maxGapTop = _playSize.height - _gapHeight - _minEdgeMargin;
      final gapTop = _minEdgeMargin +
          _rng.nextDouble() * max(0, maxGapTop - _minEdgeMargin);
      _pipes.add(_Pipe(x: _playSize.width + _pipeWidth, gapTop: gapTop, gapHeight: _gapHeight));
    }

    // Collision — simple AABB, bunny box a little smaller than its sprite
    // so a near-miss LOOKS like a near-miss instead of an unfair hit.
    const inset = 7.0;
    final bunnyRect = Rect.fromLTWH(
      _bunnyLeft + inset, _bunnyY + inset,
      _bunnySize - inset * 2, _bunnySize - inset * 2,
    );
    for (final p in _pipes) {
      final topPipe = Rect.fromLTWH(p.x, 0, _pipeWidth, p.gapTop);
      final bottomPipe = Rect.fromLTWH(
        p.x, p.gapTop + p.gapHeight, _pipeWidth, _playSize.height - (p.gapTop + p.gapHeight),
      );
      if (bunnyRect.overlaps(topPipe) || bunnyRect.overlaps(bottomPipe)) {
        _endRun();
        return;
      }
    }

    setState(() {});
  }

  void _endRun() {
    _ticker?.stop();
    _lastReward = _score ~/ 5;
    unawaited(_saveBestIfNeeded());
    if (_lastReward > 0) unawaited(CarrotWallet.instance.earn(_lastReward));
    setState(() => _status = _RunStatus.gameOver);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hops Hopper'),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Bunny skin',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HopsShopPage()),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: CarrotWallet.instance.balance,
            builder: (context, balance, _) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  const Text('🥕', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 4),
                  Text(
                    CarrotWallet.debugUnlimitedCarrots ? '∞' : '$balance',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: HopsBackgroundPattern(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Score: $_score',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text('Level $_level',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: colors.primary, fontWeight: FontWeight.bold)),
                  Text('Best: $_bestScore',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: colors.onSurface.withValues(alpha: 0.55))),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _flap,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _playSize = Size(constraints.maxWidth, constraints.maxHeight);
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(color: colors.surfaceContainerHighest.withValues(alpha: 0.4)),
                            ..._pipes.expand((p) => _buildPipe(p, colors)),
                            _buildBunny(colors),
                            if (_status != _RunStatus.playing) _buildOverlay(colors, theme),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBunny(ColorScheme colors) {
    final top = _bunnyY.isFinite ? _bunnyY : 0.0;
    // Tilt with velocity, Flappy-Bird style — nose up on a flap, nose down
    // mid-fall. Clamped well short of a full quarter-turn so it still
    // reads as flying, not tumbling.
    final tilt = (_bunnyVelocity / 900).clamp(-0.5, 0.7);
    return Positioned(
      left: _bunnyLeft,
      top: top,
      width: _bunnySize,
      height: _bunnySize,
      child: Transform.rotate(
        angle: tilt,
        // The source art is a solid black silhouette with a transparent
        // background — invisible against a dark theme's dark play-area
        // fill if left untinted. A purchased Shop skin picks a fixed
        // color; the free default instead adapts to colors.onSurface
        // (contrast-safe against surface-ish backgrounds in every theme)
        // — that adaptive fallback is what fixed the dark-theme
        // visibility bug, and it's what a player with no skin bought
        // still gets.
        child: ValueListenableBuilder<String>(
          valueListenable: CosmeticPrefs.instance.hopperSkin,
          builder: (context, skinId, _) {
            final skinColor = HopperSkinOptions.byId(skinId).color ?? colors.onSurface;
            return ColorFiltered(
              colorFilter: ColorFilter.mode(skinColor, BlendMode.srcIn),
              child: Image.asset('assets/images/hops_bunny.png', fit: BoxFit.contain),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildPipe(_Pipe p, ColorScheme colors) {
    final bottomTop = p.gapTop + p.gapHeight;
    final bottomHeight = _playSize.height - bottomTop;
    final deco = BoxDecoration(
      color: colors.error.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(6),
    );
    return [
      Positioned(
        left: p.x, top: 0, width: _pipeWidth, height: p.gapTop,
        child: Container(decoration: deco),
      ),
      Positioned(
        left: p.x, top: bottomTop, width: _pipeWidth,
        height: bottomHeight > 0 ? bottomHeight : 0,
        child: Container(decoration: deco),
      ),
    ];
  }

  Widget _buildOverlay(ColorScheme colors, ThemeData theme) {
    final isGameOver = _status == _RunStatus.gameOver;
    final isCountdown = _status == _RunStatus.countdown;
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: isCountdown
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Get Ready',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$_countdownValue',
                      style: theme.textTheme.displayLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isGameOver ? 'Game Over' : 'Hops Hopper',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (isGameOver) ...[
                      Text('Score: $_score  ·  Level $_level',
                          style: const TextStyle(color: Colors.white, fontSize: 16)),
                      if (_lastReward > 0) ...[
                        const SizedBox(height: 4),
                        Text('🥕 +$_lastReward carrots earned',
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                      const SizedBox(height: 16),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          'Tap to flap through the gaps. Every 5 cleared = 1 🥕, and it '
                          'speeds up every $_pointsPerLevel pipes.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
                        ),
                      ),
                    FilledButton(
                      onPressed: _beginCountdown,
                      child: Text(isGameOver ? 'Play Again' : 'Start'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
