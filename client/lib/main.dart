import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/hops_theme.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/views/hops_app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? savedToken = prefs.getString('saved_hops_token');

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HopsTheme.lightTheme,
    home: savedToken != null ? const HopsApp() : const HopsRootGatekeeper(),
    builder: (context, child) {
      // Limit text scale to avoid overflow
      final mediaQueryData = MediaQuery.of(context);
      final constrainedTextScale = mediaQueryData.textScaleFactor.clamp(1.0, 1.2);
      return MediaQuery(
        data: mediaQueryData.copyWith(textScaleFactor: constrainedTextScale),
        child: child!,
      );
    },
  ));
}