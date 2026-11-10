import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:client/views/received_files_page.dart';
import 'package:path_provider/path_provider.dart';
import 'package:client/services/bluetooth_permissions.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/main.dart' show nearbyConnectionsSessionCount;
import 'package:client/widgets/hops_card.dart';
import 'package:client/widgets/hops_background_pattern.dart';

class HopsSharePage extends StatefulWidget {
  final String myUsername;
  const HopsSharePage({super.key, required this.myUsername});
  @override
  State<HopsSharePage> createState() => _HopsSharePageState();
}

class _HopsSharePageState extends State<HopsSharePage> {
  final List<NearbyDevice> _discoveredDevices = [];
  String? _connectedEndpointId;
  // The peer's Hops username, shown in the "Connected to ___" banner
  // instead of _connectedEndpointId — Nearby Connections' endpointId is an
  // internal 4-character code (e.g. "NO9J") assigned per-session by the
  // package, not anything that identifies the peer to a person. Populated
  // either from the discovered-device list (the requester already knows
  // it before connecting) or from ConnectionInfo.endpointName (what the
  // OTHER side's requestConnection call passed as its own nickname).
  String? _connectedPeerName;
  bool _isConnected = false;
  // The endpointId a "Connect" tap is currently waiting on — Nearby
  // Connections' BLE+Bluetooth-Classic handshake can genuinely take a few
  // seconds, so this drives a spinner on that device's tile instead of the
  // button just sitting there looking unresponsive. Cleared on success,
  // failure, or _connectTimeout firing.
  String? _connectingEndpointId;
  Timer? _connectTimeout;
  PlatformFile? _pickedFile;
  bool _isSending = false;
  // 0.0–1.0 while a send is in flight, null otherwise — fed by
  // Nearby Connections' own onPayloadTransferUpdate, not a fake/simulated
  // timer, so it reflects real bytes-on-the-wire progress.
  double? _sendProgress;
  // The payload ID Nearby Connections assigned to the FILE payload we're
  // currently sending — onPayloadTransferUpdate fires for every payload on
  // this connection (including the small metadata BYTES payload sent right
  // alongside it), so progress tracking has to filter on this, not just
  // "are we sending something."
  int? _sendingPayloadId;
  // Invalidated by _cancelSend — see its use in _sendPickedFile.
  Object? _sendToken;
  // Mirror of _sendingPayloadId/_sendProgress for the INCOMING direction.
  // Nearby Connections reports IN_PROGRESS updates for a file the peer is
  // sending us in exactly the same way as one we're sending, so the
  // receiving end can show a real progress bar too — instead of the screen
  // sitting silent until a "Received X" snackbar suddenly appears at the
  // end, which for a large file over Bluetooth is indistinguishable from
  // nothing happening at all.
  int? _receivingPayloadId;
  double? _receiveProgress;
  String? _receivingFileName;
  bool _hasPermissions = false;
  bool _checkingPermissions = true;

  // Files in flight FROM the peer, keyed by the FILE payload's ID — a
  // transfer isn't "received" until BOTH halves have arrived: the actual
  // bytes (PayloadType.FILE, landing at some OS-chosen temp path/URI, whose
  // content isn't trustworthy until onPayloadTransferUpdate reports
  // SUCCESS for that ID) and the small metadata BYTES payload sent
  // alongside it (sender/fileName/size) that's needed to know what to name
  // it. The two can arrive in either order.
  final Map<int, _IncomingFile> _incoming = {};

  final TextEditingController _textNoteController = TextEditingController();

  // Service ID must be passed explicitly — the package default is unrelated.
  static const String _serviceId = "com.hops.share";

  // Every BYTES payload on this channel now starts with a one-byte marker —
  // needed once file transfers and text notes both need to travel over the
  // same "sendBytesPayload" pipe. See _kMetaFile/_kNote below and
  // hops_chat_service.dart, which established this exact pattern first.
  static const int _kMetaFile = 0xF1;
  static const int _kNote = 0xF2;

  @override
  void initState() {
    super.initState();
    UnreadTracker.instance.clear(UnreadSource.hopsShare);
    // Stop BLE advertising while Nearby Connections is active — both compete
    // for Bluetooth Classic resources.
    BlePeripheral.stopAdvertising();
    // Tells HopsApp (which is still alive underneath this pushed screen) to
    // pause its own background BLE advertising-refresh/scan-cycle timers
    // for as long as this session is open — see hops_app.dart's
    // _pauseBackgroundBleForNearbyConnections for why those otherwise keep
    // firing regardless of what's on top of it.
    nearbyConnectionsSessionCount.value++;
    _requestPermissionsAndStart();
  }

  @override
  void dispose() {
    _connectTimeout?.cancel();
    _cleanupNearby();
    // Restore Hops BLE advertising WITH the service UUID so the radar
    // hardware filter picks us up again immediately.
    BlePeripheral.startAdvertising(
      localName: "HPS:${widget.myUsername}",
      services: [HOPS_SERVICE_UUID],
    );
    nearbyConnectionsSessionCount.value--;
    _textNoteController.dispose();
    super.dispose();
  }

  // ── Permissions ────────────────────────────────────────────────────────────
  // Nearby Connections on Android 13+ requires NEARBY_WIFI_DEVICES in addition
  // to the Bluetooth permissions. Without it, discovery silently finds nothing.
  Future<void> _requestPermissionsAndStart() async {
    // Version-aware — see services/bluetooth_permissions.dart. It asks for
    // NEARBY_WIFI_DEVICES only on Android 13+ and for the Bluetooth
    // runtime trio only on Android 12+; on older devices those resolve to
    // no manifest entry at all and come back permanently denied, which
    // used to leave this screen stuck on its permissions prompt.
    final granted = await BluetoothPermissions.request(includeNearbyWifi: true);

    setState(() {
      _hasPermissions = granted;
      _checkingPermissions = false;
    });

    if (granted) {
      _startNearbyDiscoveryAndAdvertising();
    }
  }

  // ── Nearby Connections ─────────────────────────────────────────────────────
  void _startNearbyDiscoveryAndAdvertising() {
    // Both advertise AND discover simultaneously — P2P_CLUSTER supports this.
    _startAdvertising();
    _startDiscovery();
  }

  void _startAdvertising() {
    Nearby().startAdvertising(
      widget.myUsername,
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,           // ← was missing; used the package default before
      onConnectionInitiated: _handleConnectionInitiated,
      onConnectionResult: _handleConnectionResult,
      onDisconnected: _handleDisconnected,
    );
  }

  // ── Connection handshake (shared by both directions) ───────────────────────
  // Nearby Connections registers these three callbacks separately for the
  // advertiser (startAdvertising) and the discoverer (requestConnection),
  // and BOTH sets fire on a device doing both at once — which under
  // P2P_CLUSTER we always are. They used to be two near-duplicate copies
  // with subtly different behaviour, and that is what broke a simultaneous
  // "Connect" tap on both phones:
  //
  //   1. Each device received onConnectionInitiated TWICE for the same peer
  //      — once from its own outgoing request, once from the peer's
  //      incoming one — and called acceptConnection both times. The second
  //      accept is an out-of-order call on an endpoint that has already
  //      been accepted; it fails and takes the handshake down with it, so
  //      NEITHER side ever reached the file-sending screen.
  //   2. acceptConnection also overwrites the plugin's single payload-
  //      callback slot, so even a surviving double-accept would leave the
  //      transfer callbacks wired to the wrong closure.
  //   3. requestConnection's Future was neither awaited nor caught, so the
  //      PlatformException thrown by whichever side loses that race went
  //      nowhere — the spinner just sat there until the 20s timeout.
  //   4. The advertiser's copy set _isConnected at *accept* time instead of
  //      waiting for the result, so a handshake that later failed could
  //      strand a phone on a connected-looking screen with no connection
  //      behind it.
  //
  // Accepting each endpoint at most once collapses a mutual tap into the
  // single connection Nearby was always going to give us anyway.

  /// Endpoints acceptConnection has already been called for. Cleared on
  /// disconnect and teardown, so a genuine later reconnect to the same peer
  /// isn't mistaken for a duplicate.
  final Set<String> _acceptedEndpoints = {};

  void _handleConnectionInitiated(String id, ConnectionInfo info) {
    // info.endpointName is the OTHER side's own nickname, i.e. their Hops
    // username. On an incoming request this is the only place that name is
    // available at all, so it has to be captured here rather than derived
    // from the endpointId later.
    _connectedPeerName = info.endpointName;
    // A handshake starting is already proof the peer is answering, so the
    // "peer never responded" watchdog has done its job.
    _connectTimeout?.cancel();
    if (!_acceptedEndpoints.add(id)) return; // already accepted this peer
    Nearby()
        .acceptConnection(
      id,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: _onTransferUpdate,
    )
        .catchError((_) {
      // Roll the guard back so a retry isn't permanently blocked by a
      // single failed accept.
      _acceptedEndpoints.remove(id);
      return false;
    });
  }

  void _handleConnectionResult(String id, Status status) {
    _connectTimeout?.cancel();
    if (!mounted) return;
    if (status == Status.CONNECTED) {
      setState(() {
        _connectedEndpointId = id;
        _isConnected = true;
        _connectingEndpointId = null;
      });
      // Radio housekeeping — advertising/discovery are no longer needed
      // once the connection is up, and leaving them running competes with
      // it for the same radio (part of what was making "Connect" slow).
      // hops_chat_service.dart established this exact pattern first.
      Nearby().stopAdvertising();
      Nearby().stopDiscovery();
      return;
    }
    if (_isConnected && _connectedEndpointId == id) {
      // Already connected to this peer through the other direction of a
      // simultaneous request — this is the losing half of that race
      // reporting its own failure, NOT the live connection going away
      // (that arrives via onDisconnected). Tearing the session down here
      // would kill a perfectly good connection.
      setState(() => _connectingEndpointId = null);
      return;
    }
    _acceptedEndpoints.remove(id);
    setState(() {
      _connectedEndpointId = null;
      _isConnected = false;
      _connectedPeerName = null;
      _connectingEndpointId = null;
    });
    _startDiscovery(); // didn't connect — keep the device list alive
  }

  void _handleDisconnected(String id) {
    _incoming.clear();
    _acceptedEndpoints.remove(id);
    if (!mounted) return;
    setState(() {
      _connectedEndpointId = null;
      _isConnected = false;
      _connectedPeerName = null;
      _connectingEndpointId = null;
      _receivingPayloadId = null;
      _receiveProgress = null;
      _receivingFileName = null;
    });
    // Bring advertising+discovery back so the screen is usable again
    // instead of going quietly dead after a disconnect.
    _startNearbyDiscoveryAndAdvertising();
  }

  void _startDiscovery() {
    Nearby().startDiscovery(
      widget.myUsername,
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,           // ← was missing
      onEndpointFound: (id, name, serviceId) {
        setState(() {
          _discoveredDevices.removeWhere((d) => d.id == id);
          _discoveredDevices.add(NearbyDevice(id: id, name: name));
        });
      },
      onEndpointLost: (id) {
        setState(() => _discoveredDevices.removeWhere((d) => d.id == id));
      },
    );
  }

  void _cleanupNearby() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    _incoming.clear();
    _acceptedEndpoints.clear();
  }

  Future<void> _connectToDevice(String endpointId) async {
    // Stop discovery before requesting a connection — Nearby Connections'
    // own guidance, and it's a real contributor to a slow "Connect" tap:
    // leaving the discovery scan running throughout the handshake
    // competes for the same BLE radio as the connection negotiation
    // itself. Resumed below (_startDiscovery) if the attempt doesn't pan
    // out, so the device list keeps working either way.
    await Nearby().stopDiscovery();

    // We already know this peer's username from the discovered-device
    // list — no need to wait for the handshake to show a name.
    final device = _discoveredDevices.firstWhere(
      (d) => d.id == endpointId,
      orElse: () => NearbyDevice(id: endpointId, name: endpointId),
    );
    _connectedPeerName = device.name;

    setState(() => _connectingEndpointId = endpointId);
    // The handshake has no built-in timeout of its own — if the peer never
    // answers (walked out of range mid-tap, etc.) onConnectionResult might
    // just never fire. Without this the spinner would spin forever with no
    // way out except leaving the screen.
    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 20), () {
      // The _isConnected guard is new: with both phones tapping Connect at
      // once, the connection can already be up via the peer's incoming
      // request by the time this fires, and the old version would then
      // wipe _connectedPeerName and claim a failure on a live session.
      if (!mounted || _isConnected || _connectingEndpointId != endpointId) {
        return;
      }
      setState(() {
        _connectingEndpointId = null;
        _connectedPeerName = null;
      });
      _startDiscovery();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't connect to ${device.name} — try again.")),
      );
    });

    // Awaited and caught, unlike before. When both phones tap Connect at
    // the same moment, one of the two requests necessarily loses the race
    // and throws (ALREADY_CONNECTED_TO_ENDPOINT / OUT_OF_ORDER_API_CALL);
    // left uncaught that became an unhandled async error, and the spinner
    // ran all the way to the 20-second timeout even when the connection
    // had in fact succeeded through the other direction. Losing that race
    // is not a failure — the shared handlers are already bringing the same
    // connection up — so this only reports a problem if nothing connected.
    try {
      await Nearby().requestConnection(
        widget.myUsername,
        endpointId,
        onConnectionInitiated: _handleConnectionInitiated,
        onConnectionResult: _handleConnectionResult,
        onDisconnected: _handleDisconnected,
      );
    } catch (_) {
      if (!mounted ||
          _isConnected ||
          _acceptedEndpoints.contains(endpointId)) {
        return; // the other direction has it in hand
      }
      _connectTimeout?.cancel();
      setState(() {
        _connectingEndpointId = null;
        _connectedPeerName = null;
      });
      _startDiscovery();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't connect to ${device.name} — try again.")),
      );
    }
  }

  // ── Payload handling ───────────────────────────────────────────────────────
  // Dispatches on the type byte set by _sendPickedFile/_sendTextNote below.
  // FILE payloads (the actual file bytes) are handled separately —
  // Nearby Connections delivers those through this same callback too, with
  // payload.type == PayloadType.FILE, at whatever path/URI the OS chose;
  // the content there isn't complete/trustworthy until
  // onPayloadTransferUpdate reports SUCCESS for payload.id (see
  // _onTransferUpdate), so this just records where it landed.
  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.FILE) {
      final entry = _incoming.putIfAbsent(payload.id, () => _IncomingFile());
      // filePath is deprecated (Android 10 and below only); uri is the
      // Android 11+ scoped-storage form — copyFileAndDeleteOriginal below
      // knows how to resolve either. Reading it is intentional here (it's
      // the only way to support the pre-scoped-storage fallback), not an
      // oversight.
      // ignore: deprecated_member_use
      entry.filePath = payload.filePath;
      entry.uri = payload.uri;
      unawaited(_maybeFinishIncoming(payload.id));
      return;
    }
    if (payload.type != PayloadType.BYTES) return;
    final data = payload.bytes;
    if (data == null || data.isEmpty) return;
    switch (data[0]) {
      case _kMetaFile:
        Map<String, dynamic> meta;
        try {
          meta = json.decode(utf8.decode(data.sublist(1))) as Map<String, dynamic>;
        } catch (_) {
          return; // malformed/corrupt — nothing safe to do with it
        }
        final id = meta['payloadId'] as int?;
        if (id == null) return;
        final entry = _incoming.putIfAbsent(id, () => _IncomingFile());
        entry.sender = meta['sender'] as String?;
        entry.fileName = meta['fileName'] as String?;
        entry.size = meta['size'] as int?;
        unawaited(_maybeFinishIncoming(id));
        break;
      case _kNote:
        final rest = data.sublist(1);
        final firstNull = rest.indexOf(0);
        if (firstNull == -1) return;
        final sender = utf8.decode(rest.sublist(0, firstNull));
        final secondNull = rest.indexOf(0, firstNull + 1);
        if (secondNull == -1) return;
        final fileName = utf8.decode(rest.sublist(firstNull + 1, secondNull));
        final fileData = rest.sublist(secondNull + 1);
        _saveReceivedFile(sender, fileName, Uint8List.fromList(fileData));
        break;
      default:
        // Unknown/future payload kind — ignore rather than misparse it.
        break;
    }
  }

  // Called whenever either half of an incoming file (the bytes, or the
  // metadata) newly becomes available — finalizes the transfer only once
  // BOTH are present, regardless of which arrived first.
  Future<void> _maybeFinishIncoming(int payloadId) async {
    final entry = _incoming[payloadId];
    if (entry == null || !entry.transferDone) return;
    if (entry.sender == null || entry.fileName == null) return;
    if (entry.filePath == null && entry.uri == null) return;
    _incoming.remove(payloadId);

    final dir = await getApplicationDocumentsDirectory();
    final destPath = '${dir.path}/${entry.fileName}';
    bool ok;
    if (entry.uri != null) {
      // Android 11+: the received file lives behind a content:// URI under
      // scoped storage — the plugin's own helper is the supported way to
      // pull it into a real app-owned path.
      ok = await Nearby().copyFileAndDeleteOriginal(entry.uri!, destPath);
    } else if (entry.filePath != null) {
      try {
        await File(entry.filePath!).copy(destPath);
        try {
          await File(entry.filePath!).delete();
        } catch (_) {
          // Best-effort cleanup of the OS-chosen temp file — not worth
          // surfacing an error for this.
        }
        ok = true;
      } catch (_) {
        ok = false;
      }
    } else {
      ok = false;
    }

    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save ${entry.fileName} from ${entry.sender}")),
        );
      }
      return;
    }

    int size = entry.size ?? 0;
    if (size <= 0) {
      try {
        size = await File(destPath).length();
      } catch (_) {}
    }
    await _updateReceivedFilesRecord(entry.sender!, entry.fileName!, size);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Received ${entry.fileName} from ${entry.sender}")),
      );
    }
    UnreadTracker.instance.mark(UnreadSource.hopsShare);
    await NotificationService.showFileReceivedNotification(sender: entry.sender!, fileName: entry.fileName!);
  }

  Future<void> _saveReceivedFile(
      String sender, String fileName, Uint8List data) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(data, flush: true);
    await _updateReceivedFilesRecord(sender, fileName, data.length);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "Received $fileName from $sender (${data.length} bytes)"),
        ),
      );
    }
    // Files can land here well after the sender's transfer finished — a
    // system notification is what actually tells you it arrived if you've
    // since backgrounded the app or moved to a different screen.
    UnreadTracker.instance.mark(UnreadSource.hopsShare);
    await NotificationService.showFileReceivedNotification(sender: sender, fileName: fileName);
  }

  Future<void> _updateReceivedFilesRecord(
      String sender, String fileName, int size) async {
    final dir = await getApplicationDocumentsDirectory();
    final recordFile = File('${dir.path}/received_files.json');
    List<Map<String, dynamic>> records = [];
    if (await recordFile.exists()) {
      final content = await recordFile.readAsString();
      if (content.isNotEmpty) {
        records = List<Map<String, dynamic>>.from(json.decode(content));
      }
    }
    records.add({
      'sender': sender,
      'fileName': fileName,
      'size': size,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    await recordFile.writeAsString(json.encode(records), flush: true);
  }

  // ── File picking & sending ─────────────────────────────────────────────────
  // withData: false (the default) — this used to load the ENTIRE file into
  // memory (withData: true) just to hand its bytes to sendBytesPayload.
  // That's the root of "can't send large files": a multi-hundred-MB file
  // could OOM the picker before a send was even attempted, and Android's
  // Nearby Connections BYTES payload type isn't meant for large transfers
  // in the first place. Leaving withData off keeps file_picker's on-disk
  // path (.path) instead, which _sendPickedFile now streams via
  // sendFilePayload — no full-file read into Dart memory at all.
  void _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _pickedFile = result.files.first);
    }
  }

  Future<void> _sendPickedFile() async {
    final file = _pickedFile;
    final endpointId = _connectedEndpointId;
    if (file == null || endpointId == null) return;
    final path = file.path;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't access that file — try picking it again.")),
      );
      return;
    }
    // Identifies THIS send attempt — checked after the sendFilePayload
    // await below returns, in case _cancelSend() ran while that request
    // was still in flight. Without it, a cancel tapped in that narrow
    // window would still let the metadata payload go out right after the
    // UI had already told the user "Transfer canceled."
    final token = Object();
    _sendToken = token;
    setState(() {
      _isSending = true;
      _sendProgress = 0;
    });
    try {
      // sendFilePayload streams straight from disk and is what actually
      // reports incremental IN_PROGRESS updates for anything beyond a
      // trivial size — sendBytesPayload (the old path) hands the whole
      // buffer over in one shot, so onPayloadTransferUpdate had nothing
      // meaningful to report until the single chunk finished, which is why
      // the bar looked "broken" rather than just fast.
      final payloadId = await Nearby().sendFilePayload(endpointId, path);
      if (_sendToken != token) {
        // Canceled while sendFilePayload was still in flight — tell
        // Nearby Connections to stop this one too and skip the metadata
        // send entirely.
        try {
          await Nearby().cancelPayload(payloadId);
        } catch (_) {}
        return;
      }
      _sendingPayloadId = payloadId;
      // A small metadata message travels alongside it so the receiver
      // knows what to name the file and who it's from — the FILE payload
      // itself carries none of that.
      final metaJson = json.encode({
        'payloadId': payloadId,
        'sender': widget.myUsername,
        'fileName': file.name,
        'size': file.size,
      });
      final metaPayload = Uint8List.fromList([_kMetaFile, ...utf8.encode(metaJson)]);
      await Nearby().sendBytesPayload(endpointId, metaPayload);
      // _isSending/_pickedFile are deliberately NOT reset here — the sends
      // above only confirm the OS accepted the request, well before the
      // file transfer itself finishes. Real progress and completion arrive
      // later via onPayloadTransferUpdate, filtered to _sendingPayloadId.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Transfer failed: $e")),
        );
      }
      setState(() {
        _isSending = false;
        _sendProgress = null;
        _sendingPayloadId = null;
      });
    }
  }

  // Cancels the file currently being sent. cancelPayload() asks Nearby
  // Connections to abort the transfer on the wire — best-effort; it's
  // wrapped in try/catch because the payload may already have finished or
  // failed by the time the tap lands (a fast transfer racing a slow
  // finger). Either way, the local UI state is reset unconditionally right
  // after, so "Cancel" always gets you back to a usable screen even if the
  // request itself couldn't be delivered.
  Future<void> _cancelSend() async {
    _sendToken = null;
    final id = _sendingPayloadId;
    if (id != null) {
      try {
        await Nearby().cancelPayload(id);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _isSending = false;
      _sendProgress = null;
      _sendingPayloadId = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Transfer canceled.")),
    );
  }

  // Nearby Connections reports progress for every payload crossing this
  // connection — both our own outgoing FILE transfer and (separately) any
  // incoming one from the peer — so this has to route by payload ID, not
  // just "are we sending something."
  void _onTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (_isSending && update.id == _sendingPayloadId) {
      if (!mounted) return;
      if (update.status == PayloadStatus.IN_PROGRESS && update.totalBytes > 0) {
        setState(() => _sendProgress = update.bytesTransferred / update.totalBytes);
      } else if (update.status == PayloadStatus.SUCCESS) {
        setState(() {
          _isSending = false;
          _sendProgress = null;
          _sendingPayloadId = null;
          _pickedFile = null;
        });
      } else if (update.status == PayloadStatus.FAILURE || update.status == PayloadStatus.CANCELED) {
        setState(() {
          _isSending = false;
          _sendProgress = null;
          _sendingPayloadId = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Transfer failed — try again.")),
        );
      }
      return;
    }

    // Otherwise this is progress on a FILE payload the peer is sending us —
    // the content at entry.filePath/uri isn't safe to read until SUCCESS.
    // Anything with no _incoming entry (notably the small metadata BYTES
    // payload that travels alongside each file) isn't a transfer the user
    // needs to watch, so it's ignored rather than driving the bar.
    final entry = _incoming[update.id];
    if (entry == null) return;

    if (update.status == PayloadStatus.IN_PROGRESS) {
      if (!mounted) return;
      setState(() {
        _receivingPayloadId = update.id;
        // May still be null on the first few updates — the metadata
        // payload carrying the name can arrive after the bytes start
        // flowing. The UI falls back to a generic label until it lands.
        _receivingFileName = entry.fileName;
        _receiveProgress = update.totalBytes > 0
            ? update.bytesTransferred / update.totalBytes
            : null;
      });
      return;
    }

    if (update.status == PayloadStatus.SUCCESS) {
      entry.transferDone = true;
      if (mounted) setState(_clearReceiveProgress);
      unawaited(_maybeFinishIncoming(update.id));
      return;
    }

    // FAILURE / CANCELED — drop the half-received transfer instead of
    // leaving both a stuck progress bar and an _incoming entry that can
    // never complete.
    _incoming.remove(update.id);
    if (!mounted) return;
    setState(_clearReceiveProgress);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Incoming ${entry.fileName ?? 'file'} didn't finish."),
      ),
    );
  }

  /// Call inside setState — resets the incoming-transfer indicator.
  void _clearReceiveProgress() {
    _receivingPayloadId = null;
    _receiveProgress = null;
    _receivingFileName = null;
  }

  void _sendTextNote() {
    if (_connectedEndpointId == null) return;
    final text = _textNoteController.text.trim();
    if (text.isEmpty) return;
    final payload = Uint8List.fromList([
      _kNote,
      ...utf8.encode(widget.myUsername), 0,
      ...utf8.encode("note.txt"), 0,
      ...utf8.encode(text),
    ]);
    Nearby().sendBytesPayload(_connectedEndpointId!, payload);
    _textNoteController.clear();
    setState(() {});
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Hops Share",
          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          TextButton.icon(
            icon: Icon(Icons.folder_open, color: colors.primary, size: 20),
            label: Text(
              "Received Files",
              style: TextStyle(color: colors.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReceivedFilesPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: HopsBackgroundPattern(
        child: Column(
          children: [
            // Shown on every state of this screen, including while
            // permissions are still being checked.
            //
            // Hops Share moves arbitrary files between two phones over a
            // direct link with no server in between — which means no virus
            // scanning, no reputation check, and nothing between the sender
            // and your storage but this sentence. The app genuinely cannot
            // tell a lecture PDF from a malicious APK, and saying so is
            // more honest than implying a check that does not exist.
            _buildSafetyNotice(colors),
            Expanded(
              child: _checkingPermissions
                  ? const Center(child: CircularProgressIndicator())
                  : !_hasPermissions
                  ? _buildPermissionDeniedView(colors)
                  : _isConnected
                  ? _buildConnectedView()
                  : _buildDiscoveryView(),
            ),
          ],
        ),
      ),
    );
  }

  /// Standing warning across the top of Hops Share.
  ///
  /// Deliberately NOT dismissible. It is one line, it sits above a feature
  /// whose whole purpose is accepting files from strangers in Bluetooth
  /// range, and the moment somebody most needs to read it is the moment
  /// they are least likely to go looking for it. Amber rather than red:
  /// this is a caution on an ordinary action, not an error, and a red bar
  /// permanently on screen stops being read within a day.
  Widget _buildSafetyNotice(ColorScheme colors) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9A825).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF9A825).withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, size: 18, color: Color(0xFFB26A00)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Only share and accept files from people you trust. Hops "
              "transfers files directly between phones and cannot scan them "
              "for viruses or harmful content.",
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionDeniedView(ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: HopsCard(
          radius: 20,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colors.error.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.wifi_off, size: 30, color: colors.error),
              ),
              const SizedBox(height: 16),
              Text(
                "Permissions required",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: colors.primary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                "Hops Share needs Nearby Devices, Location, and Bluetooth "
                    "permissions to find nearby peers. Please grant them in "
                    "Settings → Apps → Hops → Permissions.",
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurface.withValues(alpha: 0.65), fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    setState(() => _checkingPermissions = true);
                    _requestPermissionsAndStart();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text("Try Again"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiscoveryView() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(Icons.wifi_tethering, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  "Nearby Devices",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_discoveredDevices.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    "${_discoveredDevices.length}",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colors.primary),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _discoveredDevices.isEmpty
              ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  "Searching for nearby Hops users…",
                  style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                ),
              ],
            ),
          )
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: _discoveredDevices.length,
            itemBuilder: (context, index) {
              final device = _discoveredDevices[index];
              final connecting = _connectingEndpointId == device.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: HopsCard(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: colors.primary.withValues(alpha: 0.12),
                        child: Text(
                          device.name.isNotEmpty ? device.name[0].toUpperCase() : '?',
                          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          device.name,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // While a connection attempt to THIS device is in
                      // flight, swap its button for a spinner rather than
                      // leaving "Connect" sitting there looking
                      // unresponsive — the handshake can genuinely take a
                      // few seconds. Every OTHER device's button is
                      // disabled for the same window so a second tap can't
                      // kick off a competing attempt.
                      connecting
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: Padding(
                                padding: EdgeInsets.all(6),
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              ),
                            )
                          : ElevatedButton(
                              onPressed: _connectingEndpointId == null ? () => _connectToDevice(device.id) : null,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: colors.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                              ),
                              child: const Text("Connect"),
                            ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedView() {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.circle, size: 10, color: Colors.green),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    "Connected to ${_connectedPeerName ?? _connectedEndpointId ?? ''}",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          HopsCard(
            radius: 20,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.file_present_outlined, color: colors.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      "Send a File",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: colors.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text("Choose a File"),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                    ),
                    onPressed: _pickFile,
                  ),
                ),
                if (_pickedFile != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.insert_drive_file, size: 32, color: colors.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _pickedFile!.name,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                "${(_pickedFile!.size / 1024).toStringAsFixed(1)} kB",
                                style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.6)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isSending ? null : _sendPickedFile,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                          ),
                          child: _isSending
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                              : const Text("Send"),
                        ),
                      ],
                    ),
                  ),
                  if (_isSending) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(100),
                      child: LinearProgressIndicator(
                        // null progress (still 0 or first update hasn't landed
                        // yet) falls back to an indeterminate bar rather than
                        // sitting frozen at a misleading 0%.
                        value: (_sendProgress != null && _sendProgress! > 0) ? _sendProgress : null,
                        minHeight: 6,
                        backgroundColor: colors.primary.withValues(alpha: 0.12),
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _sendProgress != null
                              ? "${(_sendProgress! * 100).toStringAsFixed(0)}% sent"
                              : "Starting transfer…",
                          style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                        ),
                        InkWell(
                          onTap: _cancelSend,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.close, size: 13, color: colors.error),
                                const SizedBox(width: 3),
                                Text(
                                  "Cancel",
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colors.error),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
          // Receiving side of a transfer. Only rendered while one is
          // actually in flight — there's nothing useful to show otherwise,
          // and a permanently-present empty bar would just be noise.
          if (_receivingPayloadId != null) ...[
            const SizedBox(height: 16),
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.download_outlined, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Receiving ${_receivingFileName ?? 'a file'}",
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: colors.primary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: LinearProgressIndicator(
                      // Same fallback as the send bar: an indeterminate bar
                      // rather than one frozen at a misleading 0% while the
                      // first real update is still on its way.
                      value: (_receiveProgress != null && _receiveProgress! > 0)
                          ? _receiveProgress
                          : null,
                      minHeight: 6,
                      backgroundColor: colors.primary.withValues(alpha: 0.12),
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _receiveProgress != null
                        ? "${(_receiveProgress! * 100).toStringAsFixed(0)}% received"
                        : "Starting transfer…",
                    style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurface.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          HopsCard(
            radius: 20,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sticky_note_2_outlined, color: colors.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      "Send a Quick Note",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: colors.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _textNoteController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: "Type your note...",
                    filled: true,
                    fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _textNoteController.text.isNotEmpty
                        ? _sendTextNote
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                    ),
                    child: const Text("Send"),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NearbyDevice {
  final String id;
  final String name;
  NearbyDevice({required this.id, required this.name});
}

/// Tracks one in-flight incoming file transfer until both halves — the
/// actual bytes and the small metadata message describing them — have
/// arrived. See _onPayloadReceived/_maybeFinishIncoming above.
class _IncomingFile {
  String? sender;
  String? fileName;
  int? size;
  String? filePath; // Android 10 and below
  String? uri; // Android 11+ (scoped storage)
  bool transferDone = false;
}