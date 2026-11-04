// lib/services/bluetooth_permissions.dart
//
// Asks for the Bluetooth permissions that actually exist on the device
// being run on.
//
// BLUETOOTH_SCAN, BLUETOOTH_ADVERTISE and BLUETOOTH_CONNECT were
// introduced in Android 12 (API 31). Below that, Bluetooth is covered by
// the install-time BLUETOOTH/BLUETOOTH_ADMIN permissions, and the only
// runtime permission classic discovery needs is location.
//
// Requesting the Android 12 trio on an older phone does not merely fail
// harmlessly. permission_handler resolves each of them to a manifest
// entry only when SDK_INT >= S (PermissionUtils.java:283), and
// PermissionManager.java:369 records any permission with no manifest
// entry as DENIED. So on an Android 8/9 handset all three come back
// denied — with no dialog shown, and nothing in system settings the user
// can switch on to change it.
//
// Any screen that then required all four to be granted was permanently
// locked out on those devices. That is what made 1:1 chat unusable on a
// Huawei P20 lite: the permission gate failed before connect() was ever
// called, so it was not that the two phones could not find each other —
// the older one never started looking. The "Bluetooth & location
// permission needed" message was accurate about the state and completely
// misleading about the cause.
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// First Android release where the Bluetooth runtime permissions exist.
const int kAndroidSApiLevel = 31;

class BluetoothPermissions {
  BluetoothPermissions._();

  static const MethodChannel _meta =
      MethodChannel('com.example.client/rfcomm/meta');

  static int? _sdkInt;

  /// Android API level, or null off Android (Windows desktop builds).
  ///
  /// Cached — it cannot change while the process is alive, and this is
  /// consulted on every permission gate.
  static Future<int?> sdkInt() async {
    if (_sdkInt != null) return _sdkInt;
    try {
      return _sdkInt = await _meta.invokeMethod<int>('getSdkInt');
    } catch (_) {
      return null;
    }
  }

  /// The permissions worth asking for on this device.
  ///
  /// Location is requested on every version: below Android 12 it is what
  /// authorises classic-Bluetooth discovery, and on 12+ it is still what
  /// several OEM builds require before `startDiscovery()` returns
  /// anything, despite `neverForLocation` on BLUETOOTH_SCAN.
  static Future<List<Permission>> _requiredPermissions({
    bool includeNearbyWifi = false,
  }) async {
    final sdk = await sdkInt();
    final permissions = <Permission>[Permission.location];

    if (sdk == null || sdk >= kAndroidSApiLevel) {
      // Unknown version is treated as modern: asking for a permission
      // that exists is recoverable by the user, whereas failing to ask
      // for one that does is not.
      permissions.addAll(const [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ]);
    }

    // NEARBY_WIFI_DEVICES arrived in Android 13 and is only needed by
    // Nearby Connections (Hops Share), not by RFCOMM chat.
    if (includeNearbyWifi && (sdk == null || sdk >= 33)) {
      permissions.add(Permission.nearbyWifiDevices);
    }

    return permissions;
  }

  /// Requests what this device needs and reports whether it can proceed.
  ///
  /// [includeNearbyWifi] for Nearby Connections callers (Hops Share).
  static Future<bool> request({bool includeNearbyWifi = false}) async {
    final statuses =
        await requestStatuses(includeNearbyWifi: includeNearbyWifi);
    return statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );
  }

  /// Same request, but hands back the raw statuses.
  ///
  /// For callers that need to tell an ordinary denial from a permanent one
  /// — Android stops showing the dialog once something is permanently
  /// denied, so `request()` returns instantly and the tap looks like it did
  /// nothing. Only `openAppSettings()` can recover from that, and a caller
  /// can't know to offer it without seeing the statuses. See
  /// `admin_settings_screen.dart`'s Bluetooth restart.
  static Future<Map<Permission, PermissionStatus>> requestStatuses({
    bool includeNearbyWifi = false,
  }) async {
    final required =
        await _requiredPermissions(includeNearbyWifi: includeNearbyWifi);
    return required.request();
  }

  /// Whether the needed permissions are already held, without prompting.
  static Future<bool> isGranted({bool includeNearbyWifi = false}) async {
    final required =
        await _requiredPermissions(includeNearbyWifi: includeNearbyWifi);
    for (final permission in required) {
      final status = await permission.status;
      if (status != PermissionStatus.granted &&
          status != PermissionStatus.limited) {
        return false;
      }
    }
    return true;
  }
}
