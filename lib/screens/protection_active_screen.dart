// Protection screen: the camera runs while this route is mounted. On Windows
// the window expands to a fullscreen blackout when the user looks away; on
// Android (experimental) it notifies the separate overlay process instead.

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../services/camera_gaze_service.dart';
import '../services/gaze_detector_service.dart';
import '../services/head_pose_estimator.dart';
import '../services/settings_service.dart';
import '../theme/tokens.dart';

class ProtectionActiveScreen extends StatefulWidget {
  const ProtectionActiveScreen({super.key});

  @override
  State<ProtectionActiveScreen> createState() => _ProtectionActiveScreenState();
}

class _ProtectionActiveScreenState extends State<ProtectionActiveScreen>
    with WindowListener {
  late final GazeDetectorService _gazeDetector;
  late final CameraGazeService _cameraGazeService;

  bool _isStarting = true;
  String? _error;

  // Windows overlay state
  bool _overlayActive = false;
  Timer? _windowDebounce;

  /// Serialises window_manager transitions. Without this, two overlapping
  /// calls to [_applyWindowMode] can interleave their awaits and leave the
  /// window fullscreen while the state says it is not — which would show the
  /// blackout over a screen the user is actively looking at, or worse, leave
  /// the screen exposed while the state believes it is covered.
  Future<void> _windowOp = Future<void>.value();

  bool _lastNotifiedVisible = false;

  /// Re-evaluates state on a timer. [GazeDetectorService.isScreenVisible] can
  /// flip to protected purely through the passage of time when samples stop
  /// arriving, and that transition fires no callback, so nothing else would
  /// notice a wedged capture loop.
  Timer? _watchdog;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final SettingsService settings = SettingsService.instance;
    _gazeDetector = GazeDetectorService(
      sensitivity: settings.sensitivity,
      detectShoulderSurfers: settings.detectShoulderSurfers,
    );
    _cameraGazeService = CameraGazeService(
      gazeDetector: _gazeDetector,
      onGazeStateChanged: _onGazeChanged,
      onError: (msg) {
        if (!mounted) return;
        setState(() {
          _isStarting = false;
          _error = msg;
        });
        // A camera failure can arrive while the blackout is already up — a
        // yanked USB webcam, for instance. Stand the window back down so the
        // error is readable and dismissable rather than fullscreen.
        if (Platform.isWindows) _applyWindowMode();
      },
    );
    if (Platform.isWindows) {
      windowManager.addListener(this);
      _initWindowsMode();
    }
    _startCamera();
    _watchdog = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkForStateDrift(),
    );
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _windowDebounce?.cancel();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      _restoreWindowSize();
    }
    _cameraGazeService.stop();
    super.dispose();
  }

  void _checkForStateDrift() {
    if (!mounted) return;
    if (_gazeDetector.isScreenVisible != _lastNotifiedVisible) {
      _onGazeChanged();
    } else {
      // Keep the confidence meter and reason text live.
      setState(() {});
    }
  }

  // ── Windows window management ─────────────────────────────────────────────

  Future<void> _initWindowsMode() async {
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSize(W.panel);
    await windowManager.center();
  }

  Future<void> _restoreWindowSize() async {
    try {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSize(W.panel);
      await windowManager.center();
    } catch (_) {}
  }

  /// Whether the fullscreen blackout should currently be covering the screen.
  ///
  /// Note the two guards beyond the detector state. The detector fails closed,
  /// so `isScreenVisible` is false while starting up and after a camera error —
  /// states where there is nothing to protect because the camera never opened.
  /// Escalating those to a fullscreen, always-on-top, self-refocusing window
  /// leaves the user with an error message they cannot alt-tab away from.
  bool get _blackoutWanted =>
      !_isStarting && _error == null && !_gazeDetector.isScreenVisible;

  /// If the blackout loses focus while the screen is meant to be protected,
  /// put it back on top. Otherwise alt-tab or a notification toast would
  /// reveal exactly the content the blackout exists to hide.
  @override
  void onWindowBlur() {
    if (!Platform.isWindows || !mounted) return;
    if (!_blackoutWanted) return;
    _enqueueWindowOp(() async {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  void _scheduleWindowUpdate() {
    _windowDebounce?.cancel();
    _windowDebounce = Timer(
      const Duration(milliseconds: 120),
      _applyWindowMode,
    );
  }

  /// Chains work onto [_windowOp] so window transitions never interleave.
  void _enqueueWindowOp(Future<void> Function() op) {
    _windowOp = _windowOp.then((_) async {
      if (!mounted) return;
      try {
        await op();
      } catch (e) {
        debugPrint('SafeScreen window op failed: $e');
      }
    });
  }

  /// Expands the blackout across every display.
  ///
  /// `setFullScreen` only ever covers the monitor the window happens to be on,
  /// so on a multi-monitor desk every other screen stayed perfectly readable
  /// while the user was away. That is the hole this closes.
  ///
  /// A caveat worth stating rather than burying: screen_retriever reports each
  /// monitor's geometry divided by *that monitor's own* scale factor, while
  /// window_manager converts bounds back using the window's current DPI. On a
  /// mixed-DPI desk those two disagree and the cover can land slightly off. A
  /// single-display setup therefore keeps the setFullScreen path, which is
  /// exact and additionally hides the taskbar.
  Future<void> _coverAllDisplays() async {
    List<Display> displays = const <Display>[];
    try {
      displays = await screenRetriever.getAllDisplays();
    } catch (e) {
      debugPrint('SafeScreen: could not enumerate displays: $e');
    }

    if (displays.length < 2) {
      await windowManager.setFullScreen(true);
      return;
    }

    Rect? union;
    for (final Display d in displays) {
      final Offset origin = d.visiblePosition ?? Offset.zero;
      final Rect r = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        d.size.width,
        d.size.height,
      );
      if (r.isEmpty) continue;
      union = union == null ? r : union.expandToInclude(r);
    }

    // Never trust a nonsensical rectangle. A bad cover is worse than a
    // single-monitor one, because it could leave the primary screen bare while
    // the app believes it is protected.
    if (union == null || union.width < 200 || union.height < 200) {
      debugPrint('SafeScreen: display union looked wrong, using fullscreen');
      await windowManager.setFullScreen(true);
      return;
    }

    await windowManager.setFullScreen(false);
    await windowManager.setBounds(union);
  }

  void _applyWindowMode() {
    if (!mounted || !Platform.isWindows) return;
    _enqueueWindowOp(() async {
      final bool wantBlackout = _blackoutWanted;
      if (wantBlackout && !_overlayActive) {
        _overlayActive = true;
        await windowManager.show();
        await _coverAllDisplays();
        await windowManager.setAlwaysOnTop(true);
        await windowManager.focus();
      } else if (!wantBlackout && _overlayActive) {
        _overlayActive = false;
        await windowManager.setFullScreen(false);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSize(W.panel);
        await windowManager.center();
      }
    });
  }

  // ── Gaze callback ─────────────────────────────────────────────────────────

  void _onGazeChanged() {
    if (!mounted) return;
    setState(() {});

    final bool isVisible = _gazeDetector.isScreenVisible;
    _lastNotifiedVisible = isVisible;

    if (Platform.isAndroid) {
      try {
        FlutterOverlayWindow.shareData(isVisible ? 'looking' : 'away');
      } catch (_) {}
    }
    if (Platform.isWindows) {
      _scheduleWindowUpdate();
    }
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  Future<void> _startCamera() async {
    setState(() {
      _isStarting = true;
      _error = null;
    });
    try {
      await _cameraGazeService.start();
      if (!mounted) return;
      setState(() => _isStarting = false);
      _lastNotifiedVisible = _gazeDetector.isScreenVisible;
      if (Platform.isAndroid) {
        try {
          FlutterOverlayWindow.shareData(
            _gazeDetector.isScreenVisible ? 'looking' : 'away',
          );
        } catch (_) {}
      }
      if (Platform.isWindows) _applyWindowMode();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isStarting = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _stopProtection() async {
    await _cameraGazeService.stop();
    if (Platform.isWindows) {
      await _restoreWindowSize();
    }
    if (Platform.isAndroid) {
      // Without this the overlay service outlives the camera and stays stuck on
      // whatever state it saw last — potentially a permanent black screen.
      try {
        await FlutterOverlayWindow.closeOverlay();
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  // -- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool isVisible = _gazeDetector.isScreenVisible;
    final bool showBlackout = _blackoutWanted;

    return Stack(
      fit: StackFit.expand,
      children: [
        Scaffold(
          backgroundColor: C.paper,
          body: Column(
            children: [
              if (Platform.isWindows)
                TitleStrip(
                  title:
                      _isStarting
                          ? 'Starting'
                          : (_error != null
                              ? 'Camera error'
                              : 'Protection active'),
                  statusColor:
                      _isStarting
                          ? C.inkMuted
                          : (_error != null
                              ? C.signal
                              : (isVisible ? C.clear : C.signal)),
                  onBack: _stopProtection,
                  onMinimise: () => windowManager.hide(),
                  onClose: () => windowManager.close(),
                ),
              Expanded(
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(S.x5),
                    child: _buildBody(isVisible),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showBlackout && Platform.isWindows) _buildBlackout(),
      ],
    );
  }

  Widget _buildBody(bool isVisible) {
    if (_isStarting) return _buildStarting();
    if (_error != null) return _buildErrorState();
    return _buildStatus(isVisible);
  }

  Widget _buildStarting() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STATUS', style: T.label),
        const SizedBox(height: S.x2),
        const Text('Opening\ncamera', style: T.state),
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

  Widget _buildErrorState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STATUS', style: T.label.copyWith(color: C.signal)),
        const SizedBox(height: S.x2),
        Text('Camera\nerror', style: T.state.copyWith(color: C.signal)),
        const SizedBox(height: S.x5),
        const Rule(),
        const SizedBox(height: S.x4),
        Text(_error!, style: T.body),
        const SizedBox(height: S.x6),
        PanelButton(label: 'Retry', primary: true, onPressed: _startCamera),
        const SizedBox(height: S.x2),
        PanelButton(label: 'Stop protection', onPressed: _stopProtection),
      ],
    );
  }

  // -- The console ----------------------------------------------------------

  Widget _buildStatus(bool isVisible) {
    final CameraController? controller = _cameraGazeService.controller;
    final bool hasPreview =
        controller != null && controller.value.isInitialized;
    final Color tone = isVisible ? C.clear : C.signal;
    final HeadPose? pose = _cameraGazeService.lastPose;
    final int failures = _cameraGazeService.shredFailures;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SCREEN', style: T.label),
        const SizedBox(height: S.x2),
        Text(
          isVisible ? 'Visible' : 'Protected',
          style: T.state.copyWith(color: tone),
        ),
        const SizedBox(height: S.x1),
        Text(_gazeDetector.reason.message, style: T.body),

        const SizedBox(height: S.x4),
        SegmentMeter(
          filled:
              isVisible
                  ? _gazeDetector.framesToReveal
                  : (_gazeDetector.confidence * _gazeDetector.framesToReveal)
                      .round(),
          total: _gazeDetector.framesToReveal,
          color: tone,
        ),

        if (hasPreview) ...[
          const SizedBox(height: S.x5),
          // Constrained rather than fixed: the preview keeps the camera's own
          // aspect ratio and simply gets smaller in a narrow window, instead of
          // forcing a 4:3 box wider than the panel.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: AspectRatio(
              aspectRatio:
                  controller.value.aspectRatio == 0
                      ? 4 / 3
                      : controller.value.aspectRatio,
              child: CameraPreview(controller),
            ),
          ),
        ],

        const SizedBox(height: S.x6),
        const Rule(),
        SpecRow(
          label: 'Yaw',
          value: pose == null ? '--' : '${pose.yaw.toStringAsFixed(1)} deg',
        ),
        const Rule(faint: true),
        SpecRow(
          label: 'Roll',
          value: pose == null ? '--' : '${pose.roll.toStringAsFixed(1)} deg',
        ),
        const Rule(faint: true),
        SpecRow(
          label: 'Calibration',
          value: _cameraGazeService.isPitchCalibrated ? 'Learned' : 'Learning',
        ),
        const Rule(faint: true),
        SpecRow(label: 'Capture', value: _captureModeLabel),
        const Rule(faint: true),
        SpecRow(
          label: 'Frames wiped',
          value:
              failures == 0
                  ? '${_cameraGazeService.framesShredded}'
                  : '${_cameraGazeService.framesShredded}  ($failures failed)',
          valueColor: failures == 0 ? C.ink : C.signal,
          emphasis: failures != 0,
        ),
        const Rule(),

        const SizedBox(height: S.x6),
        if (Platform.isWindows) ...[
          PanelButton(
            label: 'Minimise to tray',
            icon: Icons.remove,
            onPressed: () => windowManager.hide(),
          ),
          const SizedBox(height: S.x2),
        ],
        PanelButton(
          label: 'Stop protection',
          danger: true,
          icon: Icons.stop_outlined,
          onPressed: _stopProtection,
        ),
      ],
    );
  }

  String get _captureModeLabel {
    final ResolutionPreset? p = _cameraGazeService.activeResolution;
    return switch (p) {
      ResolutionPreset.low => '240p',
      ResolutionPreset.medium => '480p',
      ResolutionPreset.high => '720p',
      ResolutionPreset.veryHigh => '1080p',
      ResolutionPreset.ultraHigh => '2160p',
      ResolutionPreset.max => 'max',
      null => '--',
    };
  }

  // -- Blackout -------------------------------------------------------------

  Widget _buildBlackout() {
    return ColoredBox(
      color: C.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(S.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: C.paper.withValues(alpha: 0.8),
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.lock_outline,
                  size: 22,
                  color: C.paper.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: S.x5),
              Text(
                'SCREEN PROTECTED',
                textAlign: TextAlign.center,
                style: T.state.copyWith(
                  color: C.paper,
                  fontSize: 34,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: S.x3),
              Text(
                _gazeDetector.reason.message.toUpperCase(),
                textAlign: TextAlign.center,
                style: T.label.copyWith(color: C.signal, fontSize: 12),
              ),
              const SizedBox(height: S.x7),
              SizedBox(
                width: 220,
                child: PanelButton(
                  label: 'Stop protection',
                  onPressed: _stopProtection,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
