// In-app privacy mode: blurs this window when the user looks away.
// No overlay permissions needed.

import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../services/camera_gaze_service.dart';
import '../services/gaze_detector_service.dart';
import '../services/settings_service.dart';

const _bg = Color(0xFF0D1117);
const _surface = Color(0xFF161B22);
const _border = Color(0xFF30363D);
const _blue = Color(0xFF3B82F6);
const _green = Color(0xFF10B981);
const _amber = Color(0xFFF59E0B);
const _textPrimary = Color(0xFFE6EDF3);
const _textMuted = Color(0xFF8B949E);

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  late final GazeDetectorService _gazeDetector;
  late final CameraGazeService _cameraGazeService;

  bool _isStarting = true;
  String? _error;
  bool _showPreview = false;

  /// See the equivalent in ProtectionActiveScreen: the detector can fall back
  /// to protected through staleness alone, which fires no callback.
  Timer? _watchdog;

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
      onGazeStateChanged: () {
        if (mounted) setState(() {});
      },
      onError: (msg) {
        if (!mounted) return;
        setState(() {
          _isStarting = false;
          _error = msg;
        });
      },
    );
    _startCamera();
    _watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _cameraGazeService.stop();
    super.dispose();
  }

  Future<void> _startCamera() async {
    setState(() {
      _isStarting = true;
      _error = null;
    });
    try {
      await _cameraGazeService.start();
      if (mounted) setState(() => _isStarting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isStarting = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isLooking = _gazeDetector.isScreenVisible;

    return Scaffold(
      backgroundColor: _bg,
      appBar: Platform.isWindows ? _buildWindowsAppBar(isLooking) : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Simulated content background ─────────────────────────────────
          _buildBackground(),

          // ── Privacy blur overlay ──────────────────────────────────────────
          if (!_isStarting && _error == null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child:
                  isLooking
                      ? const SizedBox.shrink(key: ValueKey('visible'))
                      : _buildBlurOverlay(key: const ValueKey('blurred')),
            ),

          // ── Status chip (top-left) ────────────────────────────────────────
          if (!_isStarting && _error == null)
            Positioned(top: 16, left: 16, child: _buildStatusChip(isLooking)),

          // ── Camera preview thumbnail (top-right) ─────────────────────────
          if (!_isStarting && _error == null && _showPreview)
            Positioned(top: 16, right: 16, child: _buildCameraPreview()),

          // ── Toggle preview button (top-right when no preview) ────────────
          if (!_isStarting && _error == null && !_showPreview)
            Positioned(top: 16, right: 16, child: _buildPreviewToggle()),

          // ── Stop button (bottom-centre) ───────────────────────────────────
          if (!_isStarting && _error == null)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(child: _buildStopButton()),
            ),

          // ── Loading / error overlay ───────────────────────────────────────
          if (_isStarting || _error != null) _buildLoadingOrError(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildWindowsAppBar(bool isLooking) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, size: 18, color: _textMuted),
        tooltip: 'Stop',
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text(
        'In-App Mode',
        style: TextStyle(
          color: _textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
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

  Widget _buildBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF161B22)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 60),
            Container(
              height: 12,
              width: 180,
              decoration: BoxDecoration(
                color: _textMuted.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              height: 10,
              width: 240,
              decoration: BoxDecoration(
                color: _textMuted.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 10,
              width: 200,
              decoration: BoxDecoration(
                color: _textMuted.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              height: 80,
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _border),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 60,
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _border),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 60,
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _border),
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Center(
              child: Text(
                'Your work is here',
                style: TextStyle(
                  color: _textMuted.withValues(alpha: 0.3),
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _buildBlurOverlay({Key? key}) {
    return ClipRect(
      key: key,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          color: Colors.black.withValues(alpha: 0.72),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.lock_rounded,
                  size: 40,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Screen Protected',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _gazeDetector.reason.message,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(bool isLooking) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              isLooking
                  ? _green.withValues(alpha: 0.4)
                  : _amber.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Confidence bar dots
          ...List.generate(3, (i) {
            final filled = _gazeDetector.confidence > i / 3;
            return Padding(
              padding: const EdgeInsets.only(right: 3),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: filled ? (isLooking ? _green : _amber) : _border,
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
          const SizedBox(width: 6),
          Text(
            isLooking ? 'Visible' : 'Protected',
            style: TextStyle(
              color: isLooking ? _green : _amber,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraGazeService.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => setState(() => _showPreview = false),
      child: Container(
        width: 100,
        height: 80,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _buildPreviewToggle() {
    return GestureDetector(
      onTap: () => setState(() => _showPreview = true),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _border),
        ),
        child: const Icon(Icons.videocam_outlined, size: 16, color: _textMuted),
      ),
    );
  }

  Widget _buildStopButton() {
    return TextButton.icon(
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.stop_circle_outlined, size: 15),
      label: const Text('Stop'),
      style: TextButton.styleFrom(
        foregroundColor: _textMuted,
        backgroundColor: _surface.withValues(alpha: 0.85),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _border),
        ),
      ),
    );
  }

  Widget _buildLoadingOrError() {
    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      child:
          _isStarting
              ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: _blue, strokeWidth: 2.5),
                  SizedBox(height: 18),
                  Text(
                    'Starting camera…',
                    style: TextStyle(color: _textMuted, fontSize: 14),
                  ),
                ],
              )
              : Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 40,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error ?? 'Camera error',
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
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Go Back',
                        style: TextStyle(color: _textMuted),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }
}
