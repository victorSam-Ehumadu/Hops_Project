import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/views/hops_app.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/foreground_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

final ValueNotifier<int> themeNotifier = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'Hops Service',
      channelDescription: 'Keeps BLE scanning active for emergency alerts',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      autoRunOnBoot: true,
      allowWakeLock: true,
    ),
  );

  await FlutterForegroundTask.startService(
    notificationTitle: 'Hops is active',
    notificationText: 'Scanning for emergency flares…',
  );

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
  final themeIndex = prefs.getInt('selected_theme_index') ?? 0;
  themeNotifier.value = themeIndex;

  runApp(const HopsRoot());
}

class HopsRoot extends StatefulWidget {
  const HopsRoot({super.key});
  @override
  State<HopsRoot> createState() => _HopsRootState();
}

class _HopsRootState extends State<HopsRoot> {
  late int _themeIndex;

  @override
  void initState() {
    super.initState();
    _themeIndex = themeNotifier.value;
    themeNotifier.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    themeNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (_themeIndex != themeNotifier.value) {
      setState(() {
        _themeIndex = themeNotifier.value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppThemes.all[_themeIndex];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.toThemeData(),
      home: _getHomeWidget(),
      builder: (context, child) {
        final mediaQueryData = MediaQuery.of(context);
        final constrainedTextScale = mediaQueryData.textScaleFactor.clamp(1.0, 1.2);
        return MediaQuery(
          data: mediaQueryData.copyWith(textScaleFactor: constrainedTextScale),
          child: child!,
        );
      },
    );
  }

  Widget _getHomeWidget() {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final savedToken = snapshot.data!.getString('saved_hops_token');
        if (savedToken != null) {
          return const HopsApp();
        } else {
          return const HopsRootGatekeeper();
        }
      },
    );
  }
}