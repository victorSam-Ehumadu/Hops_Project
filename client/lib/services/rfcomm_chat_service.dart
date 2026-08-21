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
//
// The native half of this (MainActivity.kt's openSession/closeSession +
// per-peer MethodChannel, RfcommChatService.kt's actual socket handling)
// was already fully built and was simply never reachable from Dart before
// this file. What WAS still missing, and is new here:
//
//   1. A Hops username has no Bluetooth MAC address on file anywhere — two
//      devices that have never bonded need classic Bluetooth discovery to
//      find each other's MAC, which means matching on the discoverable
//      device *name*. So both sides temporarily rename their classic
//      Bluetooth adapter to their own Hops username for the duration of
//      the chat (mirrors hops_app.dart's existing
//      _captureOriginalBluetoothName/_advertiseWithName pattern of
//      restoring the original name afterward — reuses the exact same
//      getAdapterName/setAdapterName meta-channel calls).
//   2. For the SCANNED-for side to actually show up in the other device's
//      discovery results, it has to be "discoverable" — Android requires
//      an explicit user-facing system dialog for that (there is no way to
//      silently grant it, unlike ordinary BLE scan/advertise permissions)
//      — see MainActivity.kt's ensureDiscoverable.
//   3. A role split, so both sides don't try to do the same thing: whoever
//      username sorts first (plain string comparison) hosts — calls
//      startServer() and waits, discoverable — the other discovers +
//      connects to them. Deterministic and symmetric without either side
//      needing to negotiate first.
//   4. RfcommChatService.kt's socket is a line-oriented text stream
//      (PrintWriter.println / BufferedReader.readLine), not
//      nearby_connections' arbitrary byte payloads — so profile/rotating-
//      seed binary data (which HopsChatService multiplexed as raw bytes)
//      is base64-encoded onto its own single line here instead, keeping
//      the multiplexing-by-type-prefix idea but adapted to a text
//      protocol. Outgoing chat text has any embedded newline stripped for
//      the same reason — a literal \n would corrupt the line framing.
//
// NOT yet validated against real hardware (no device available while
// writing this) — the two likeliest failure points if something's still
// off are (2) above (the discoverable-dialog duration/timing) and classic
// discovery's own reliability, which — like BLE scanning — varies by
// Android OEM/chipset. See the watchdog retry loop below, mirroring
// hops_chat_service.dart's own retry shape for the exact same reason that
// one has it: a single lost discovery/connect attempt shouldn't strand the
// chat on "Connecting…" forever with nothing automatically trying again.
import 'dart:async';
import 'dart:convert';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/services.dart';

enum ChatConnectionState { connecting, connected, disconnected, failed }

class RfcommChatService {
  final String myUsername;
  final String peerUsername;
  // [id] is the same id the sender's own row was stored under (see
  // sendMessage) — carrying it across the wire, rather than each side
  // minting its own uuid for "the same" message, is what makes
  // onMessageDeleted below able to remove the right row on this end too.
  final void Function(String id, String message)? onMessageReceived;
  // The peer deleted one of *their* messages (i.e. one of ours, from this
  // side's perspective) and it was still connected long enough to tell us
  // — see sendDeleteMessage. Best-effort only: if we're not connected when
  // they delete, this never arrives and our copy just stays put, same as
  // any other message sent while disconnected.
  final void Function(String id)? onMessageDeleted;
  final void Function(ChatConnectionState state)? onStateChanged;
  final void Function(String bio, String thinking, Uint8List? avatarBytes)? onProfileReceived;
  final void Function(Uint8List seed)? onRotatingSeedReceived;
  // A MAC address this device already has on file for this peer from a
  // prior successful RFCOMM connection (see chat_terminal.dart, which
  // reads/writes this via DatabaseHelper's contact_profiles table) — lets
  // both roles skip the slow/intrusive parts of first-time pairing:
  // the client tries connecting to it directly before falling back to full
  // discovery, and the host skips requesting discoverability altogether
  // (a direct connect-by-MAC needs the target listening, not discoverable
  // — see this file's header comment). Null for a contact never
  // successfully RFCOMM-chatted with before.
  final String? knownMacAddress;
  // Fired once this device learns (or reconfirms) the peer's MAC address —
  // client learns it immediately (it's the address it just dialed), host
  // learns it from the native onConnected push (RfcommChatService.kt now
  // reports the accepted socket's remote address). The caller is expected
  // to persist this for next time.
  final void Function(String macAddress)? onMacLearned;

  static const _metaChannel = MethodChannel('com.example.client/rfcomm/meta');
  static const _discoveryEvents = EventChannel('com.example.client/bluetooth/discovery');

  // Single-line text-protocol prefixes — see this file's header comment.
  static const String _prefixChat = 'MSG:';
  static const String _prefixProfile = 'PRF:';
  static const String _prefixSeed = 'SED:';
  static const String _prefixDelete = 'DEL:';
  // uuid v4's canonical string form is always exactly 36 characters
  // (8-4-4-4-12 hex, hyphens included) — used below to split a decoded
  // MSG: payload back into its id and text without needing a delimiter
  // that outgoing text would then have to avoid.
  static const int _kMessageIdLength = 36;

  static const int _maxConnectAttempts = 5;
  // Android's classic-Bluetooth inquiry scan runs for roughly 12 seconds
  // per cycle and reports most devices only toward the end of it. The
  // first version of this used a 12s attempt interval with a 10s discovery
  // timeout inside it — i.e. it gave up and restarted *before a single
  // inquiry cycle had ever finished*, so the peer could easily never be
  // reported at all. Both windows are now comfortably longer than one
  // full inquiry.
  static const Duration _discoveryTimeout = Duration(seconds: 20);
  static const Duration _connectAttemptInterval = Duration(seconds: 25);
  static const Duration _discoverableWindow = Duration(seconds: 300);

  // BluetoothAdapter.setName() is asynchronous inside the Android
  // Bluetooth stack — the new name is not immediately what remote devices
  // see during an inquiry. Renaming and then instantly starting discovery
  // meant the peer could scan us while we were still broadcasting our old
  // (non-username) adapter name, so their name-match never fired. Waiting
  // out a short settle window before either side starts looking closes
  // that race.
  static const Duration _adapterNameSettleDelay = Duration(seconds: 3);

  late final String _peerId; // sanitized peerUsername — channel name + native map key
  late final MethodChannel _peerChannel;
  StreamSubscription? _discoverySub;
  Timer? _connectWatchdog;
  int _connectAttemptCount = 0;
  bool _amHost = false;
  bool _connected = false;
  bool _disposed = false;
  bool _sessionOpen = false;
  String? _originalAdapterName;

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
  }) {
    _peerId = peerUsername.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  }

  bool get isConnected => _connected;

  Future<void> connect() async {
    _connectAttemptCount = 0;
    _amHost = myUsername.compareTo(peerUsername) < 0;
    _setState(ChatConnectionState.connecting);

    // Classic-BT discovery/inquiry and BLE peripheral advertising are
    // different radio personas but share the same physical chip — same
    // discipline hops_chat_service.dart used to use for nearby_connections,
    // cheap insurance against contention on lower-end radios even though
    // RFCOMM's overlap with BLE peripheral mode is less direct than
    // nearby_connections' was.
    try {
      await BlePeripheral.stopAdvertising();
    } catch (_) {}

    try {
      _originalAdapterName ??= await _metaChannel.invokeMethod<String>('getAdapterName');
    } catch (_) {
      // Best-effort — if we can't read/restore it later, worst case the
      // adapter is left showing this device's Hops username, which isn't
      // harmful, just not restored to whatever it said before.
    }

    await _openSession();
    await _renameAdapterToUsername();
    // See _adapterNameSettleDelay — skipped when we already know the
    // peer's MAC, since that path never depends on name-based discovery.
    if (knownMacAddress == null) {
      await Future.delayed(_adapterNameSettleDelay);
    }

    if (_amHost) {
      await _runAsHost();
    } else {
      await _runAsClient();
    }
    _armConnectWatchdog();
  }

  Future<void> _openSession() async {
    if (_sessionOpen) return;
    await _metaChannel.invokeMethod('openSession', {'peerId': _peerId});
    _peerChannel = MethodChannel('com.example.client/rfcomm/$_peerId');
    _peerChannel.setMethodCallHandler(_handlePeerChannelCall);
    _sessionOpen = true;
  }

  Future<void> _renameAdapterToUsername() async {
    try {
      await _metaChannel.invokeMethod('setAdapterName', {'name': myUsername});
    } catch (_) {
      // Best-effort — if this fails, discovery-by-name just won't resolve
      // us on the peer's side; the watchdog will keep retrying regardless.
    }
  }

  Future<void> _restoreAdapterName() async {
    final original = _originalAdapterName;
    if (original == null || original.isEmpty) return;
    try {
      await _metaChannel.invokeMethod('setAdapterName', {'name': original});
    } catch (_) {}
  }

  // ── Host role ────────────────────────────────────────────────────────────

  Future<void> _runAsHost() async {
    if (knownMacAddress == null) {
      // No record of ever having connected to this peer before — assume
      // this might be a first-time pairing and request discoverability so
      // the client's discovery scan can actually find us. If we DO have a
      // MAC on file, skip this entirely: the client will try a direct
      // connect-by-MAC first, which needs us listening (startServer,
      // below), not discoverable.
      try {
        await _metaChannel.invokeMethod('ensureDiscoverable', {'seconds': _discoverableWindow.inSeconds});
      } catch (_) {
        // Denied or unavailable — startServer() below still runs; a peer
        // with our MAC already on file can still connect without this.
      }
    }
    // Deliberately not awaited — startServer() blocks natively until a
    // client actually connects (or the socket is closed out from under
    // it), which can be a long wait. Not awaiting here lets connect()
    // return promptly; _handlePeerChannelCall/_armConnectWatchdog handle
    // the eventual result either way.
    unawaited(_peerChannel.invokeMethod('startServer').then((_) {
      // Only reachable once a client actually connected — onConnectionResult
      // isn't separately pushed for the host side in the native
      // implementation, so a successful return from startServer IS the
      // connected signal.
      if (!_disposed && !_connected) _onConnected();
    }).catchError((_) {
      // Expected on a deliberate cancel (the watchdog closing the socket
      // to retry) as well as a genuine failure — either way, the watchdog
      // is what decides whether to retry or give up, not this.
    }));
  }

  // ── Client role ──────────────────────────────────────────────────────────

  Future<void> _runAsClient() async {
    // Try a direct connect to whatever MAC we already have on file first —
    // no discovery, no dialog on either side needed if this succeeds. Only
    // falls through to full discovery below if it fails (peer's MAC
    // changed — a factory reset, a different device — or this is the
    // first-ever attempt with a stale/bad cached value).
    final known = knownMacAddress;
    if (known != null) {
      try {
        await _peerChannel.invokeMethod('connectToDevice', {'macAddress': known});
        if (!_disposed && !_connected) {
          onMacLearned?.call(known);
          _onConnected();
        }
        if (_connected) return;
      } catch (_) {
        // Fall through to discovery below.
      }
    }

    // Already-bonded devices are known to the adapter without any inquiry
    // at all — check them before paying the ~12s cost of a discovery scan.
    // Two phones that have chatted before are usually bonded from that
    // first RFCOMM connection, so this is the common path on every chat
    // after the first, and it's near-instant.
    try {
      final bonded = await _metaChannel.invokeMethod<List<dynamic>>('getBondedDevices');
      for (final entry in bonded ?? const []) {
        final map = (entry as Map).cast<String, dynamic>();
        if (map['name'] == peerUsername) {
          final mac = map['address'] as String?;
          if (mac == null) continue;
          try {
            await _peerChannel.invokeMethod('connectToDevice', {'macAddress': mac});
            if (!_disposed && !_connected) {
              onMacLearned?.call(mac);
              _onConnected();
            }
            if (_connected) return;
          } catch (_) {
            // Bonded but not currently reachable/listening — fall through
            // to a full discovery scan below.
          }
        }
      }
    } catch (_) {
      // Permission denied or adapter unavailable — discovery below will
      // fail the same way and the watchdog handles it.
    }

    if (_disposed || _connected) return;

    final completer = Completer<String?>(); // resolves to the peer's MAC address
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

    try {
      await _peerChannel.invokeMethod('connectToDevice', {'macAddress': address});
      if (!_disposed && !_connected) {
        onMacLearned?.call(address);
        _onConnected();
      }
    } catch (_) {
      // Left to the watchdog to retry.
    }
  }

  void _onConnected() {
    _connected = true;
    _connectWatchdog?.cancel();
    _setState(ChatConnectionState.connected);
  }

  // See hops_chat_service.dart's identical watchdog for why this exists —
  // a single lost discovery broadcast or connection attempt in a noisy RF
  // environment shouldn't leave the chat stuck on "Connecting…" forever.
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
      // Both roles tear down and re-open a fresh native session before
      // retrying — this used to only happen for the host. The client
      // branch just called _runAsClient() again on the SAME instance,
      // which was the actual bug behind "stuck on Connecting… forever,
      // only on some phones": BluetoothSocket.connect() is a blocking
      // native call with no built-in timeout, and on some OEM Bluetooth
      // stacks it can hang indefinitely instead of ever throwing. With no
      // teardown, a hung attempt just sat there forever while every
      // subsequent retry piled a NEW concurrent connect attempt on top of
      // it instead of replacing it. disconnect() now actually closes the
      // in-flight socket to unblock a hung connect() (see
      // RfcommChatService.kt's pendingSocket) — but that only works if the
      // retry actually calls it, which the client branch never did.
      try {
        await _peerChannel.invokeMethod('disconnect');
      } catch (_) {}
      _sessionOpen = false;
      await _openSession();
      if (_amHost) {
        await _runAsHost();
      } else {
        await _runAsClient();
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
        // Host-side only signal (see RfcommChatService.kt's onSocketReady)
        // — the client already knows its own dialed address and reports
        // it itself in _runAsClient. Reported regardless of whether we
        // already had a MAC on file, so a stale cached value gets
        // refreshed too.
        final mac = call.arguments as String?;
        if (mac != null) onMacLearned?.call(mac);
        if (!_disposed && !_connected) _onConnected();
        break;
      case 'onConnectionLost':
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
        if (decoded.length < _kMessageIdLength) return; // malformed — no id to key it by
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
        if (bytes.length < 1 + bioLen + 1) return; // +1 for the thinkingLen byte that follows
        final bio = utf8.decode(bytes.sublist(1, 1 + bioLen), allowMalformed: true);
        final thinkingLenIndex = 1 + bioLen;
        final thinkingLen = bytes[thinkingLenIndex];
        final thinkingStart = thinkingLenIndex + 1;
        if (bytes.length < thinkingStart + thinkingLen) return;
        final thinking = utf8.decode(bytes.sublist(thinkingStart, thinkingStart + thinkingLen), allowMalformed: true);
        final avatarStart = thinkingStart + thinkingLen;
        final avatarBytes = bytes.length > avatarStart ? Uint8List.fromList(bytes.sublist(avatarStart)) : null;
        onProfileReceived?.call(bio, thinking, avatarBytes);
      } else if (line.startsWith(_prefixSeed)) {
        final bytes = base64Decode(line.substring(_prefixSeed.length));
        if (bytes.isEmpty) return;
        onRotatingSeedReceived?.call(Uint8List.fromList(bytes));
      }
      // Unknown prefix (future payload type) — ignore rather than misparse.
    } catch (_) {
      // Malformed line — drop it rather than crash the chat over one bad packet.
    }
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

  // [id] is the row id the caller already stored its own outgoing copy
  // under — sent alongside the text (not separately) so a single MSG: line
  // still carries everything needed, and so the two ends' copies of "the
  // same" message share one id from the moment it's first sent, which is
  // what lets a later sendDeleteMessage(id) reach the right row on both
  // sides instead of just the sender's.
  Future<bool> sendMessage(String id, String text) {
    // Strip embedded newlines — a literal \n would corrupt the native
    // side's readLine()-based framing (see this file's header comment).
    // Chat input is single-line anyway (chat_terminal.dart's TextField),
    // so this only ever matters for pasted multi-line text.
    final safe = text.replaceAll('\n', ' ').replaceAll('\r', ' ');
    return _sendLine(_prefixChat + base64Encode(utf8.encode(id + safe)));
  }

  // "Delete for everyone" — best-effort, live-connection-only (see
  // onMessageDeleted's comment above). [id] must be an id the peer also
  // has on file for this message, i.e. one that was actually sent via
  // sendMessage above rather than written locally some other way.
  Future<bool> sendDeleteMessage(String id) => _sendLine(_prefixDelete + id);

  Future<bool> sendProfile({required String bio, required String thinking, Uint8List? avatarBytes}) {
    final bioBytesFull = utf8.encode(bio);
    final bioBytes = bioBytesFull.length > 255 ? bioBytesFull.sublist(0, 255) : bioBytesFull;
    final thinkingBytesFull = utf8.encode(thinking);
    final thinkingBytes = thinkingBytesFull.length > 255 ? thinkingBytesFull.sublist(0, 255) : thinkingBytesFull;
    final payload = Uint8List.fromList([
      bioBytes.length, ...bioBytes,
      thinkingBytes.length, ...thinkingBytes,
      ...?avatarBytes,
    ]);
    return _sendLine(_prefixProfile + base64Encode(payload));
  }

  Future<bool> sendRotatingSeed(Uint8List seed) {
    return _sendLine(_prefixSeed + base64Encode(seed));
  }

  // ── Ping pause/resume (mirrors HopsChatService's — chat_terminal.dart
  // calls these while not yet connected, to let a BLE CHT: ping borrow the
  // radio briefly without RFCOMM's own discovery/advertise fighting it) ──

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
    if (_amHost) {
      await _runAsHost();
    } else {
      await _runAsClient();
    }
    _armConnectWatchdog();
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectWatchdog?.cancel();
    await _discoverySub?.cancel();
    _connected = false;
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
