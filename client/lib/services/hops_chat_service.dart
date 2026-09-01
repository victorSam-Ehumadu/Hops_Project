// lib/services/hops_chat_service.dart
//
// Real 1:1 chat transport, built on nearby_connections.
//
// Why this and not the RFCOMM path already sitting in rfcomm_chat_service.dart
// / MainActivity.kt: that path never had Dart call `openSession` to register
// the native peer channel, never captured a peer's classic-Bluetooth MAC
// address anywhere, and was never reachable from the UI at all. This service
// instead mirrors the ONE transport in this codebase that's already proven
// to work end-to-end — hops_share_page.dart's file-transfer flow — which
// does both startAdvertising AND startDiscovery together. (The earlier,
// abandoned chat_connection_service.dart only ever called startDiscovery,
// so two peers running it were both listening and neither was ever visible
// — a structural deadlock, not a Dart problem.)
//
// IMPORTANT: nearby_connections' `Nearby()` is a process-wide singleton with
// a SINGLE slot for each callback (see package source) — starting a second
// advertise/discover session anywhere else in the app (e.g. HopsSharePage)
// while a chat is connecting would overwrite these callbacks. Callers must
// call dispose() when leaving the chat screen, same discipline
// hops_share_page.dart already uses for the same reason.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:client/services/hops_constants.dart';

enum ChatConnectionState { connecting, connected, disconnected, failed }

class HopsChatService {
  final String myUsername;
  final String peerUsername;
  final void Function(String message)? onMessageReceived;
  final void Function(ChatConnectionState state)? onStateChanged;
  // bio, avatarBytes (null if the peer has no avatar set)
  final void Function(String bio, Uint8List? avatarBytes)? onProfileReceived;
  // The peer's rotating-ID seed — lets this device recognize their
  // "HPS:<token>" presence beacon on Radar from now on. See
  // hops_constants.dart's computeRotatingToken for what this is for.
  final void Function(Uint8List seed)? onRotatingSeedReceived;

  // Distinct from HopsSharePage's 'com.hops.share' so the two features
  // never mistake each other's sessions for one another.
  static const String _serviceId = 'com.hops.chat';

  // Every payload now starts with one byte identifying what it is — the
  // original wire format was chat-text-only with no type marker, which
  // this feature needed to change since profile info now shares the same
  // channel.
  static const int _payloadTypeChat = 0x01;
  static const int _payloadTypeProfile = 0x02;
  static const int _payloadTypeRotatingSeed = 0x03;

  String? _endpointId;
  bool _connecting = false;
  bool _connected = false;
  bool _disposed = false;

  // Campus testing surfaced a real gap: connect() used to make exactly one
  // advertise+discover attempt and then just sit there — if a single BLE
  // advertisement or the connection-request handshake got lost to RF noise
  // (a busy campus is a much noisier radio environment than a quiet home,
  // and BLE advertising/discovery packets have no delivery guarantee or
  // retry of their own), the chat hung on "Connecting…" forever with
  // nothing automatically trying again. This watchdog periodically cycles
  // advertising/discovery for a bounded number of attempts before finally
  // reporting failure, so a single lost packet doesn't need a human to
  // notice and manually hit retry.
  static const int _maxConnectAttempts = 5;
  static const Duration _connectAttemptInterval = Duration(seconds: 10);
  Timer? _connectWatchdog;
  int _connectAttemptCount = 0;

  HopsChatService({
    required this.myUsername,
    required this.peerUsername,
    this.onMessageReceived,
    this.onStateChanged,
    this.onProfileReceived,
    this.onRotatingSeedReceived,
  });

  bool get isConnected => _connected;

  Future<void> connect() async {
    _connectAttemptCount = 0;
    _setState(ChatConnectionState.connecting);

    // Nearby Connections competes with BLE peripheral advertising for
    // Bluetooth Classic radio time — same discipline hops_share_page.dart
    // already uses for this exact reason.
    await BlePeripheral.stopAdvertising();
    await Nearby().stopAllEndpoints();
    await _startAdvertisingAndDiscovery();
    _armConnectWatchdog();
  }

  // See _maxConnectAttempts' doc comment above for why this exists. Ticks
  // every _connectAttemptInterval while still unconnected: cycles
  // advertising/discovery (often enough on its own to recover from a
  // stalled BLE stack) and counts the attempt, until either a connection
  // succeeds (the timer cancels itself, see _onConnectionResult) or the
  // attempt budget runs out and this finally reports ChatConnectionState.failed.
  void _armConnectWatchdog() {
    _connectWatchdog?.cancel();
    _connectWatchdog = Timer.periodic(_connectAttemptInterval, (timer) async {
      if (_disposed || _connected) {
        timer.cancel();
        return;
      }
      _connectAttemptCount++;
      if (_connectAttemptCount >= _maxConnectAttempts) {
        timer.cancel();
        _setState(ChatConnectionState.failed);
        return;
      }
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
      await _startAdvertisingAndDiscovery();
    });
  }

  // Factored out of connect() so pauseForPing()/resumeAfterPing() (below)
  // can bring Nearby Connections back up the exact same way after
  // stepping aside for a CHT: ping, without duplicating this whole block.
  Future<void> _startAdvertisingAndDiscovery() async {
    await Nearby().startAdvertising(
      myUsername,
      // P2P_CLUSTER, not P2P_POINT_TO_POINT — the latter is documented by
      // Nearby Connections to opportunistically upgrade the link to Wi-Fi
      // Direct for extra bandwidth, which is what was silently flipping
      // the device's Wi-Fi radio on every time a chat opened. That's the
      // opposite of what an offline/BLE-mesh app should do, and text +
      // small avatar payloads don't need Wi-Fi-grade bandwidth anyway.
      // hops_share_page.dart already uses P2P_CLUSTER for the same reason.
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );

    await Nearby().startDiscovery(
      myUsername,
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,
      onEndpointFound: (id, name, foundServiceId) {
        if (_disposed || _connected || _connecting) return;
        if (name != peerUsername) return; // not the peer we're trying to reach
        _connecting = true;
        Nearby().requestConnection(
          myUsername,
          id,
          onConnectionInitiated: _onConnectionInitiated,
          onConnectionResult: _onConnectionResult,
          onDisconnected: _onDisconnected,
        );
      },
      onEndpointLost: (_) {},
    );
  }

  // Briefly steps out of Nearby Connections' own advertise/discover so a
  // short BLE-peripheral CHT: ping (see hops_app.dart) can safely use the
  // radio without the two fighting each other — the same contention
  // connect() already guards against at startup, just re-applied
  // mid-session. No-op once actually connected — nothing needs pinging
  // by that point, and tearing down a live connection to send a ping
  // would be a much worse trade.
  Future<void> pauseForPing() async {
    if (_connected) return;
    _connectWatchdog?.cancel();
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
  }

  // Pairs with pauseForPing() — brings Nearby Connections back up after
  // the ping's gone out. No-op if we've disposed or connected in the
  // meantime (a connection completing while the ping was in flight means
  // there's nothing left to resume).
  Future<void> resumeAfterPing() async {
    if (_disposed || _connected) return;
    await _startAdvertisingAndDiscovery();
    _armConnectWatchdog();
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    if (_disposed || _connected) return;
    if (info.endpointName != peerUsername) {
      // Some other Hops chat session nearby — not who we came for.
      Nearby().rejectConnection(id);
      return;
    }
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) => _onPayload(payload),
    );
  }

  void _onConnectionResult(String id, Status status) {
    _connecting = false;
    if (_disposed) return;
    if (status == Status.CONNECTED) {
      _endpointId = id;
      _connected = true;
      _connectWatchdog?.cancel();
      // Radio housekeeping — advertising/discovery are no longer needed
      // once the one connection P2P_POINT_TO_POINT allows is up.
      Nearby().stopAdvertising();
      Nearby().stopDiscovery();
      _setState(ChatConnectionState.connected);
    } else {
      // Don't immediately report failure on a single rejected/dropped
      // handshake — in a noisy RF environment a lone failed attempt is
      // common and not necessarily the end of the story. Advertising and
      // discovery are still running (nothing stopped them), so just leave
      // the watchdog above to keep retrying and only surface
      // ChatConnectionState.failed once its attempt budget is actually
      // exhausted.
    }
  }

  void _onDisconnected(String id) {
    if (id != _endpointId) return;
    _connected = false;
    _endpointId = null;
    if (!_disposed) _setState(ChatConnectionState.disconnected);
  }

  void _onPayload(Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null || payload.bytes!.isEmpty) {
      return;
    }
    final data = payload.bytes!;
    switch (data[0]) {
      case _payloadTypeChat:
        final rest = data.sublist(1);
        final nullIndex = rest.indexOf(0);
        if (nullIndex == -1) return;
        final message = utf8.decode(rest.sublist(nullIndex + 1), allowMalformed: true);
        onMessageReceived?.call(message);
        break;
      case _payloadTypeProfile:
        if (data.length < 2) return;
        final bioLen = data[1];
        if (data.length < 2 + bioLen) return;
        final bio = utf8.decode(data.sublist(2, 2 + bioLen), allowMalformed: true);
        final avatarBytes = data.length > 2 + bioLen
            ? Uint8List.fromList(data.sublist(2 + bioLen))
            : null;
        onProfileReceived?.call(bio, avatarBytes);
        break;
      case _payloadTypeRotatingSeed:
        final seed = data.sublist(1);
        if (seed.isEmpty) return;
        onRotatingSeedReceived?.call(Uint8List.fromList(seed));
        break;
      default:
        // Unknown/future payload type — ignore rather than misparse it.
        break;
    }
  }

  Future<bool> sendMessage(String text) async {
    if (!_connected || _endpointId == null) return false;
    final payload = Uint8List.fromList([
      _payloadTypeChat,
      ...utf8.encode(myUsername), 0,
      ...utf8.encode(text),
    ]);
    try {
      await Nearby().sendBytesPayload(_endpointId!, payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Sent automatically once a chat connects (see chat_terminal.dart) so
  // the peer's avatar/bio become available without either side having to
  // ask — the only way this app has for that data to travel between
  // devices at all, since nothing here is synced through a backend.
  Future<bool> sendProfile({required String bio, Uint8List? avatarBytes}) async {
    if (!_connected || _endpointId == null) return false;
    final bioBytesFull = utf8.encode(bio);
    // Length-prefixed with a single byte, so cap at 255 — plenty for a bio.
    final bioBytes = bioBytesFull.length > 255 ? bioBytesFull.sublist(0, 255) : bioBytesFull;
    final payload = Uint8List.fromList([
      _payloadTypeProfile,
      bioBytes.length,
      ...bioBytes,
      ...?avatarBytes,
    ]);
    try {
      await Nearby().sendBytesPayload(_endpointId!, payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Sent automatically once a chat connects, alongside sendProfile — see
  // chat_terminal.dart. [seed] is this device's own rotating_id_seed (from
  // secure storage), handed to the peer so their Radar can recognize this
  // device's beacon from now on. Small fixed-size payload, no
  // length-prefixing needed unlike the bio/avatar one.
  Future<bool> sendRotatingSeed(Uint8List seed) async {
    if (!_connected || _endpointId == null) return false;
    final payload = Uint8List.fromList([_payloadTypeRotatingSeed, ...seed]);
    try {
      await Nearby().sendBytesPayload(_endpointId!, payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectWatchdog?.cancel();
    final endpointId = _endpointId;
    _connected = false;
    _endpointId = null;
    if (endpointId != null) {
      await Nearby().disconnectFromEndpoint(endpointId);
    }
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    await Nearby().stopAllEndpoints();

    // Restore the passive Hops presence beacon so the radar/scan filter
    // sees this device again — mirrors hops_share_page.dart's dispose().
    try {
      await BlePeripheral.startAdvertising(
        localName: "HPS:$myUsername",
        services: [HOPS_SERVICE_UUID],
      );
    } catch (_) {
      // Best-effort — nothing useful to do if this fails here.
    }
  }

  void _setState(ChatConnectionState state) {
    if (!_disposed) onStateChanged?.call(state);
  }
}
