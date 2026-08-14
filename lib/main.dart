import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:window_manager/window_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'screens/privacy_screen.dart';
import 'screens/protection_active_screen.dart';
import 'services/settings_service.dart';
import 'overlay/overlay_screen.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.load();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    windowManager.addListener(_WindowsTrayListener());
    await windowManager.setPreventClose(false);
  }
  runApp(const SafeScreenApp());
}

class _WindowsTrayListener extends WindowListener {
  @override
  void onWindowMinimize() => windowManager.hide();
}

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: OverlayScreen()),
  );
}

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

class SafeScreenApp extends StatelessWidget {
  const SafeScreenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeScreen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF0D1117),
          onSurface: const Color(0xFFE6EDF3),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        useMaterial3: true,
      ),
      home: const SafeScreenHome(),
    );
  }
}

// ---------------------------------------------------------------------------
// Home screen
// ---------------------------------------------------------------------------

class SafeScreenHome extends StatefulWidget {
  const SafeScreenHome({super.key});

  @override
  State<SafeScreenHome> createState() => _SafeScreenHomeState();
}

class _SafeScreenHomeState extends State<SafeScreenHome>
    with tray.TrayListener {
  bool _checking = true;
  String? _error;
  bool _canOpenSettings = false;
  bool _showSettings = false;
  double _sensitivity = SettingsService.instance.sensitivity;
  bool _detectShoulderSurfers = SettingsService.instance.detectShoulderSurfers;

  // Design tokens
  static const _bg = Color(0xFF0D1117);
  static const _surface = Color(0xFF161B22);
  static const _border = Color(0xFF30363D);
  static const _blue = Color(0xFF3B82F6);
  static const _green = Color(0xFF10B981);
  static const _textPrimary = Color(0xFFE6EDF3);
  static const _textMuted = Color(0xFF8B949E);

  @override
  void initState() {
    super.initState();
    _checkCamera();
    if (Platform.isWindows) {
      tray.trayManager.addListener(this);
      _initWindowsTray();
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      tray.trayManager.removeListener(this);
      tray.trayManager.destroy();
    }
    super.dispose();
  }

  // ── Tray ──────────────────────────────────────────────────────────────────

  Future<void> _initWindowsTray() async {
    try {
      final byteData = await rootBundle.load('assets/tray_icon.ico');
      final dir = await getTemporaryDirectory();
      final icoPath = path.join(dir.path, 'safescreen_tray.ico');
      await File(icoPath).writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
      );
      await tray.trayManager.setIcon(icoPath);
      await tray.trayManager.setToolTip('SafeScreen');
      await tray.trayManager.setContextMenu(
        tray.Menu(
          items: [
            tray.MenuItem(key: 'show', label: 'Show SafeScreen'),
            tray.MenuItem(key: 'hide', label: 'Hide to tray'),
            tray.MenuItem.separator(),
            tray.MenuItem(key: 'exit', label: 'Exit'),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Tray init: $e');
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem item) {
    switch (item.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'hide':
        windowManager.hide();
      case 'exit':
        windowManager.close();
    }
  }

  // ── Camera check ──────────────────────────────────────────────────────────

  Future<void> _checkCamera() async {
    setState(() {
      _checking = true;
      _error = null;
      _canOpenSettings = false;
    });
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          if (mounted) {
            setState(() {
              _checking = false;
              _canOpenSettings = status.isPermanentlyDenied;
              _error =
                  status.isPermanentlyDenied
                      ? 'Camera access was permanently denied. Enable it in Settings.'
                      : 'Camera access is required to detect gaze.';
            });
          }
          return;
        }
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _checking = false;
            _error = 'No camera found on this device.';
          });
        }
        return;
      }
      if (mounted) setState(() => _checking = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goToProtection() {
    if (!Platform.isAndroid) {
      Navigator.of(context).push(_route(const ProtectionActiveScreen()));
      return;
    }
    _startAndroidOverlay();
  }

  Future<void> _startAndroidOverlay() async {
    try {
      // ignore: unnecessary_null_aware_operator
      bool granted = (await FlutterOverlayWindow.isPermissionGranted()) == true;
      if (!granted) {
        // ignore: unnecessary_null_aware_operator
        granted = (await FlutterOverlayWindow.requestPermission()) == true;
      }
      if (!granted || !mounted) return;
      await FlutterOverlayWindow.showOverlay(
        height: WindowSize.fullCover,
        width: WindowSize.matchParent,
        flag: OverlayFlag.defaultFlag,
        overlayTitle: 'SafeScreen',
        overlayContent: 'Privacy protection active',
      );
      if (!mounted) return;
      Navigator.of(context).push(_route(const ProtectionActiveScreen()));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Overlay error: $e')));
      }
    }
  }

  void _goToPrivacyScreen() {
    Navigator.of(context).push(_route(const PrivacyScreen()));
  }

  static PageRoute _route(Widget page) =>
      MaterialPageRoute(builder: (_) => page);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_checking) return _buildLoading();
    if (_error != null) return _buildError();
    return _buildHome();
  }

  Widget _buildLoading() {
    return const Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _blue),
            SizedBox(height: 20),
            Text('Checking camera…', style: TextStyle(color: _textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.videocam_off_rounded,
                  size: 40,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Camera unavailable',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _textMuted, height: 1.5),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _checkCamera,
                style: FilledButton.styleFrom(backgroundColor: _blue),
                child: const Text('Retry'),
              ),
              if (_canOpenSettings) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () async {
                    await openAppSettings();
                    if (mounted) _checkCamera();
                  },
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text('Open Settings'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHome() {
    return Scaffold(
      backgroundColor: _bg,
      appBar: Platform.isWindows ? _buildWindowsAppBar() : null,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildCameraChip(),
              const SizedBox(height: 24),
              _buildModeCard(
                icon: Icons.shield_rounded,
                iconColor: _blue,
                title: 'Full Protection',
                subtitle:
                    Platform.isAndroid
                        ? 'Overlays every app when you look away'
                        : 'Fullscreen overlay when you look away',
                bullets:
                    Platform.isAndroid
                        ? ['Works over all apps', 'Hides automatically']
                        : ['Always on top', 'Minimises to system tray'],
                buttonLabel: 'Start Protection',
                onPressed: _goToProtection,
              ),
              const SizedBox(height: 16),
              _buildModeCard(
                icon: Icons.blur_on_rounded,
                iconColor: _green,
                title: 'In-App Mode',
                subtitle: 'Blurs only this window — no overlay needed',
                bullets: ['No special permissions', 'Instant blur effect'],
                buttonLabel: 'Start In-App',
                onPressed: _goToPrivacyScreen,
              ),
              const SizedBox(height: 20),
              _buildSettingsCard(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildWindowsAppBar() {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      title: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.shield_rounded, size: 14, color: _blue),
          ),
          const SizedBox(width: 10),
          const Text(
            'SafeScreen',
            style: TextStyle(
              color: _textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.minimize_rounded, size: 18),
          tooltip: 'Minimise to tray',
          onPressed: () => windowManager.hide(),
          color: _textMuted,
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          tooltip: 'Close',
          onPressed: () => windowManager.close(),
          color: _textMuted,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: _blue.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: _blue.withValues(alpha: 0.25),
              width: 1.5,
            ),
          ),
          child: const Icon(Icons.shield_rounded, size: 36, color: _blue),
        ),
        const SizedBox(height: 16),
        const Text(
          'SafeScreen',
          style: TextStyle(
            color: _textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Gaze-based privacy protection',
          style: TextStyle(color: _textMuted, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildCameraChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _green.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'Camera ready',
            style: TextStyle(
              color: _green,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required List<String> bullets,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(color: _textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...bullets.map(
            (b) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 14,
                    color: iconColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    b,
                    style: const TextStyle(color: _textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: iconColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                buttonLabel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _showSettings = !_showSettings),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 18, color: _textMuted),
                  const SizedBox(width: 10),
                  const Text(
                    'Detection settings',
                    style: TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _showSettings
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: _textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_showSettings) ...[
            Divider(height: 1, color: _border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Sensitivity',
                        style: TextStyle(
                          color: _textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _sensitivityLabel(_sensitivity),
                        style: const TextStyle(
                          color: _blue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: _blue,
                      inactiveTrackColor: _border,
                      thumbColor: _blue,
                      overlayColor: _blue.withValues(alpha: 0.12),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _sensitivity,
                      min: 0,
                      max: 1,
                      divisions: 4,
                      onChanged: (v) => setState(() => _sensitivity = v),
                      onChangeEnd:
                          (v) => SettingsService.instance.setSensitivity(v),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text(
                        'Lenient',
                        style: TextStyle(color: _textMuted, fontSize: 11),
                      ),
                      Text(
                        'Strict',
                        style: TextStyle(color: _textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _sensitivityDescription(_sensitivity),
                    style: const TextStyle(
                      color: _textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Divider(height: 1, color: _border),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Shoulder-surfer detection',
                              style: TextStyle(
                                color: _textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Protect the screen when a second face appears',
                              style: TextStyle(color: _textMuted, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _detectShoulderSurfers,
                        activeColor: _blue,
                        onChanged: (v) {
                          setState(() => _detectShoulderSurfers = v);
                          SettingsService.instance.setDetectShoulderSurfers(v);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _sensitivityLabel(double v) {
    if (v <= 0.1) return 'Very Lenient';
    if (v <= 0.35) return 'Lenient';
    if (v <= 0.65) return 'Medium';
    if (v <= 0.85) return 'Strict';
    return 'Very Strict';
  }

  String _sensitivityDescription(double v) {
    if (v <= 0.35) {
      return 'Large head movements allowed before screen is protected. Good for busy environments.';
    }
    if (v <= 0.65) {
      return 'Balanced — protects screen when you look away but tolerates small shifts.';
    }
    return 'Screen protects quickly at the slightest head turn. Best for high-privacy needs.';
  }
}
