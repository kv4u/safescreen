// Decides whether the screen is safe to show, from per-frame face observations.
//
// Pure logic: no camera, no plugins, no Flutter. Both platform pipelines feed
// it [GazeSample]s and read back [isScreenVisible].
//
// Two principles govern the design:
//
//   1. Fail closed. The screen starts protected and stays protected whenever
//      evidence is missing, ambiguous, or stale. Revealing requires positive
//      proof that exactly one attentive face is present.
//   2. Asymmetric hysteresis. Hiding is fast (one bad frame is enough at
//      default sensitivity); revealing is slow (several consecutive good
//      frames). Flicker toward "protected" is a cosmetic annoyance; flicker
//      toward "visible" is a privacy failure.

import 'dart:math' as math;

/// Why the screen is currently protected.
enum ProtectionReason {
  /// Not protected — the user is present and attentive.
  none,

  /// No confirmed reading yet. The initial state, and deliberately protected.
  initialising,

  /// The detector reported no face in frame.
  noFace,

  /// A face is present but turned away from the screen.
  lookedAway,

  /// A face is present and facing the screen, but the eyes are closed.
  eyesClosed,

  /// More than one face is in frame — possible shoulder surfer.
  multipleFaces,

  /// The camera or detector failed. Protected because we are blind, not because
  /// we know the user left.
  detectorError,

  /// No sample has arrived recently enough to be trusted.
  stale,
}

extension ProtectionReasonMessage on ProtectionReason {
  /// Short human-readable explanation, suitable for the status UI.
  String get message => switch (this) {
    ProtectionReason.none => 'Looking at screen',
    ProtectionReason.initialising => 'Waiting for camera…',
    ProtectionReason.noFace => 'No one detected',
    ProtectionReason.lookedAway => 'Looking away',
    ProtectionReason.eyesClosed => 'Eyes closed',
    ProtectionReason.multipleFaces => 'Someone else is looking',
    ProtectionReason.detectorError => 'Detector unavailable',
    ProtectionReason.stale => 'Lost camera feed',
  };
}

/// One frame's worth of evidence.
///
/// Fields are nullable because the two platforms measure different things:
/// ML Kit reports Euler angles and eye-open probabilities, while the Windows
/// TFLite path reports keypoint geometry with no eye-openness signal at all.
/// A null field means "not measured", never "zero" — the detector skips checks
/// it has no data for rather than guessing.
class GazeSample {
  const GazeSample({
    required this.faceCount,
    this.yawDeg,
    this.pitchDeg,
    this.pitchDeviation,
    this.rollDeg,
    this.leftEyeOpen,
    this.rightEyeOpen,
  });

  /// A frame in which the detector ran successfully and saw nobody.
  const GazeSample.noFace()
    : faceCount = 0,
      yawDeg = null,
      pitchDeg = null,
      pitchDeviation = null,
      rollDeg = null,
      leftEyeOpen = null,
      rightEyeOpen = null;

  /// How many faces the detector found.
  final int faceCount;

  /// Horizontal head rotation in degrees; 0 = facing the camera.
  final double? yawDeg;

  /// Vertical head rotation in degrees (Android/ML Kit only).
  final double? pitchDeg;

  /// Normalised nose-below-eyes deviation from the user's neutral pose
  /// (Windows only — see `head_pose_estimator.dart`). Unitless.
  final double? pitchDeviation;

  /// Head tilt in degrees.
  final double? rollDeg;

  /// Eye-open probability in [0,1] (Android/ML Kit only).
  final double? leftEyeOpen;
  final double? rightEyeOpen;
}

class GazeDetectorService {
  GazeDetectorService({
    double sensitivity = 0.5,
    this.detectShoulderSurfers = true,
    this.staleAfter = const Duration(seconds: 3),
  }) {
    _applySensitivity(sensitivity.clamp(0.0, 1.0));
  }

  /// When true, a second face in frame protects the screen.
  bool detectShoulderSurfers;

  /// How long a sample stays trustworthy. Past this the screen re-protects,
  /// so a wedged capture loop cannot leave the screen exposed indefinitely.
  final Duration staleAfter;

  // ── Thresholds, all derived from sensitivity ─────────────────────────────
  double _maxYawDeg = 27.5;
  double _maxPitchDeg = 23.5;
  double _maxPitchDeviation = 0.30;
  double _maxRollDeg = 47.5;
  int _framesToProtect = 1;
  int _framesToReveal = 3;

  /// Below this, an eye counts as shut. Only applied when the platform
  /// actually measures eye openness.
  static const double _minEyeOpenProbability = 0.35;

  // ── State ────────────────────────────────────────────────────────────────
  int _consecutiveAttentive = 0;
  int _consecutiveInattentive = 0;

  // Fail closed: protected until proven otherwise.
  bool _screenVisible = false;
  ProtectionReason _reason = ProtectionReason.initialising;
  ProtectionReason _pendingReason = ProtectionReason.initialising;
  DateTime? _lastSampleAt;

  /// Injectable clock, so staleness is testable without real waiting.
  DateTime Function() clock = DateTime.now;

  // ── Read-only state ──────────────────────────────────────────────────────

  /// True only when it is safe to show the screen. Callers must treat this as
  /// the single source of truth and default to hiding.
  bool get isScreenVisible => _screenVisible && !_isStale;

  /// Inverse of [isScreenVisible], for readability at call sites.
  bool get isProtected => !isScreenVisible;

  ProtectionReason get reason =>
      _isStale && _screenVisible
          ? ProtectionReason.stale
          : (_screenVisible ? ProtectionReason.none : _reason);

  bool get _isStale {
    final last = _lastSampleAt;
    if (last == null) return true;
    return clock().difference(last) > staleAfter;
  }

  /// Progress toward the next state change, in [0,1]. Drives the UI meter.
  ///
  /// While protected this ramps as attentive frames accumulate, so the user can
  /// see the screen is about to unlock. While visible it stays at 1.
  double get confidence {
    if (_screenVisible && !_isStale) return 1.0;
    if (_framesToReveal <= 0) return 1.0;
    return math.min(1.0, _consecutiveAttentive / _framesToReveal);
  }

  int get framesToReveal => _framesToReveal;
  int get framesToProtect => _framesToProtect;
  double get maxYawDeg => _maxYawDeg;
  double get maxPitchDeg => _maxPitchDeg;
  double get maxPitchDeviation => _maxPitchDeviation;

  // ── Configuration ────────────────────────────────────────────────────────

  void setSensitivity(double sensitivity) {
    _applySensitivity(sensitivity.clamp(0.0, 1.0));
  }

  /// 0.0 = lenient (wide tolerance, slow to hide), 1.0 = strict (tight
  /// tolerance, hides on the first bad frame).
  void _applySensitivity(double s) {
    _maxYawDeg = 40.0 - s * 25.0; // 40° → 15°
    _maxPitchDeg = 35.0 - s * 23.0; // 35° → 12°
    _maxPitchDeviation = 0.45 - s * 0.30; // 0.45 → 0.15
    _maxRollDeg = 60.0 - s * 25.0; // 60° → 35° (head tilt is normal; be lax)

    // Hiding: strict settings react to a single bad frame.
    _framesToProtect = s >= 0.5 ? 1 : 2;
    // Revealing: always needs more evidence than hiding does.
    _framesToReveal = 2 + (s * 2).round(); // 2 → 4
  }

  /// Return to the initial, protected state.
  void reset() {
    _consecutiveAttentive = 0;
    _consecutiveInattentive = 0;
    _screenVisible = false;
    _reason = ProtectionReason.initialising;
    _pendingReason = ProtectionReason.initialising;
    _lastSampleAt = null;
  }

  // ── Observation ──────────────────────────────────────────────────────────

  /// Record a frame the detector processed successfully.
  void observe(GazeSample sample) {
    _lastSampleAt = clock();

    final ProtectionReason? problem = _evaluate(sample);
    if (problem == null) {
      _consecutiveInattentive = 0;
      _consecutiveAttentive++;
    } else {
      _consecutiveAttentive = 0;
      _consecutiveInattentive++;
      _pendingReason = problem;
    }
    _updateState();
  }

  /// Record a frame where the camera or detector failed.
  ///
  /// Distinct from [GazeSample.noFace]: we did not observe an empty room, we
  /// observed nothing at all. Both protect, but the reason shown differs.
  void observeError() {
    _lastSampleAt = clock();
    _consecutiveAttentive = 0;
    _consecutiveInattentive++;
    _pendingReason = ProtectionReason.detectorError;
    _updateState();
  }

  /// Returns the reason the sample is disqualifying, or null if it is fine.
  ProtectionReason? _evaluate(GazeSample s) {
    if (s.faceCount <= 0) return ProtectionReason.noFace;
    if (detectShoulderSurfers && s.faceCount > 1) {
      return ProtectionReason.multipleFaces;
    }

    final double? yaw = s.yawDeg;
    if (yaw != null && (!yaw.isFinite || yaw.abs() > _maxYawDeg)) {
      return ProtectionReason.lookedAway;
    }

    final double? pitch = s.pitchDeg;
    if (pitch != null && (!pitch.isFinite || pitch.abs() > _maxPitchDeg)) {
      return ProtectionReason.lookedAway;
    }

    final double? pitchDev = s.pitchDeviation;
    if (pitchDev != null &&
        (!pitchDev.isFinite || pitchDev.abs() > _maxPitchDeviation)) {
      return ProtectionReason.lookedAway;
    }

    final double? roll = s.rollDeg;
    if (roll != null && (!roll.isFinite || roll.abs() > _maxRollDeg)) {
      return ProtectionReason.lookedAway;
    }

    // Eye openness is only checked where it is measured. A platform that
    // cannot see eyelids must not be treated as seeing open eyes.
    final double? left = s.leftEyeOpen;
    final double? right = s.rightEyeOpen;
    if (left != null && right != null) {
      if (math.min(left, right) < _minEyeOpenProbability) {
        return ProtectionReason.eyesClosed;
      }
    }

    return null;
  }

  void _updateState() {
    if (_consecutiveInattentive >= _framesToProtect) {
      _screenVisible = false;
      _reason = _pendingReason;
    } else if (_consecutiveAttentive >= _framesToReveal) {
      _screenVisible = true;
      _reason = ProtectionReason.none;
    }
  }
}
