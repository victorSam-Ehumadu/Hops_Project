import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:nearby_connections/nearby_connections.dart';

class ChatConnectionService {
  final String myUsername;
  String? _endpointId;
  bool _connected = false;
  Function(String sender, String message)? onMessageReceived;

  ChatConnectionService({required this.myUsername});

  bool get isConnected => _connected;

  Future<String?> connectToFriend(String friendUsername) async {
    final completer = Completer<String?>();

    // 1. Clean any previous Nearby sessions
    Nearby().stopAllEndpoints();
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();

    // 2. Start discovery to find the friend
    Nearby().startDiscovery(
      myUsername,
      Strategy.P2P_CLUSTER,
      onEndpointFound: (id, name, serviceId) {
        if (name == friendUsername && !_connected) {
          Nearby().requestConnection(
            myUsername,
            id,
            onConnectionInitiated: (connId, info) {
              Nearby().acceptConnection(connId, onPayLoadRecieved: (eId, payload) {
                if (payload.type == PayloadType.BYTES) {
                  _handlePayload(payload.bytes!);
                }
              });
              _endpointId = connId;
              _connected = true;
              if (!completer.isCompleted) completer.complete(connId);
            },
            onConnectionResult: (connId, status) {
              if (status == Status.CONNECTED) {
                _endpointId = connId;
                _connected = true;
                if (!completer.isCompleted) completer.complete(connId);
              }
            },
            onDisconnected: (id) {
              if (id == _endpointId) {
                _connected = false;
                _endpointId = null;
              }
            },
          );
        }
      },
      onEndpointLost: (id) {},
    );

    // 3. Timeout after 20 seconds
    Future.delayed(const Duration(seconds: 20), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        Nearby().stopDiscovery();
      }
    });

    return completer.future;
  }

  void _handlePayload(Uint8List data) {
    final prefix = utf8.decode(data.sublist(0, 5));
    if (prefix == "CHAT:") {
      final rest = data.sublist(5);
      final nullIndex = rest.indexOf(0);
      if (nullIndex == -1) return;
      final sender = utf8.decode(rest.sublist(0, nullIndex));
      final message = utf8.decode(rest.sublist(nullIndex + 1));
      onMessageReceived?.call(sender, message);
    }
  }

  Future<void> sendMessage(String text) async {
    if (!_connected || _endpointId == null) return;
    final payload = Uint8List.fromList([
      ...utf8.encode("CHAT:"),
      ...utf8.encode(myUsername),
      0,
      ...utf8.encode(text),
    ]);
    Nearby().sendBytesPayload(_endpointId!, payload);
  }

  void disconnect() {
    if (_endpointId != null) {
      Nearby().disconnectFromEndpoint(_endpointId!);
    }
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    _connected = false;
    _endpointId = null;
  }
}