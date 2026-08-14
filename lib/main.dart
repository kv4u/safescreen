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
import 'theme/tokens.dart';
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

    // The runner creates the window at 1280x720 and shows it immediately, so
    // without this the app flashes up as a large, mostly empty window and then
    // snaps down to panel size. waitUntilReadyToShow sizes it before the first
    // paint; the minimum size stops a drag from breaking the layout.
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: W.panel,
        minimumSize: W.minimum,
        center: true,
        backgroundColor: C.paper,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
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
          seedColor: C.signal,
          brightness: Brightness.light,
        ).copyWith(surface: C.paper, onSurface: C.ink),
        scaffoldBackgroundColor: C.paper,
        splashFactory: NoSplash.splashFactory,
        useMaterial3: true,
      ),
      builder: (BuildContext context, Widget? child) {
        // Windows text-scale settings can go high enough to burst a compact
        // panel. Honour the user's preference, but cap it where the layout
        // still holds together rather than overflowing.
        final MediaQueryData mq = MediaQuery.of(context);
        final double scale = mq.textScaler.scale(14) / 14;
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(scale.clamp(1.0, 1.35)),
          ),
          child: child!,
        );
      },
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

  /// Name of the camera that will be used, shown in the spec table so the user
  /// can see which device this is about before granting it their face.
  String? _cameraName;

  String get _cameraLabel => _cameraName ?? 'Detected';

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
      // Prefer the front camera, matching what CameraGazeService will pick.
      final Iterable<CameraDescription> front = cameras.where(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.front,
      );
      final CameraDescription chosen =
          front.isNotEmpty ? front.first : cameras.first;

      if (mounted) {
        setState(() {
          _checking = false;
          _cameraName = chosen.name.trim().isEmpty ? null : chosen.name.trim();
        });
      }
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
    return Scaffold(
      backgroundColor: C.paper,
      body: Column(
        children: [
          if (Platform.isWindows)
            TitleStrip(
              title: 'SafeScreen',
              onMinimise: () => windowManager.hide(),
              onClose: () => windowManager.close(),
            ),
          // Expanded + scroll view: the panel is laid out to fit its natural
          // window size, and degrades to scrolling rather than overflowing
          // when the window is dragged small or the text scale is large.
          Expanded(
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(S.x5),
                child: _buildBody(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_checking) return _buildChecking();
    if (_error != null) return _buildError();
    return _buildPanel();
  }

  // -- States ---------------------------------------------------------------

  Widget _buildChecking() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STATUS', style: T.label),
        const SizedBox(height: S.x2),
        const Text('Checking\ncamera', style: T.state),
        const SizedBox(height: S.x5),
        const SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            minHeight: 3,
            color: C.ink,
            backgroundColor: C.ruleFaint,
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STATUS', style: T.label.copyWith(color: C.signal)),
        const SizedBox(height: S.x2),
        Text('Camera\nunavailable', style: T.state.copyWith(color: C.signal)),
        const SizedBox(height: S.x5),
        const Rule(),
        const SizedBox(height: S.x4),
        Text(_error!, style: T.body),
        const SizedBox(height: S.x6),
        PanelButton(label: 'Retry', primary: true, onPressed: _checkCamera),
        if (_canOpenSettings) ...[
          const SizedBox(height: S.x2),
          PanelButton(
            label: 'Open system settings',
            onPressed: () async {
              await openAppSettings();
              if (mounted) _checkCamera();
            },
          ),
        ],
      ],
    );
  }

  // -- The panel ------------------------------------------------------------

  Widget _buildPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SCREEN PRIVACY', style: T.label),
        const SizedBox(height: S.x2),
        const Text('Ready', style: T.state),
        const SizedBox(height: S.x3),
        Text(
          'Your screen goes dark when you look away, or when a second '
          'face appears behind you.',
          style: T.body,
        ),
        const SizedBox(height: S.x6),
        const Rule(),
        SpecRow(label: 'Camera', value: _cameraLabel),
        const Rule(faint: true),
        SpecRow(label: 'Sensitivity', value: _sensitivityLabel(_sensitivity)),
        const Rule(faint: true),
        SpecRow(
          label: 'Shoulder',
          value: _detectShoulderSurfers ? 'Watching' : 'Ignored',
          valueColor: _detectShoulderSurfers ? C.ink : C.inkMuted,
        ),
        const Rule(faint: true),
        const SpecRow(label: 'Network', value: 'None', emphasis: true),
        const Rule(),
        const SizedBox(height: S.x6),
        PanelButton(
          label: Platform.isAndroid ? 'Start overlay' : 'Start protection',
          primary: true,
          icon: Icons.shield_outlined,
          onPressed: _goToProtection,
        ),
        const SizedBox(height: S.x2),
        PanelButton(
          label: 'In-app mode only',
          icon: Icons.blur_on,
          onPressed: _goToPrivacyScreen,
        ),
        const SizedBox(height: S.x6),
        _buildSettings(),
      ],
    );
  }

  Widget _buildSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showSettings = !_showSettings),
          hoverColor: C.paperSunken,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x2),
            child: Row(
              children: [
                Icon(
                  _showSettings ? Icons.remove : Icons.add,
                  size: 13,
                  color: C.inkMuted,
                ),
                const SizedBox(width: S.x2),
                Text('DETECTION SETTINGS', style: T.label),
              ],
            ),
          ),
        ),
        if (_showSettings) ...[
          const Rule(faint: true),
          const SizedBox(height: S.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  _sensitivityLabel(_sensitivity).toUpperCase(),
                  style: T.readout.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text('${(_sensitivity * 100).round()}', style: T.label),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: C.ink,
              inactiveTrackColor: C.ruleFaint,
              thumbColor: C.signal,
              overlayColor: C.signal.withValues(alpha: 0.10),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              tickMarkShape: SliderTickMarkShape.noTickMark,
            ),
            child: Slider(
              value: _sensitivity,
              divisions: 4,
              onChanged: (double v) => setState(() => _sensitivity = v),
              onChangeEnd: SettingsService.instance.setSensitivity,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('LENIENT', style: T.label),
              Text('STRICT', style: T.label),
            ],
          ),
          const SizedBox(height: S.x3),
          Text(_sensitivityDescription(_sensitivity), style: T.body),
          const SizedBox(height: S.x5),
          const Rule(faint: true),
          const SizedBox(height: S.x3),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SHOULDER-SURFER', style: T.label),
                    const SizedBox(height: 2),
                    Text(
                      'Protect when a second face appears',
                      style: T.body.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _detectShoulderSurfers,
                activeColor: C.signal,
                inactiveThumbColor: C.inkMuted,
                inactiveTrackColor: C.ruleFaint,
                onChanged: (bool v) {
                  setState(() => _detectShoulderSurfers = v);
                  SettingsService.instance.setDetectShoulderSurfers(v);
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _sensitivityLabel(double v) {
    if (v <= 0.1) return 'Very lenient';
    if (v <= 0.35) return 'Lenient';
    if (v <= 0.65) return 'Medium';
    if (v <= 0.85) return 'Strict';
    return 'Very strict';
  }

  String _sensitivityDescription(double v) {
    if (v <= 0.35) {
      return 'Tolerates large head movements before protecting. '
          'Suits busy environments.';
    }
    if (v <= 0.65) {
      return 'Balanced. Protects when you look away but tolerates '
          'small shifts.';
    }
    return 'Protects at the slightest turn of the head. '
        'Best for high-privacy work.';
  }
}
