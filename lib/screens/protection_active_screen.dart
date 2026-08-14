// Protection screen: the camera runs while this route is mounted. On Windows
// the window expands to a fullscreen blackout when the user looks away; on
// Android (experimental) it notifies the separate overlay process instead.

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:window_manager/window_manager.dart';

import '../services/camera_gaze_service.dart';
import '../services/gaze_detector_service.dart';
import '../services/settings_service.dart';

// Design tokens (duplicated for file independence)
const _bg = Color(0xFF0D1117);
const _surface = Color(0xFF161B22);
const _border = Color(0xFF30363D);
const _blue = Color(0xFF3B82F6);
const _green = Color(0xFF10B981);
const _amber = Color(0xFFF59E0B);
const _textPrimary = Color(0xFFE6EDF3);
const _textMuted = Color(0xFF8B949E);

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
    await windowManager.setSize(const Size(440, 420));
    await windowManager.center();
  }

  Future<void> _restoreWindowSize() async {
    try {
      await windowManager.setFullScreen(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSize(const Size(480, 640));
      await windowManager.center();
    } catch (_) {}
  }

  /// If the blackout loses focus while the screen is meant to be protected,
  /// put it back on top. Otherwise alt-tab or a notification toast would
  /// reveal exactly the content the blackout exists to hide.
  @override
  void onWindowBlur() {
    if (!Platform.isWindows || !mounted) return;
    if (_gazeDetector.isScreenVisible) return;
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

  void _applyWindowMode() {
    if (!mounted || !Platform.isWindows) return;
    _enqueueWindowOp(() async {
      final bool isVisible = _gazeDetector.isScreenVisible;
      if (!isVisible && !_overlayActive) {
        _overlayActive = true;
        await windowManager.show();
        await windowManager.setFullScreen(true);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.focus();
      } else if (isVisible && _overlayActive) {
        _overlayActive = false;
        await windowManager.setFullScreen(false);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSize(const Size(440, 420));
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool isVisible = _gazeDetector.isScreenVisible;
    final bool showOverlay = !_isStarting && _error == null && !isVisible;

    return Stack(
      fit: StackFit.expand,
      children: [
        Scaffold(
          backgroundColor: _bg,
          appBar: Platform.isWindows ? _buildWindowsAppBar() : null,
          body: SafeArea(child: _buildBody(isVisible)),
        ),
        if (showOverlay && Platform.isWindows) _buildWindowsOverlay(),
      ],
    );
  }

  PreferredSizeWidget _buildWindowsAppBar() {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, size: 18, color: _textMuted),
        tooltip: 'Stop protection',
        onPressed: _stopProtection,
      ),
      title: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color:
                  _isStarting ? _amber : (_error != null ? Colors.red : _green),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isStarting
                ? 'Starting…'
                : (_error != null ? 'Error' : 'Protection active'),
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 14,
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

  Widget _buildBody(bool isVisible) {
    if (_isStarting) return _buildStarting();
    if (_error != null) return _buildErrorState();
    return _buildStatus(isVisible);
  }

  Widget _buildStarting() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _blue, strokeWidth: 2.5),
          SizedBox(height: 20),
          Text(
            'Starting camera…',
            style: TextStyle(color: _textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 32,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Camera error',
              style: TextStyle(
                color: _textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textMuted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _startCamera,
              style: FilledButton.styleFrom(backgroundColor: _blue),
              child: const Text('Retry'),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _stopProtection,
              child: const Text(
                'Stop Protection',
                style: TextStyle(color: _textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(bool isVisible) {
    final CameraController? controller = _cameraGazeService.controller;
    final bool hasPreview =
        controller != null && controller.value.isInitialized;
    final ProtectionReason reason = _gazeDetector.reason;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (hasPreview) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 140,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: CameraPreview(controller),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isVisible
                        ? _green.withValues(alpha: 0.3)
                        : _amber.withValues(alpha: 0.3),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isVisible ? _green : _amber,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isVisible ? _green : _amber).withValues(
                              alpha: 0.5,
                            ),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isVisible ? 'Screen visible' : 'Screen protected',
                            style: TextStyle(
                              color: isVisible ? _green : _amber,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            reason.message,
                            style: const TextStyle(
                              color: _textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Gaze confidence',
                          style: TextStyle(color: _textMuted, fontSize: 11),
                        ),
                        Text(
                          '${(_gazeDetector.confidence * 100).round()}%',
                          style: const TextStyle(
                            color: _textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _gazeDetector.confidence,
                        backgroundColor: _border,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isVisible ? _green : _amber,
                        ),
                        minHeight: 5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (Platform.isWindows) _buildFrameHygieneCard(),
          const SizedBox(height: 12),
          Text(
            Platform.isAndroid
                ? 'Minimise this app — the overlay will cover other apps when you look away.'
                : 'Use the minimise button to hide to tray. The blackout appears automatically.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _textMuted,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          if (Platform.isWindows) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => windowManager.hide(),
                icon: const Icon(Icons.minimize_rounded, size: 16),
                label: const Text('Minimise to Tray'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _textPrimary,
                  side: const BorderSide(color: _border),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _stopProtection,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('Stop Protection'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.red, width: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Surfaces the capture-file accounting, so the disk behaviour described in
  /// SECURITY.md is observable rather than something the user has to trust.
  Widget _buildFrameHygieneCard() {
    final int shredded = _cameraGazeService.framesShredded;
    final int failures = _cameraGazeService.shredFailures;
    final bool healthy = failures == 0;

    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: healthy ? _border : Colors.redAccent.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            healthy ? Icons.delete_sweep_rounded : Icons.warning_amber_rounded,
            size: 16,
            color: healthy ? _textMuted : Colors.redAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              healthy
                  ? '$shredded capture files erased'
                  : '$shredded erased · $failures could not be deleted',
              style: TextStyle(
                color: healthy ? _textMuted : Colors.redAccent,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Windows fullscreen blackout ───────────────────────────────────────────

  Widget _buildWindowsOverlay() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.1),
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.lock_rounded,
                size: 48,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Screen Protected',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _gazeDetector.reason.message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 48),
            TextButton(
              onPressed: _stopProtection,
              child: Text(
                'Stop Protection',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
