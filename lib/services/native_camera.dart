// Dart side of the in-memory capture path.
//
// Talks to windows/runner/mf_camera.cpp over a method channel. Frames arrive as
// raw BGRA and are wrapped in a BMP container here (see bmp_encoder.dart)
// because the face detector's only entry point decodes an encoded image.
//
// Nothing here touches the filesystem. That is the entire point: the
// `camera_windows` path this replaces has no image-stream API, so its only way
// to produce a frame is to encode a JPEG to disk first.
//
// Availability is not assumed. `start` returns false on any failure — no
// Windows, no Media Foundation, a camera that will not produce RGB32 — and the
// caller falls back to the old path rather than losing protection entirely.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bmp_encoder.dart';

class NativeCameraCapture {
  static const MethodChannel _channel = MethodChannel('safescreen/camera');

  bool _running = false;
  String? _device;
  int _width = 0;
  int _height = 0;

  bool get isRunning => _running;

  /// Friendly name of the device the native side actually opened.
  String? get device => _device;

  int get width => _width;
  int get height => _height;

  /// Opens the camera, preferring one whose name contains [preferredName].
  ///
  /// Returns false rather than throwing when in-memory capture is unavailable,
  /// so the caller can fall back without special-casing errors.
  Future<bool> start({String? preferredName}) async {
    if (!Platform.isWindows) return false;
    if (_running) return true;

    try {
      final Object? reply = await _channel.invokeMethod<Object?>('start', {
        if (preferredName != null) 'deviceName': preferredName,
      });
      if (reply is! Map) return false;

      _device = reply['device'] as String?;
      _width = (reply['width'] as num?)?.toInt() ?? 0;
      _height = (reply['height'] as num?)?.toInt() ?? 0;
      if (_width <= 0 || _height <= 0) return false;

      _running = true;
      debugPrint(
        'SafeScreen: in-memory capture running on '
        '${_device ?? "camera"} at ${_width}x$_height',
      );
      return true;
    } catch (e) {
      debugPrint('SafeScreen: in-memory capture unavailable ($e)');
      return false;
    }
  }

  /// Grabs one frame, already wrapped as a BMP ready for the detector.
  ///
  /// Null means no usable frame. Callers must treat that as blindness — and
  /// therefore protect the screen — rather than as "nobody is there".
  Future<Uint8List?> grabFrame() async {
    if (!_running) return null;
    try {
      final Object? reply = await _channel.invokeMethod<Object?>('grab');
      if (reply is! Map) return null;

      final Uint8List? bgra = reply['bytes'] as Uint8List?;
      final int w = (reply['width'] as num?)?.toInt() ?? 0;
      final int h = (reply['height'] as num?)?.toInt() ?? 0;
      final int stride = (reply['stride'] as num?)?.toInt() ?? 0;
      if (bgra == null) return null;

      return encodeBgraAsBmp(bgra, width: w, height: h, stride: stride);
    } catch (e) {
      debugPrint('SafeScreen: in-memory grab failed ($e)');
      return null;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _device = null;
    _width = 0;
    _height = 0;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('SafeScreen: in-memory capture stop failed ($e)');
    }
  }
}
