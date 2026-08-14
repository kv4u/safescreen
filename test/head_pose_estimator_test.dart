import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/head_pose_estimator.dart';

/// Builds a synthetic face.
///
/// Tragions sit at y=0 spanning [0, span]; the eyes sit symmetrically inside
/// them; the nose sits [noseX] across and [noseDrop] below. Rotating by [rollDeg]
/// spins the whole arrangement about the tragion midpoint, which is what a real
/// head tilt does to the keypoints.
FaceKeypoints buildFace({
  double span = 100,
  required double noseX,
  double noseDrop = 30,
  double rollDeg = 0,
}) {
  final double cx = span / 2;
  final double r = rollDeg * math.pi / 180;
  final double cosR = math.cos(r);
  final double sinR = math.sin(r);

  Pt rot(double x, double y) {
    final double dx = x - cx;
    final double dy = y;
    return Pt(cx + dx * cosR - dy * sinR, dx * sinR + dy * cosR);
  }

  return FaceKeypoints(
    rightTragion: rot(0, 0),
    leftTragion: rot(span, 0),
    rightEye: rot(span * 0.3, 0),
    leftEye: rot(span * 0.7, 0),
    noseTip: rot(noseX, noseDrop),
  );
}

void main() {
  group('estimateHeadPose', () {
    test('a symmetric frontal face reads as zero yaw and zero roll', () {
      final HeadPose? pose = estimateHeadPose(buildFace(noseX: 50));

      expect(pose, isNotNull);
      expect(pose!.yaw, closeTo(0, 1e-6));
      expect(pose.roll, closeTo(0, 1e-6));
    });

    test('nose displaced toward a tragion yields the modelled yaw', () {
      // t = 0.75 → tan(yaw) = (0.75 - 0.5) * 2 = 0.5 → yaw = atan(0.5).
      final double expected = math.atan(0.5) * 180 / math.pi;

      expect(
        estimateHeadPose(buildFace(noseX: 75))!.yaw,
        closeTo(expected, 1e-6),
      );
      expect(
        estimateHeadPose(buildFace(noseX: 25))!.yaw,
        closeTo(-expected, 1e-6),
      );
    });

    test('yaw grows monotonically as the head turns further', () {
      final List<double> yaws =
          <double>[
            50,
            60,
            70,
            80,
          ].map((x) => estimateHeadPose(buildFace(noseX: x))!.yaw).toList();

      for (int i = 1; i < yaws.length; i++) {
        expect(yaws[i], greaterThan(yaws[i - 1]));
      }
    });

    test('a tilted head reports roll without contaminating yaw', () {
      final HeadPose? pose = estimateHeadPose(
        buildFace(noseX: 50, rollDeg: 30),
      );

      expect(pose, isNotNull);
      expect(pose!.roll, closeTo(30, 1e-6));
      // The face is still pointed at the camera, so yaw must stay ~0 even
      // though every keypoint moved.
      expect(pose.yaw, closeTo(0, 1e-6));
    });

    test('pitchRatio is measured perpendicular to the eye line, so roll '
        'does not change it', () {
      final HeadPose upright = estimateHeadPose(buildFace(noseX: 50))!;
      final HeadPose tilted =
          estimateHeadPose(buildFace(noseX: 50, rollDeg: 25))!;

      expect(tilted.pitchRatio, closeTo(upright.pitchRatio, 1e-6));
    });

    test('pitchRatio grows as the nose drops further below the eye line', () {
      final HeadPose shallow =
          estimateHeadPose(buildFace(noseX: 50, noseDrop: 20))!;
      final HeadPose deep =
          estimateHeadPose(buildFace(noseX: 50, noseDrop: 40))!;

      expect(deep.pitchRatio, greaterThan(shallow.pitchRatio));
    });

    test('roll folds into [-90, 90] rather than reporting a flipped angle', () {
      final HeadPose? pose = estimateHeadPose(
        buildFace(noseX: 50, rollDeg: 170),
      );

      expect(pose!.roll.abs(), lessThanOrEqualTo(90));
      expect(pose.roll, closeTo(-10, 1e-6));
    });

    test('degenerate geometry returns null instead of a noisy reading', () {
      const Pt origin = Pt(0, 0);
      final HeadPose? coincident = estimateHeadPose(
        const FaceKeypoints(
          leftEye: origin,
          rightEye: origin,
          noseTip: origin,
          leftTragion: origin,
          rightTragion: origin,
        ),
      );

      expect(coincident, isNull);
    });

    test('non-finite coordinates return null', () {
      final HeadPose? pose = estimateHeadPose(
        const FaceKeypoints(
          leftEye: Pt(70, 0),
          rightEye: Pt(30, 0),
          noseTip: Pt(double.nan, 30),
          leftTragion: Pt(100, 0),
          rightTragion: Pt(0, 0),
        ),
      );

      expect(pose, isNull);
    });
  });

  group('PitchBaseline', () {
    test('falls back to the nominal value before any samples arrive', () {
      final PitchBaseline baseline = PitchBaseline(nominal: 0.62);

      expect(baseline.isCalibrated, isFalse);
      expect(baseline.value, 0.62);
    });

    test('converges toward the observed neutral pose', () {
      final PitchBaseline baseline = PitchBaseline(
        smoothing: 0.2,
        samplesToCalibrate: 5,
      );
      for (int i = 0; i < 40; i++) {
        baseline.observe(0.80);
      }

      expect(baseline.isCalibrated, isTrue);
      expect(baseline.value, closeTo(0.80, 0.01));
      expect(baseline.deviation(0.80), closeTo(0, 0.01));
    });

    test('rejects absurd readings so one bad frame cannot poison it', () {
      final PitchBaseline baseline = PitchBaseline(smoothing: 0.5);
      baseline.observe(0.70);
      final double before = baseline.value;

      baseline.observe(50.0);
      baseline.observe(double.nan);

      expect(baseline.value, before);
      expect(baseline.sampleCount, 1);
    });

    test('reset returns it to the uncalibrated nominal', () {
      final PitchBaseline baseline = PitchBaseline(nominal: 0.62);
      for (int i = 0; i < 30; i++) {
        baseline.observe(0.9);
      }
      baseline.reset();

      expect(baseline.isCalibrated, isFalse);
      expect(baseline.value, 0.62);
    });
  });
}
