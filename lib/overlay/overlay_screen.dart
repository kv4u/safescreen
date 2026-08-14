// Fullscreen overlay shown when user looks away. Used on Android (over other apps).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

class OverlayScreen extends StatefulWidget {
  const OverlayScreen({super.key});

  @override
  State<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends State<OverlayScreen> {
  bool _isLooking = true; // start transparent until first update
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = FlutterOverlayWindow.overlayListener.listen((event) {
      final String msg = event?.toString() ?? '';
      final isLooking = msg == 'looking';
      if (mounted && _isLooking != isLooking) {
        setState(() => _isLooking = isLooking);
        try {
          FlutterOverlayWindow.updateFlag(
            isLooking ? OverlayFlag.clickThrough : OverlayFlag.defaultFlag,
          );
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // When looking: fully transparent, click-through. When away: fullscreen blur/dark over other apps.
    return Material(
      color: Colors.transparent,
      child: SizedBox.expand(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: _isLooking ? 0.0 : 1.0,
          child:
              _isLooking
                  ? const SizedBox.shrink()
                  : Container(
                    width: double.infinity,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.92),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.visibility_off,
                            size: 72,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Screen protected',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.95),
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Look at the screen to continue',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
        ),
      ),
    );
  }
}
