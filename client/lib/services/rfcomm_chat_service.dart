// lib/services/rfcomm_chat_service.dart
//
// Real 1:1 chat transport, built on classic Bluetooth RFCOMM sockets —
// replaces hops_chat_service.dart's nearby_connections-based transport,
// specifically because Nearby Connections' Android SDK opportunistically
// upgrades a connection to Wi-Fi-based mediums (Wi-Fi Direct/Hotspot)
// internally, regardless of which Strategy is chosen — confirmed by
// reading the nearby_connections plugin's own Dart source, which exposes
// Strategy (topology) but nothing that restricts *medium* selection, that
// being entirely up to Android's Nearby Connections implementation. RFCOMM
// sockets are genuinely Bluetooth-only; nothing here ever touches Wi-Fi.
import 'dart:async';
import 'dart:convert';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/services.dart';
import 'package:client/services/bluetooth_name_guard.dart';

enum ChatConnectionState { connecting, connected, disconnected, failed }

class RfcommChatService {
  final String myUsername;
  final String peerUsername;
  final void Function(String id, String message)? onMessageReceived;
  final void Function(String id)? onMessageDeleted;
  final void Function(ChatConnectionState state)? onStateChanged;
  final void Function(String bio, String thinking, Uint8List? avatarBytes)? onProfileReceived;
  final void Function(Uint8List seed)? onRotatingSeedReceived;
  final String? knownMacAddress;
  final void Function(String macAddress)? onMacLearned;

  static const _metaChannel = MethodChannel('com.example.client/rfcomm/meta');
  static const _discoveryEvents = EventChannel('com.example.client/bluetooth/discovery');

  // Single-line text-protocol prefixes.
  static const String _prefixChat = 'MSG:';
  static const String _prefixProfile = 'PRF:';
  static const String _prefixSeed = 'SED:';
  static const String _prefixDelete = 'DEL:';
  static const int _kMessageIdLength = 36;

  static const int _maxConnectAttempts = 5;
  static const Duration _discoveryTimeout = Duration(seconds: 20);
  // Sized so a full client cycle (known-MAC attempt + 20s discovery scan +
  // 12s RFCOMM socket connect) can complete without the periodic watchdog
  // tearing down an in-progress handshake.
  static const Duration _connectAttemptInterval = Duration(seconds: 38);
  static const Duration _discoverableWindow = Duration(seconds: 300);
  static const Duration _adapterNameSettleDelay = Duration(seconds: 3);
  static const Duration _socketConnectTimeout = Duration(seconds: 12);

  late final String _peerId;
  late final MethodChannel _peerChannel;
  StreamSubscription? _discoverySub;
  Timer? _connectWatchdog;
  int _connectAttemptCount = 0;
  bool _amHost = false;
  bool _connected = false;
  bool _disposed = false;
  bool _sessionOpen = false;
  bool _clientAttemptInFlight = false;
  bool _hostServerRunning = false;
  DateTime? _discoverableRequestedAt;
  String? _originalAdapterName;
  String? _cachedMacAddress;

  RfcommChatService({
    required this.myUsername,
    required this.peerUsername,
    this.onMessageReceived,
    this.onMessageDeleted,
    this.onStateChanged,
    this.onProfileReceived,
    this.onRotatingSeedReceived,
    this.knownMacAddress,
    this.onMacLearned,
  }) : _cachedMacAddress = knownMacAddress {
    _peerId = peerUsername.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  }

  bool get isConnected => _connected;

  Future<void> connect() async {
    _disposed = false;
    _connected = false;
    _connectAttemptCount = 0;
    _amHost = myUsername.compareTo(peerUsername) < 0;
    _setState(ChatConnectionState.connecting);

    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}

    _originalAdapterName ??= await BluetoothNameGuard.capture();

    await _openSession();
    await _renameAdapterToUsername();
    if (_cachedMacAddress == null) {
      await Future.delayed(_adapterNameSettleDelay);
    }

    if (_disposed || _connected) return;

    // Arm the watchdog BEFORE starting the role loop so that a hung first
    // attempt is still rescued by the timer.
    _armConnectWatchdog();

    if (_amHost) {
      await _runAsHost();
    } else {
      unawaited(_runAsClient());
    }
  }

  Future<void> _openSession() async {
    if (_sessionOpen) return;
    await _metaChannel.invokeMethod('openSession', {'peerId': _peerId});
    _peerChannel = MethodChannel('com.example.client/rfcomm/$_peerId');
    _peerChannel.setMethodCallHandler(_handlePeerChannelCall);
    _sessionOpen = true;
  }

  Future<void> _renameAdapterToUsername() async {
    if (_disposed) return;
    try {
      await _metaChannel.invokeMethod('setAdapterName', {'name': myUsername});
    } catch (_) {}
  }

  /// Re-applies this user's Hops username to the Bluetooth adapter after
  /// an external BLE broadcast (like a wake-up ping or mesh fallback
  /// message) temporarily renamed the adapter.
  Future<void> restoreRfcommAdapterName() async {
    if (_disposed || _connected) return;
    await _renameAdapterToUsername();
  }

  Future<void> _restoreAdapterName() => BluetoothNameGuard.restore();

  bool get _needsDiscoverablePrompt {
    if (_cachedMacAddress != null) return false;
    final last = _discoverableRequestedAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= _discoverableWindow;
  }

  // ── Host role ────────────────────────────────────────────────────────────

  Future<void> _runAsHost() async {
    if (_disposed || _connected) return;

    await _renameAdapterToUsername();

    if (_needsDiscoverablePrompt) {
      _discoverableRequestedAt = DateTime.now();
      try {
        await _metaChannel.invokeMethod(
          'ensureDiscoverable',
          {'seconds': _discoverableWindow.inSeconds},
        );
      } catch (_) {}
    }

    if (_disposed || _connected || _hostServerRunning) return;
    _hostServerRunning = true;

    unawaited(_peerChannel.invokeMethod('startServer').then((_) {
      _hostServerRunning = false;
      // Note: If MainActivity.kt resolves startServer only after accept()
      // succeeds, this marks the session connected. If MainActivity.kt
      // also pushes 'onConnected', the !_connected guard prevents double-firing.
      if (!_disposed && !_connected) _onConnected();
    }).catchError((_) {
      _hostServerRunning = false;
      // If the server socket closed unexpectedly while we're still trying
      // to connect, reopen a fresh session after a brief delay.
      if (!_disposed && !_connected && _amHost) {
        Future.delayed(const Duration(seconds: 2), () async {
          if (_disposed || _connected) return;
          try {
            await _peerChannel.invokeMethod('disconnect');
          } catch (_) {}
          _sessionOpen = false;
          await _openSession();
          await _runAsHost();
        });
      }
    }));
  }

  // ── Client role ──────────────────────────────────────────────────────────

  Future<bool> _tryConnectToMac(String mac) async {
    if (_disposed || _connected) return false;
    try {
      await _peerChannel
          .invokeMethod('connectToDevice', {'macAddress': mac})
          .timeout(_socketConnectTimeout);
      if (!_disposed && !_connected) {
        _cachedMacAddress = mac;
        onMacLearned?.call(mac);
        _onConnected();
      }
      return _connected;
    } catch (_) {
      // Unblock native pendingSocket if connectToDevice timed out or threw.
      try {
        await _peerChannel.invokeMethod('disconnect');
      } catch (_) {}
      return false;
    }
  }

  Future<void> _runAsClient() async {
    if (_disposed || _connected || _clientAttemptInFlight) return;
    _clientAttemptInFlight = true;

    try {
      await _renameAdapterToUsername();

      // 1. Try known MAC address on file first.
      final known = _cachedMacAddress;
      if (known != null) {
        if (await _tryConnectToMac(known)) return;
      }

      if (_disposed || _connected) return;

      // 2. Check already-bonded devices matching peerUsername.
      try {
        final bonded = await _metaChannel.invokeMethod<List<dynamic>>('getBondedDevices');
        for (final entry in bonded ?? const []) {
          if (_disposed || _connected) return;
          final map = (entry as Map).cast<String, dynamic>();
          if (map['name'] == peerUsername) {
            final mac = map['address'] as String?;
            if (mac == null) continue;
            if (await _tryConnectToMac(mac)) return;
          }
        }
      } catch (_) {}

      if (_disposed || _connected) return;

      // 3. Full classic-Bluetooth inquiry scan.
      final completer = Completer<String?>();
      await _discoverySub?.cancel();
      _discoverySub = _discoveryEvents.receiveBroadcastStream().listen((event) {
        final map = (event as Map).cast<String, dynamic>();
        if (map['name'] == peerUsername && !completer.isCompleted) {
          completer.complete(map['address'] as String?);
        }
      });

      try {
        await _metaChannel.invokeMethod('startDiscovery');
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }

      final address = await completer.future.timeout(
        _discoveryTimeout,
        onTimeout: () => null,
      );
      await _discoverySub?.cancel();
      _discoverySub = null;
      try {
        await _metaChannel.invokeMethod('stopDiscovery');
      } catch (_) {}

      if (address == null || _disposed || _connected) return;

      // Allow the Bluetooth radio a brief moment to exit inquiry mode
      // before opening an outgoing RFCOMM socket.
      await Future.delayed(const Duration(milliseconds: 500));
      if (_disposed || _connected) return;

      await _tryConnectToMac(address);
    } finally {
      _clientAttemptInFlight = false;
    }
  }

  void _onConnected() {
    _connected = true;
    _connectWatchdog?.cancel();
    _setState(ChatConnectionState.connected);
  }

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

      if (_amHost) {
        // Keep the host server socket open continuously; only re-assert the
        // adapter name and restart the server if it isn't currently running.
        await _renameAdapterToUsername();
        if (!_hostServerRunning) {
          try {
            await _peerChannel.invokeMethod('disconnect');
          } catch (_) {}
          _sessionOpen = false;
          await _openSession();
          await _runAsHost();
        }
      } else {
        // Client tears down any hung discovery/socket attempt and starts fresh.
        await _discoverySub?.cancel();
        _discoverySub = null;
        try {
          await _metaChannel.invokeMethod('stopDiscovery');
        } catch (_) {}
        try {
          await _peerChannel.invokeMethod('disconnect');
        } catch (_) {}
        _clientAttemptInFlight = false;
        _sessionOpen = false;
        await _openSession();
        unawaited(_runAsClient());
      }
    });
  }

  // ── Incoming push calls from the native side ────────────────────────────

  Future<void> _handlePeerChannelCall(MethodCall call) async {
    switch (call.method) {
      case 'onMessageReceived':
        _handleLine(call.arguments as String);
        break;
      case 'onConnected':
        final mac = call.arguments as String?;
        if (mac != null) {
          _cachedMacAddress = mac;
          onMacLearned?.call(mac);
        }
        if (!_disposed && !_connected) _onConnected();
        break;
      case 'onConnectionLost':
        _hostServerRunning = false;
        if (_connected) {
          _connected = false;
          if (!_disposed) _setState(ChatConnectionState.disconnected);
        }
        break;
    }
  }

  void _handleLine(String line) {
    try {
      if (line.startsWith(_prefixChat)) {
        final bytes = base64Decode(line.substring(_prefixChat.length));
        final decoded = utf8.decode(bytes, allowMalformed: true);
        if (decoded.length < _kMessageIdLength) return;
        final id = decoded.substring(0, _kMessageIdLength);
        final text = decoded.substring(_kMessageIdLength);
        onMessageReceived?.call(id, text);
      } else if (line.startsWith(_prefixDelete)) {
        final id = line.substring(_prefixDelete.length);
        if (id.isNotEmpty) onMessageDeleted?.call(id);
      } else if (line.startsWith(_prefixProfile)) {
        final bytes = base64Decode(line.substring(_prefixProfile.length));
        if (bytes.isEmpty) return;
        final bioLen = bytes[0];
        if (bytes.length < 1 + bioLen + 1) return;
        final bio = utf8.decode(bytes.sublist(1, 1 + bioLen), allowMalformed: true);
        final thinkingLenIndex = 1 + bioLen;
        final thinkingLen = bytes[thinkingLenIndex];
        final thinkingStart = thinkingLenIndex + 1;
        if (bytes.length < thinkingStart + thinkingLen) return;
        final thinking = utf8.decode(
            bytes.sublist(thinkingStart, thinkingStart + thinkingLen),
            allowMalformed: true);
        final avatarStart = thinkingStart + thinkingLen;
        final avatarBytes = bytes.length > avatarStart
            ? Uint8List.fromList(bytes.sublist(avatarStart))
            : null;
        onProfileReceived?.call(bio, thinking, avatarBytes);
      } else if (line.startsWith(_prefixSeed)) {
        final bytes = base64Decode(line.substring(_prefixSeed.length));
        if (bytes.isEmpty) return;
        onRotatingSeedReceived?.call(Uint8List.fromList(bytes));
      }
    } catch (_) {}
  }

  // ── Sending ──────────────────────────────────────────────────────────────

  Future<bool> _sendLine(String line) async {
    if (!_connected) return false;
    try {
      await _peerChannel.invokeMethod('sendMessage', {'message': line});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> sendMessage(String id, String text) {
    final safe = text.replaceAll('\n', ' ').replaceAll('\r', ' ');
    return _sendLine(_prefixChat + base64Encode(utf8.encode(id + safe)));
  }

  Future<bool> sendDeleteMessage(String id) => _sendLine(_prefixDelete + id);

  Future<bool> sendProfile({
    required String bio,
    required String thinking,
    Uint8List? avatarBytes,
  }) {
    final bioBytesFull = utf8.encode(bio);
    final bioBytes =
    bioBytesFull.length > 255 ? bioBytesFull.sublist(0, 255) : bioBytesFull;
    final thinkingBytesFull = utf8.encode(thinking);
    final thinkingBytes = thinkingBytesFull.length > 255
        ? thinkingBytesFull.sublist(0, 255)
        : thinkingBytesFull;
    final payload = Uint8List.fromList([
      bioBytes.length,
      ...bioBytes,
      thinkingBytes.length,
      ...thinkingBytes,
      ...?avatarBytes,
    ]);
    return _sendLine(_prefixProfile + base64Encode(payload));
  }

  Future<bool> sendRotatingSeed(Uint8List seed) {
    return _sendLine(_prefixSeed + base64Encode(seed));
  }

  // ── Ping pause/resume ────────────────────────────────────────────────────

  Future<void> pauseForPing() async {
    if (_connected) return;
    _connectWatchdog?.cancel();
    await _discoverySub?.cancel();
    _discoverySub = null;
    try {
      await _metaChannel.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  Future<void> resumeAfterPing() async {
    if (_disposed || _connected) return;
    // The BLE CHT: ping overwrote the adapter name with the ping payload
    // and then restored the phone's default name — set it back to
    // myUsername so RFCOMM discovery can find us.
    await _renameAdapterToUsername();
    await Future.delayed(const Duration(milliseconds: 500));
    if (_disposed || _connected) return;

    if (_amHost) {
      if (!_hostServerRunning) {
        await _runAsHost();
      }
    } else {
      unawaited(_runAsClient());
    }
    _armConnectWatchdog();
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectWatchdog?.cancel();
    await _discoverySub?.cancel();
    _discoverySub = null;
    _connected = false;
    _hostServerRunning = false;
    _clientAttemptInFlight = false;
    try {
      await _metaChannel.invokeMethod('stopDiscovery');
    } catch (_) {}
    if (_sessionOpen) {
      try {
        await _metaChannel.invokeMethod('closeSession', {'peerId': _peerId});
      } catch (_) {}
      _sessionOpen = false;
    }
    await _restoreAdapterName();
  }

  void _setState(ChatConnectionState state) {
    if (!_disposed) onStateChanged?.call(state);
  }
}