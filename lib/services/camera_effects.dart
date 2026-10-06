// Camera effects applied before SafeScreen ever sees a frame.
//
// Windows Studio Effects (on Copilot+ PCs) and some camera drivers can blur the
// background or crop the picture to follow the user. Both happen inside the
// camera pipeline, to the physical device, under its normal name -- so the
// virtual-camera check in camera_selection.dart cannot see them. Either one can
// remove a shoulder surfer from the frame, and the detector would then report
// "watching" while seeing nothing.
//
// The camera can be asked whether these are on (see QueryEffects in
// windows/runner/mf_camera.cpp). This file turns that answer into something the
// UI can state plainly.
//
// Eye-contact correction is deliberately not reported. It moves the pupils
// only, and SafeScreen judges attention from head pose -- the positions of the
// eyes, nose, mouth and ears -- so it does not change the look-away decision.
//
// Pure Dart, like the rest of the detection logic, so it stays unit-testable.

class CameraEffects {
  const CameraEffects({this.backgroundBlur, this.autoFraming});

  /// Nothing has been reported: not checked yet, the fallback capture path is
  /// in use, or the camera does not answer the query.
  static const CameraEffects unknown = CameraEffects();

  /// Null means the camera did not report it -- not that it is off.
  final bool? backgroundBlur;
  final bool? autoFraming;

  /// Reads the native reply. Anything that is not a clear true or false is
  /// treated as unreported rather than guessed at.
  factory CameraEffects.fromReply(Object? reply) {
    if (reply is! Map) return unknown;
    bool? read(String key) {
      final Object? v = reply[key];
      return v is bool ? v : null;
    }

    return CameraEffects(
      backgroundBlur: read('backgroundBlur'),
      autoFraming: read('autoFraming'),
    );
  }

  /// At least one effect is known to be on that can hide a second person.
  bool get hidesOthers => backgroundBlur == true || autoFraming == true;

  /// The camera answered for at least one effect.
  bool get isReported => backgroundBlur != null || autoFraming != null;

  /// Short status for the console.
  String get summary {
    if (backgroundBlur == true && autoFraming == true) {
      return 'Blur + framing on';
    }
    if (backgroundBlur == true) return 'Background blur on';
    if (autoFraming == true) return 'Auto framing on';
    // "None" only when the camera has answered for both. One answer is not
    // enough: reporting "None" while blur went unanswered is how a real blur
    // could hide behind a reassuring label.
    if (backgroundBlur == false && autoFraming == false) return 'None';
    if (backgroundBlur == false) return 'Framing unknown';
    if (autoFraming == false) return 'Blur unknown';
    return 'Not reported';
  }

  @override
  bool operator ==(Object other) =>
      other is CameraEffects &&
      other.backgroundBlur == backgroundBlur &&
      other.autoFraming == autoFraming;

  @override
  int get hashCode => Object.hash(backgroundBlur, autoFraming);
}
