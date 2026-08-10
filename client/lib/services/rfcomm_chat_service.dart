// lib/services/rfcomm_chat_service.dart
import 'package:flutter/services.dart';

class RfcommChatService {
  final MethodChannel _channel;

  final void Function(String message)? onMessageReceived;
  final VoidCallback? onConnectionLost;

  RfcommChatService({
    required String peerId,
    this.onMessageReceived,
    this.onConnectionLost,
  }) : _channel = MethodChannel('com.example.client/rfcomm/$peerId') {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onMessageReceived':
          onMessageReceived?.call(call.arguments.toString());
          break;
        case 'onConnectionLost':
          onConnectionLost?.call();
          break;
      }
      return null;
    });
  }

  Future<bool> startServer() async {
    try {
      await _channel.invokeMethod('startServer');
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> connectToDevice(String macAddress) async {
    try {
      await _channel.invokeMethod('connectToDevice', {'macAddress': macAddress});
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      final result = await _channel.invokeMethod<bool>('sendMessage', {'message': message});
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (_) {}
  }
}