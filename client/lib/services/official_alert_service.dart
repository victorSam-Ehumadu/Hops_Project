// lib/services/official_alert_service.dart
//
// Composes and broadcasts the Admin app's Official Alert (ADM:/ADM_OFF:).
// Pulled out of what used to be hops_app.dart's _broadcastOfficialAlert /
// _cancelOfficialAlert / _startSignatureCycle — the student app no longer
// sends these at all, only *receives* them (see hops_app.dart's ADM:/
// ADM_OFF: parsing, still intact there). Deliberately a standalone
// singleton rather than reusing the old private student-app methods: the
// two now live in genuinely separate app entry points with separate
// lifecycles, and hops_app.dart's personal Emergency Flare still needs its
// own copy of this same signature-cycling shape for EMG:/EMG_OFF: — see
// that file's _startSignatureCycle.
//
// Wire format (ADM:/ADM_OFF: prefixes, the 8/14-char sender/reason
// truncation, the signature chunk encoding via encodeFlareSigChunk) MUST
// stay byte-identical to what hops_app.dart's receiver expects, or a real
// admin's alert would silently fail to parse on every student's phone —
// don't change any of these without checking that side too.
import 'dart:async';
import 'dart:convert';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypton/crypton.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/services/hops_constants.dart';

class OfficialAlertService {
  OfficialAlertService._();
  static final OfficialAlertService instance = OfficialAlertService._();

  Timer? _cancelTimer;
  Timer? _sigCycleTimer;

  /// True for as long as an alert is actively (re-)advertising — the Alert
  /// tab listens to this to drive its Cancel button and the 30s countdown.
  final ValueNotifier<bool> isActive = ValueNotifier<bool>(false);

  Future<void> _advertise(
    String localName, {
    ManufacturerData? manufacturerData,
    bool manufacturerDataInScanResponse = false,
  }) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: localName,
      services: [HOPS_SERVICE_UUID], // always tagged so the campus BLE filter picks it up
      manufacturerData: manufacturerData,
      addManufacturerDataInScanResponse: manufacturerDataInScanResponse,
    );
  }

  /// Returns false if advertising itself couldn't start after retries
  /// (Bluetooth off, adapter busy, etc.) — same retry-then-report shape as
  /// the old _broadcastEmergencyFlare/_broadcastOfficialAlert had, since an
  /// unguarded single attempt was a real "silently does nothing" failure
  /// mode on this safety-critical a broadcast.
  Future<bool> broadcast({required String myUsername, required String reason}) async {
    _cancelTimer?.cancel();
    _cancelTimer = null;

    const maxSenderLen = 8;
    const maxReasonLen = 14;
    final sender = myUsername.length > maxSenderLen ? myUsername.substring(0, maxSenderLen) : myUsername;
    final shortReason = reason.length > maxReasonLen ? reason.substring(0, maxReasonLen) : reason;
    final advName = "ADM:$sender:$shortReason";

    bool started = false;
    for (var attempt = 0; attempt < 3 && !started; attempt++) {
      try {
        await _advertise(advName);
        started = true;
      } catch (_) {
        if (attempt < 2) await Future.delayed(const Duration(milliseconds: 400));
      }
    }
    if (!started) return false;

    isActive.value = true;
    unawaited(_startSignatureCycle(advName));
    // Best-effort, fire-and-forget — see log_official_alert in
    // 0008_admin_moderation.sql. A logging failure shouldn't block or
    // unwind an alert that's already live on the air.
    unawaited(_logAlert(reason));

    _cancelTimer = Timer(const Duration(seconds: 30), () => cancel(silent: true));
    return true;
  }

  Future<void> cancel({bool silent = false}) async {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    _sigCycleTimer?.cancel();
    _sigCycleTimer = null;
    if (!isActive.value) return;

    final prefs = await SharedPreferences.getInstance();
    final myUsername = prefs.getString('my_username') ?? '';
    final sender = myUsername.length > 8 ? myUsername.substring(0, 8) : myUsername;
    await _advertise("ADM_OFF:$sender");

    // Off the air a few seconds after the cancel notice has had a chance
    // to actually go out, rather than the instant this returns.
    Future.delayed(const Duration(seconds: 5), () => BlePeripheral.stopAdvertising());
    isActive.value = false;
  }

  /// Signs [advName] with this device's own private key, then cycles the
  /// signature across manufacturer-data chunks alongside the still-fixed
  /// advertised name — same cadence as hops_app.dart's _startSignatureCycle
  /// (1.2s/chunk, 3 full cycles) since receivers on both ends need to agree
  /// on that cadence to reassemble it in time.
  Future<void> _startSignatureCycle(String advName) async {
    try {
      const storage = FlutterSecureStorage();
      final privateKeyStr = await storage.read(key: 'private_key');
      if (privateKeyStr == null) return; // nothing to sign with
      final privateKey = RSAPrivateKey.fromString(privateKeyStr);
      final signature = privateKey.createSHA256Signature(Uint8List.fromList(utf8.encode(advName)));

      final chunks = <List<int>>[];
      for (var i = 0; i < signature.length; i += kFlareSigChunkBudgetBytes) {
        final end = (i + kFlareSigChunkBudgetBytes < signature.length)
            ? i + kFlareSigChunkBudgetBytes
            : signature.length;
        chunks.add(signature.sublist(i, end));
      }
      if (chunks.isEmpty) return;

      const perChunkDuration = Duration(milliseconds: 1200);
      const totalCycles = 3;

      void step(int index, int cycle) {
        if (!isActive.value) return; // cancelled/expired mid-cycle — stop
        _advertise(
          advName,
          manufacturerData: ManufacturerData(
            manufacturerId: kCommunityManufacturerId,
            data: encodeFlareSigChunk(
              chunkIndex: index,
              totalChunks: chunks.length,
              chunkBytes: chunks[index],
            ),
          ),
          manufacturerDataInScanResponse: true,
        );
        _sigCycleTimer = Timer(perChunkDuration, () {
          if (index + 1 < chunks.length) {
            step(index + 1, cycle);
          } else if (cycle + 1 < totalCycles) {
            step(0, cycle + 1);
          }
          // Done cycling — advName keeps advertising, unsigned, until
          // cancel/expiry.
        });
      }

      step(0, 0);
    } catch (_) {
      // No local key, or signing failed — the alert still broadcasts
      // unsigned rather than not at all; receivers just won't be able to
      // verify it (see hops_app.dart's ADM: parsing).
    }
  }

  Future<void> _logAlert(String reason) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('log_official_alert', params: {
        'p_hops_token': token,
        'p_reason': reason,
      });
    } catch (_) {
      // Offline/unreachable — the alert itself already went out over BLE
      // regardless; only the Dashboard/Action Log's record of it is lost.
    }
  }
}
