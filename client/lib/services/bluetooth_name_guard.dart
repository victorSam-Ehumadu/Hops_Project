// lib/services/bluetooth_name_guard.dart
//
// Protects the device's system Bluetooth name from the wire protocol.
//
// ble_peripheral has no separate BLE "local name" field. To advertise a
// name it overwrites the adapter's global name and sets the include-device-
// name flag (BlePeripheralPlugin.kt: `adapter?.name = it`, then
// `.setIncludeDeviceName(localName != null)`). Since Hops encodes every
// event into that name, advertising "CHT:diya:Test2" renames the phone
// itself to "CHT:diya:Test2" — which is what every other device shows in
// its Bluetooth settings, and what a bonded device caches in its paired
// list.
//
// Two failure modes made that stick permanently rather than transiently:
//
//   1. Nothing restored the name when the app backgrounded or was
//      disposed. Both paths stopped advertising and left the name set.
//   2. The "original" name was read at startup with no check on what it
//      was. If the app had been killed mid-advertisement, the adapter was
//      already called "HPS:xk3f9a2b" by then, so that string was captured
//      AS the original — and every subsequent "restore" faithfully put a
//      protocol string back. The mechanism meant to clean up became the
//      thing keeping it dirty.
//
// This class fixes both: the real name is recognised, persisted so it
// survives a process kill, and never overwritten by something that looks
// like a Hops payload.
//
// What it cannot fix: while an advertisement is actually on the air, the
// name IS the protocol, so nearby devices will see it. That is inherent to
// the design and would need the payload moved off the name entirely.
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every prefix this app writes into an advertisement local name.
///
/// Kept complete deliberately — a prefix missing from this list is one
/// that can be mistaken for a user's real Bluetooth name and saved as the
/// value to restore to. Add to it whenever a new prefix is introduced.
const List<String> kHopsAdvertisementPrefixes = <String>[
  'HPS:', // presence beacon
  'EMG:', 'EMG_OFF:', // emergency flare + stand-down
  'ADM:', 'ADM_OFF:', // official alert + stand-down
  'FR:', 'FA:', // friend request / accept
  'WR:', 'WA:', // watch-buddy request / accept
  'WX:', // watch cancelled — sent by either side, see hops_app.dart
  'ACK:', 'HOP:', // manual pairing handshake
  'CHT:', // chat ping
  'VBT:', 'VBX:', // Vibe Check
  'LNR:', 'LNF:', // Lost & Found
  'SBF:', 'SBI:', 'SBC:', 'SBX:', // Study Bunny
  'CM:', 'CA:', 'CX:', // community alerts
  'DM:', // direct message
];

/// True if [name] is one of this app's advertisement payloads rather than
/// a name a person chose for their phone.
bool looksLikeHopsAdvertisementName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  return kHopsAdvertisementPrefixes.any(trimmed.startsWith);
}

class BluetoothNameGuard {
  BluetoothNameGuard._();

  static const MethodChannel _meta =
      MethodChannel('com.example.client/rfcomm/meta');

  /// Persisted rather than held in memory: the case that poisoned the old
  /// implementation is the app being killed while advertising, which is
  /// exactly the case an in-memory value does not survive.
  static const String _prefsKey = 'original_bluetooth_adapter_name_v1';

  static String? _cached;

  /// The device's real Bluetooth name, or null if it has never been seen.
  ///
  /// Reads the adapter and stores the result only if it does not look like
  /// a Hops payload. When it does look like one, the stored value is left
  /// alone and returned instead — that is the whole point: a protocol
  /// string must never become the thing we restore to.
  static Future<String?> capture() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);

    String? current;
    try {
      current = await _meta.invokeMethod<String>('getAdapterName');
    } catch (_) {
      // Channel unavailable (desktop, or Bluetooth off) — nothing to do.
    }

    if (current != null &&
        current.isNotEmpty &&
        !looksLikeHopsAdvertisementName(current)) {
      if (stored != current) await prefs.setString(_prefsKey, current);
      _cached = current;
      return current;
    }

    _cached = stored;
    return stored;
  }

  /// The name to restore to, without touching the adapter.
  static Future<String?> originalName() async {
    if (_cached != null) return _cached;
    final prefs = await SharedPreferences.getInstance();
    return _cached = prefs.getString(_prefsKey);
  }

  /// Puts the device's real Bluetooth name back.
  ///
  /// Safe to call when nothing needs restoring — it reads the adapter
  /// first and does nothing if the name is already correct, so this can be
  /// called liberally from lifecycle paths without churning the adapter.
  static Future<void> restore() async {
    final original = await originalName();
    if (original == null || original.isEmpty) return;

    try {
      final current = await _meta.invokeMethod<String>('getAdapterName');
      if (current == original) return;
      await _meta.invokeMethod('setAdapterName', {'name': original});
    } catch (_) {
      // Best effort. Failing to restore leaves the adapter showing a
      // payload string, which is untidy but not harmful, and the next
      // lifecycle transition will try again.
    }
  }
}
