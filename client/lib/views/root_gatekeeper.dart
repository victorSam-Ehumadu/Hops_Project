import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypton/crypton.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:client/views/auth_screen.dart';
import 'package:client/views/hops_app.dart';
import 'package:client/theme/hops_theme.dart';
import 'dart:convert';

class HopsRootGatekeeper extends StatefulWidget {
  const HopsRootGatekeeper({super.key});

  @override
  State<HopsRootGatekeeper> createState() => _HopsRootGatekeeperState();
}

class _HopsRootGatekeeperState extends State<HopsRootGatekeeper> {
  String authEngineStatus = "System Ready";
  final _secureStorage = const FlutterSecureStorage();

  Future<bool> _requestMeshPermissionsGate() async {
    setState(() => authEngineStatus = "Awaiting System Permissions...");

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.camera,
    ].request();

    if (statuses[Permission.location]!.isGranted && statuses[Permission.bluetoothScan]!.isGranted) {
      return true;
    } else {
      setState(() => authEngineStatus = "Err: Permissions Denied");
      return false;
    }
  }

  Map<String, String> _generateLocalMeshKeys() {
    RSAKeypair keypair = RSAKeypair.fromRandom();
    return {'public': keypair.publicKey.toString(), 'private': keypair.privateKey.toString()};
  }

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> handleMeshSignUp({required String email, required String password, required String username}) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Generating Crypto Keys...");
      final meshKeys = _generateLocalMeshKeys();

      setState(() => authEngineStatus = "Registering Identity...");
      String trueDatabaseUuid = const Uuid().v4();
      String rollingToken = const Uuid().v4();
      final passwordHash = _hashPassword(password);

      await _secureStorage.write(key: 'private_key', value: meshKeys['private']);

      await Supabase.instance.client.from('profiles').insert({
        'id': trueDatabaseUuid,
        'username': username,
        'public_key': meshKeys['public'],
        'password_hash': passwordHash,
        'hops_token': rollingToken,
        'token_expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      });

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);
      await prefs.setString('my_hops_id', trueDatabaseUuid);
      await prefs.setString('my_username', username);

      setState(() => authEngineStatus = "Registration Complete!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome to the Mesh, $username!");
      }
    } catch (e) {
      print("❌ SIGNUP EXCEPTION: $e");
      setState(() => authEngineStatus = "Err: Signup Refused");
    }
  }

  Future<void> handleMeshSignIn({required String email, required String password}) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Verifying Credentials...");
      final String targetedUsername = email.contains('@') ? email.split('@').first : email;

      final response = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('username', targetedUsername)
          .maybeSingle();

      if (response == null) {
        setState(() => authEngineStatus = "Err: User Profile Not Found");
        return;
      }

      final storedHash = response['password_hash'] as String? ?? '';
      if (storedHash.isEmpty || _hashPassword(password) != storedHash) {
        setState(() => authEngineStatus = "Err: Invalid Password");
        return;
      }

      String rollingToken = const Uuid().v4();
      await Supabase.instance.client.from('profiles').update({
        'hops_token': rollingToken,
        'token_expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      }).eq('id', response['id']);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);
      await prefs.setString('my_hops_id', response['id']);
      await prefs.setString('my_username', response['username']);

      String? privateKey = await _secureStorage.read(key: 'private_key');
      if (privateKey == null) {
        final keys = _generateLocalMeshKeys();
        await _secureStorage.write(key: 'private_key', value: keys['private']);
      }

      setState(() => authEngineStatus = "Session Secured!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome back, ${response['username']}!");
      }
    } catch (e) {
      setState(() => authEngineStatus = "Err: Authentication Aborted");
    }
  }

  void _showSuccessConfirmationDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: HopsTheme.tertiaryContainer),
            SizedBox(width: 8),
            Text("Success", style: TextStyle(color: HopsTheme.primary, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(color: HopsTheme.onBackground)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (context) => const HopsApp()));
            },
            child: const Text("Enter Dashboard", style: TextStyle(color: HopsTheme.primary, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreen(
      currentStatus: authEngineStatus,
      onSignUpTrigger: handleMeshSignUp,
      onSignInTrigger: handleMeshSignIn,
    );
  }
}