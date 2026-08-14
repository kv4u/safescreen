// Head-pose estimation from BlazeFace's 6 keypoints.
//
// The Windows detector (face_detection_tflite) does not report Euler angles the
// way ML Kit does on Android, but it does report five usable keypoints. Their
// relative geometry is enough to recover yaw and roll analytically, and to
// derive a normalised pitch metric.
//
// Pure Dart on purpose: no Flutter or plugin imports, so it is cheap to unit
// test against synthetic geometry.

import 'dart:math' as math;

const double _radToDeg = 180.0 / math.pi;

/// A 2-D point in image pixel coordinates (y grows downward).
class Pt {
  const Pt(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => 'Pt($x, $y)';
}

/// The five BlazeFace keypoints this estimator needs.
///
/// "left" and "right" are as reported by the detector — which side of the real
/// face they land on depends on mirroring, and deliberately does not matter:
/// every quantity below is derived from the geometry between points, and yaw is
/// reported relative to the image rather than to the subject.
class FaceKeypoints {
  const FaceKeypoints({
    required this.leftEye,
    required this.rightEye,
    required this.noseTip,
    required this.leftTragion,
    required this.rightTragion,
  });

  final Pt leftEye;
  final Pt rightEye;
  final Pt noseTip;
  final Pt leftTragion;
  final Pt rightTragion;
}

/// Head orientation recovered from [FaceKeypoints].
class HeadPose {
  const HeadPose({
    required this.yaw,
    required this.roll,
    required this.pitchRatio,
    required this.eyeSpan,
    required this.tragionSpan,
  });

  /// Degrees of horizontal head rotation. 0 = facing the camera. Positive means
  /// the nose has swung toward the +x side of the image.
  final double yaw;

  /// Degrees of head tilt, normalised to [-90, 90]. 0 = eyes level.
  final double roll;

  /// Nose displacement below the eye line, in units of eye separation, measured
  /// perpendicular to the eye line so it is unaffected by roll.
  ///
  /// This is a *raw* metric, not an angle: its neutral value depends on facial
  /// proportions, so it is only meaningful compared against a per-user baseline.
  /// See [PitchBaseline].
  final double pitchRatio;

  /// Distance between the eye keypoints, in pixels. Proxy for how close the
  /// user is to the camera.
  final double eyeSpan;

  /// Distance between the tragion keypoints, in pixels.
  final double tragionSpan;

  @override
  String toString() =>
      'HeadPose(yaw: ${yaw.toStringAsFixed(1)}°, '
      'roll: ${roll.toStringAsFixed(1)}°, '
      'pitchRatio: ${pitchRatio.toStringAsFixed(3)})';
}

/// Recovers head orientation from face keypoints.
///
/// Returns null when the geometry is degenerate — points coincident or so close
/// together that the result would be noise. Callers must treat null as "no
/// usable reading" and fail closed rather than assuming the user is present.
HeadPose? estimateHeadPose(FaceKeypoints k) {
  // ── Eye axis ────────────────────────────────────────────────────────────
  // Force the axis to point in +x so every derived sign is deterministic
  // regardless of which eye the detector labelled "left".
  double eyeDx = k.leftEye.x - k.rightEye.x;
  double eyeDy = k.leftEye.y - k.rightEye.y;
  if (eyeDx < 0) {
    eyeDx = -eyeDx;
    eyeDy = -eyeDy;
  }
  final double eyeSpan = math.sqrt(eyeDx * eyeDx + eyeDy * eyeDy);
  if (!eyeSpan.isFinite || eyeSpan < 1e-3) return null;

  final double ux = eyeDx / eyeSpan;
  final double uy = eyeDy / eyeSpan;

  // Roll is just the inclination of that axis.
  final double roll = math.atan2(eyeDy, eyeDx) * _radToDeg;

  // ── Pitch ratio ─────────────────────────────────────────────────────────
  // Perpendicular to the eye axis. With u pointing +x, n = (-uy, ux) points
  // downward in image coordinates, so a nose below the eyes is positive.
  final double nx = -uy;
  final double ny = ux;
  final double eyeMidX = (k.leftEye.x + k.rightEye.x) / 2;
  final double eyeMidY = (k.leftEye.y + k.rightEye.y) / 2;
  final double pitchRatio =
      ((k.noseTip.x - eyeMidX) * nx + (k.noseTip.y - eyeMidY) * ny) / eyeSpan;

  // ── Yaw ─────────────────────────────────────────────────────────────────
  // Model the head as a cylinder of radius R: the nose sits at the front and
  // the tragions at ±90°. Projected onto the image x-axis at yaw θ,
  //   nose     = R·sin θ
  //   tragionA = R·cos θ
  //   tragionB = −R·cos θ
  // so the nose's normalised position between the tragions is
  //   t = (sin θ + cos θ) / (2 cos θ) = 0.5 + 0.5·tan θ
  // and therefore θ = atan((t − 0.5) · 2).
  Pt a = k.rightTragion;
  Pt b = k.leftTragion;
  if (b.x - a.x < 0) {
    final Pt swap = a;
    a = b;
    b = swap;
  }
  final double tvx = b.x - a.x;
  final double tvy = b.y - a.y;
  final double tragionSpan = math.sqrt(tvx * tvx + tvy * tvy);
  if (!tragionSpan.isFinite || tragionSpan < 1e-3) return null;

  final double t =
      ((k.noseTip.x - a.x) * (tvx / tragionSpan) +
          (k.noseTip.y - a.y) * (tvy / tragionSpan)) /
      tragionSpan;
  final double yaw = math.atan((t - 0.5) * 2) * _radToDeg;

  if (!yaw.isFinite || !roll.isFinite || !pitchRatio.isFinite) return null;

  return HeadPose(
    yaw: yaw,
    roll: _normaliseRoll(roll),
    pitchRatio: pitchRatio,
    eyeSpan: eyeSpan,
    tragionSpan: tragionSpan,
  );
}

/// Folds a roll angle into [-90, 90]; a head tilted 170° reads as -10°.
double _normaliseRoll(double deg) {
  double d = deg;
  while (d > 90) {
    d -= 180;
  }
  while (d < -90) {
    d += 180;
  }
  return d;
}

/// Learns a per-user neutral [HeadPose.pitchRatio].
///
/// Facial proportions vary enough that a fixed neutral constant produces false
/// positives on some faces and misses on others. Instead the baseline is
/// learned from readings taken while the user is confidently looking at the
/// screen, via an exponential moving average.
///
/// Until [isCalibrated] the nominal value is used, so detection still works
/// from the first frame — it just gets more accurate as evidence accumulates.
class PitchBaseline {
  PitchBaseline({
    this.nominal = 0.62,
    this.smoothing = 0.05,
    this.samplesToCalibrate = 20,
  });

  /// Typical nose-below-eyes ratio for an adult face looking straight ahead.
  final double nominal;

  /// EMA weight applied to each new sample. Small values adapt slowly and
  /// resist being dragged off by a few bad frames.
  final double smoothing;

  /// How many confident samples before the learned value is trusted outright.
  final int samplesToCalibrate;

  double? _value;
  int _samples = 0;

  bool get isCalibrated => _samples >= samplesToCalibrate;

  /// The neutral ratio to compare against.
  double get value => _value ?? nominal;

  int get sampleCount => _samples;

  /// Feed a reading taken while the user is confidently looking at the screen.
  void observe(double pitchRatio) {
    if (!pitchRatio.isFinite) return;
    // Ignore wild readings so a bad detection cannot poison the baseline.
    if (pitchRatio.abs() > 3.0) return;

    if (_value == null) {
      _value = pitchRatio;
    } else {
      _value = _value! * (1 - smoothing) + pitchRatio * smoothing;
    }
    _samples++;
  }

  /// Signed deviation of [pitchRatio] from the learned neutral.
  double deviation(double pitchRatio) => pitchRatio - value;

  void reset() {
    _value = null;
    _samples = 0;
  }
}
