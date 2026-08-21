// lib/services/sos_service.dart
//
// Dart-side half of Silent SOS — the Android native half lives in
// MainActivity.kt (the "com.example.client/sos_tile" MethodChannel) and
// HopsSosTileService.kt (the actual Quick Settings tile). See that
// service's header comment for why a tile tap doesn't fire Emergency Flare
// directly: it only sets sosTriggeredNotifier, which hops_app.dart
// consumes the exact same way it already consumes main.dart's
// shortcutNotifier for the existing "Emergency Flare" app-icon shortcut —
// opening the same confirm-then-reason dialog, never bypassing it.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One-shot signal, same shape/convention as main.dart's shortcutNotifier —
/// flips true when the Silent SOS tile (or the in-app volume-hold
/// fallback, also implemented natively in MainActivity.kt) fires. Kept as
/// its own notifier rather than folded into shortcutNotifier since it
/// arrives over a dedicated native channel that quick_actions knows
/// nothing about.
final ValueNotifier<bool> sosTriggeredNotifier = ValueNotifier<bool>(false);

class SosService {
  SosService._();

  static const MethodChannel _channel = MethodChannel('com.example.client/sos_tile');
  static bool _initialized = false;

  /// Call once at startup (main.dart's main()). Wires up delivery for a
  /// WARM start (Hops already running when the tile fires again) and
  /// checks for a COLD-start trigger (Hops was launched fresh by the tile
  /// tap) — the same cold/warm split shortcutNotifier's own comment
  /// documents for the existing app-icon shortcut, just fed by this
  /// separate channel instead of quick_actions.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isAndroid) return; // no Quick Settings equivalent on iOS/desktop
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sosTriggered') {
        sosTriggeredNotifier.value = true;
      }
    });
    try {
      final hadPending = await _channel.invokeMethod<bool>('consumePendingSos') ?? false;
      if (hadPending) sosTriggeredNotifier.value = true;
    } catch (_) {
      // Channel unavailable (non-Android platform, or a build predating
      // this native code) — Silent SOS just isn't offered; nothing to
      // surface an error about.
    }
  }

  /// Prompts Android's own "Add tile?" system dialog (API 33+ only).
  /// Returns false — not an error — on older Android or any failure;
  /// callers (sos_settings_page.dart) fall back to showing manual "swipe
  /// down twice, tap edit" instructions in that case.
  static Future<bool> requestAddTile() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestAddTile') ?? false;
    } catch (_) {
      return false;
    }
  }
}
