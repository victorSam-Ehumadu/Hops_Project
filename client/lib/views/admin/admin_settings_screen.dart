// lib/views/admin/admin_settings_screen.dart
//
// Settings for the admin app. Reached from the Dashboard's app bar rather
// than the nav bar — settings are visited rarely and shouldn't cost one of
// five nav slots.
//
// Deliberately not a copy of the student app's settings: an admin device is
// a shift tool, so this covers the things that actually go wrong on one —
// which account is signed in, whether the alarm can reach you, whether the
// Bluetooth listener is alive, and getting out of a session cleanly.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/main.dart' show themeNotifier, fontScaleNotifier;
import 'package:client/theme/app_theme.dart';
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/views/admin/admin_shell.dart' show signOutOfAdminApp;

/// Remembers which theme was chosen at each brightness, so flipping dark
/// mode off and back on returns you to the theme you picked rather than
/// resetting to the default every time.
const String _kLastLightThemeKey = 'last_light_theme_index';
const String _kLastDarkThemeKey = 'last_dark_theme_index';

class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen>
    with WidgetsBindingObserver {
  String? _username;
  String? _email;
  String? _adminTitle;
  bool _notificationsAllowed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The permission rows are the reason this screen watches the lifecycle.
  /// Both "Fix" and "Re-check" send the user to the system settings app,
  /// and the old code re-read the permission the instant after launching
  /// it — before the user had even seen the toggle, let alone changed it.
  /// So the row always came back saying exactly what it said before, and
  /// the buttons looked broken. Re-reading on resume is what actually
  /// answers "did they change it".
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = await Permission.notification.isGranted;
    if (!mounted) return;
    setState(() {
      _username = prefs.getString('my_username');
      _email = prefs.getString('my_email');
      _adminTitle = prefs.getString('my_admin_title');
      _notificationsAllowed = notifications;
    });
  }

  Future<void> _setDarkMode(bool dark) async {
    final prefs = await SharedPreferences.getInstance();
    final current = themeNotifier.value;

    // Park the current choice under its own brightness before switching,
    // so this is a toggle between two remembered themes rather than a
    // one-way trip to the defaults.
    if (AppThemes.isDark(current)) {
      await prefs.setInt(_kLastDarkThemeKey, current);
    } else {
      await prefs.setInt(_kLastLightThemeKey, current);
    }

    final target = dark
        ? prefs.getInt(_kLastDarkThemeKey) ?? AppThemes.defaultDarkIndex
        : prefs.getInt(_kLastLightThemeKey) ?? AppThemes.defaultLightIndex;

    // Guard against a stored index from a build where the catalog was a
    // different length — a stale index would throw on the theme lookup at
    // the top of the widget tree, which takes the whole app with it.
    final safe = (target >= 0 && target < AppThemes.all.length)
        ? target
        : (dark ? AppThemes.defaultDarkIndex : AppThemes.defaultLightIndex);

    themeNotifier.value = safe;
    await prefs.setInt('selected_theme_index', safe);
    if (mounted) setState(() {});
  }

  Future<void> _pickTheme() async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _ThemeSheet(current: themeNotifier.value),
    );
    if (chosen == null) return;
    themeNotifier.value = chosen;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_theme_index', chosen);
    await prefs.setInt(
      AppThemes.isDark(chosen) ? _kLastDarkThemeKey : _kLastLightThemeKey,
      chosen,
    );
    if (mounted) setState(() {});
  }

  bool _restartingBle = false;

  /// Requests notification permission, and only falls back to the system
  /// settings app if the OS won't prompt (permanently denied). The old
  /// version jumped straight to app settings, which is the slow path and
  /// the wrong one on a first run where Android would happily show a
  /// dialog.
  ///
  /// When permission is already granted this fires a test alert instead —
  /// the row's whole purpose is confidence that a flare will actually reach
  /// you, and "it says allowed" is weaker evidence than hearing it.
  Future<void> _fixNotifications() async {
    if (_notificationsAllowed) {
      await NotificationService.showOfficialAlertNotification(
        sender: "Hops Admin",
        reason: "Test alert — alerting is working",
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Test alert sent. If you didn't get it, check Do Not Disturb."),
        duration: Duration(seconds: 4),
      ));
      return;
    }

    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      // No _load() here: didChangeAppLifecycleState re-reads on resume,
      // which is the only moment the answer can actually have changed.
      return;
    }
    await _load();
  }

  /// Restarts the scan, having first made sure it's allowed to run.
  ///
  /// The permission request used to live in a separate "Re-check
  /// permissions" row, which was removed: it duplicated the notification
  /// request above it, and a generic permissions catch-all is the wrong
  /// shape anyway. Each permission now sits with the feature it powers —
  /// notifications on the alerting row, Bluetooth and location here — so
  /// there's no button whose effect you have to guess at.
  ///
  /// This ordering also fixes the common case honestly: a listener that
  /// hears nothing is usually a permission problem, and restarting a scan
  /// that isn't permitted to find anything just fails again more quietly.
  Future<void> _restartBleListener() async {
    setState(() => _restartingBle = true);
    try {
      final statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ].request();

      // Android stops showing the dialog once something is permanently
      // denied, so request() returns instantly and the tap looks like it
      // did nothing — the exact failure the notification button had. Send
      // them somewhere that can actually change it.
      if (statuses.values.any((s) => s.isPermanentlyDenied)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Bluetooth or location is blocked in Android settings — "
              "opening them now."),
          duration: Duration(seconds: 4),
        ));
        await openAppSettings();
        return; // didChangeAppLifecycleState re-reads on return
      }

      // A real stop-and-start (see AdminBleHub.restart). This used to call
      // ensureStarted(), which returns immediately once the hub is already
      // running — so the button showed a success message having done
      // precisely nothing.
      await AdminBleHub.instance.restart();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Permissions checked, Bluetooth listener restarted."),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't restart — check Bluetooth is on."),
      ));
    } finally {
      if (mounted) setState(() => _restartingBle = false);
    }
  }

  Future<void> _setTextScale(double value) async {
    fontScaleNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_scale', value);
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sign out?"),
        content: const Text(
            "This device will stop receiving emergency flares and official alerts "
            "until someone signs in again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Sign out"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await signOutOfAdminApp(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = AppThemes.isDark(themeNotifier.value);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SettingsCard(
            title: "Signed in as",
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: colors.primary,
                  child: const Icon(Icons.shield, color: Colors.white, size: 20),
                ),
                title: Text(_username ?? "—",
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  [
                    if (_adminTitle != null && _adminTitle!.isNotEmpty) _adminTitle!,
                    if (_email != null) _email!,
                  ].join(" · "),
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
                ),
              ),
            ],
          ),
          _SettingsCard(
            title: "Appearance",
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: isDark,
                onChanged: _setDarkMode,
                secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: colors.primary),
                title: const Text("Dark mode"),
                subtitle: Text(
                  isDark ? "On — easier at night on a shift" : "Off",
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.palette_outlined, color: colors.primary),
                title: const Text("Theme"),
                subtitle: Text(AppThemes.all[themeNotifier.value].name,
                    style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6))),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: _pickTheme,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.format_size, color: colors.primary, size: 20),
                    const SizedBox(width: 16),
                    const Text("Text size"),
                    Expanded(
                      child: ValueListenableBuilder<double>(
                        valueListenable: fontScaleNotifier,
                        builder: (context, scale, _) => Slider(
                          value: scale.clamp(0.85, 1.6),
                          min: 0.85,
                          max: 1.6,
                          divisions: 5,
                          label: "${(scale * 100).round()}%",
                          onChanged: _setTextScale,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _SettingsCard(
            title: "Alerting",
            children: [
              // The single most consequential setting on an admin device:
              // without notification permission, an emergency flare arrives
              // silently and nobody finds out until someone opens the app.
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _notificationsAllowed ? Icons.notifications_active : Icons.notifications_off,
                  color: _notificationsAllowed ? Colors.green : Colors.redAccent,
                ),
                title: const Text("Emergency notifications"),
                subtitle: Text(
                  _notificationsAllowed
                      ? "Allowed — flares will raise an alarm"
                      : "Blocked — you will NOT be alerted to flares",
                  style: TextStyle(
                    fontSize: 12,
                    color: _notificationsAllowed
                        ? colors.onSurface.withValues(alpha: 0.6)
                        : Colors.redAccent,
                  ),
                ),
                trailing: TextButton(
                  onPressed: _fixNotifications,
                  child: Text(_notificationsAllowed ? "Test" : "Fix"),
                ),
              ),
              ValueListenableBuilder<Map<String, LiveAlert>>(
                valueListenable: AdminBleHub.instance.liveAlerts,
                builder: (context, alerts, _) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.sensors, color: Colors.green),
                  title: const Text("Bluetooth listener"),
                  subtitle: Text(
                    "Scanning in the background · ${alerts.length} active nearby\n"
                    "Restart also re-checks Bluetooth & location access",
                    style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
                  ),
                  isThreeLine: true,
                  trailing: _restartingBle
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: _restartBleListener,
                          child: const Text("Restart"),
                        ),
                ),
              ),
            ],
          ),
          _SettingsCard(
            title: "Session",
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text("Sign out", style: TextStyle(color: Colors.redAccent)),
                subtitle: Text(
                  "Clears this device's admin session",
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
                ),
                onTap: _confirmSignOut,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              "Hops Admin",
              style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.35)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SettingsCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: colors.primary.withValues(alpha: 0.8),
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeSheet extends StatelessWidget {
  final int current;
  const _ThemeSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(100),
            ),
          ),
          const SizedBox(height: 16),
          Text("Theme", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: colors.primary)),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: AppThemes.all.length,
              itemBuilder: (context, i) {
                final theme = AppThemes.all[i];
                return ListTile(
                  leading: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primary,
                      border: Border.all(color: theme.surface, width: 3),
                    ),
                  ),
                  title: Text(theme.name),
                  subtitle: Text(
                    AppThemes.isDark(i) ? "Dark" : "Light",
                    style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                  ),
                  trailing: i == current ? Icon(Icons.check, color: colors.primary) : null,
                  onTap: () => Navigator.pop(context, i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
