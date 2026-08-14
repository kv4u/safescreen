import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/gaze_detector_service.dart';

/// A sample representing an attentive user: one face, squarely on-axis.
const GazeSample attentive = GazeSample(
  faceCount: 1,
  yawDeg: 0,
  pitchDeg: 0,
  rollDeg: 0,
  leftEyeOpen: 0.9,
  rightEyeOpen: 0.9,
);

/// Feeds [n] copies of [sample].
void feed(GazeDetectorService d, GazeSample sample, int n) {
  for (int i = 0; i < n; i++) {
    d.observe(sample);
  }
}

/// Drives the detector into the visible state and asserts it got there.
void reveal(GazeDetectorService d) {
  feed(d, attentive, d.framesToReveal);
  expect(d.isScreenVisible, isTrue, reason: 'setup: expected screen revealed');
}

void main() {
  group('fail-closed behaviour', () {
    test('starts protected before any evidence arrives', () {
      final GazeDetectorService d = GazeDetectorService();

      expect(d.isScreenVisible, isFalse);
      expect(d.isProtected, isTrue);
      expect(d.reason, ProtectionReason.initialising);
    });

    test('a single attentive frame is not enough to reveal the screen', () {
      final GazeDetectorService d = GazeDetectorService();
      d.observe(attentive);

      expect(d.isScreenVisible, isFalse);
    });

    test('reveals only after framesToReveal consecutive attentive frames', () {
      final GazeDetectorService d = GazeDetectorService();

      feed(d, attentive, d.framesToReveal - 1);
      expect(d.isScreenVisible, isFalse);

      d.observe(attentive);
      expect(d.isScreenVisible, isTrue);
      expect(d.reason, ProtectionReason.none);
    });

    test('an interrupted run of attentive frames restarts the count', () {
      final GazeDetectorService d = GazeDetectorService();

      feed(d, attentive, d.framesToReveal - 1);
      d.observe(const GazeSample.noFace());
      feed(d, attentive, d.framesToReveal - 1);

      expect(d.isScreenVisible, isFalse);
    });

    test('reset returns to the protected initial state', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);

      d.reset();

      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.initialising);
    });
  });

  group('asymmetric hysteresis', () {
    test('hiding takes fewer frames than revealing', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);

      expect(d.framesToProtect, lessThan(d.framesToReveal));
    });

    test('one disqualifying frame hides the screen at default sensitivity', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.75);
      reveal(d);

      d.observe(const GazeSample.noFace());

      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.noFace);
    });

    test('lenient settings tolerate a single dropped frame', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.0);
      reveal(d);

      expect(d.framesToProtect, 2);
      d.observe(const GazeSample.noFace());
      expect(d.isScreenVisible, isTrue, reason: 'one dropped frame tolerated');

      d.observe(const GazeSample.noFace());
      expect(d.isScreenVisible, isFalse);
    });
  });

  group('disqualifying conditions', () {
    test('no face reports noFace', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);
      d.observe(const GazeSample.noFace());

      expect(d.reason, ProtectionReason.noFace);
    });

    test('yaw beyond the threshold reports lookedAway', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      reveal(d);
      d.observe(GazeSample(faceCount: 1, yawDeg: d.maxYawDeg + 5));

      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.lookedAway);
    });

    test('yaw just inside the threshold is still attentive', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      reveal(d);
      d.observe(GazeSample(faceCount: 1, yawDeg: d.maxYawDeg - 1));

      expect(d.isScreenVisible, isTrue);
    });

    test('pitch deviation beyond the threshold reports lookedAway', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.5);
      reveal(d);
      d.observe(
        GazeSample(
          faceCount: 1,
          yawDeg: 0,
          pitchDeviation: d.maxPitchDeviation + 0.1,
        ),
      );

      expect(d.reason, ProtectionReason.lookedAway);
    });

    test('closed eyes report eyesClosed', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);
      d.observe(
        const GazeSample(
          faceCount: 1,
          yawDeg: 0,
          leftEyeOpen: 0.02,
          rightEyeOpen: 0.02,
        ),
      );

      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.eyesClosed);
    });

    test('a NaN angle is treated as disqualifying, not as zero', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);
      d.observe(const GazeSample(faceCount: 1, yawDeg: double.nan));

      expect(d.isScreenVisible, isFalse);
    });

    test('unmeasured signals are skipped rather than assumed good', () {
      // The Windows path supplies no eye-open probabilities at all. A sample
      // with nulls there must still be able to reveal the screen.
      final GazeDetectorService d = GazeDetectorService();
      feed(
        d,
        const GazeSample(faceCount: 1, yawDeg: 0, rollDeg: 0),
        d.framesToReveal,
      );

      expect(d.isScreenVisible, isTrue);
    });
  });

  group('shoulder-surfer detection', () {
    test('a second face protects the screen when enabled', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);
      d.observe(const GazeSample(faceCount: 2, yawDeg: 0));

      expect(d.isScreenVisible, isFalse);
      expect(d.reason, ProtectionReason.multipleFaces);
    });

    test('a second face is ignored when disabled', () {
      final GazeDetectorService d = GazeDetectorService(
        detectShoulderSurfers: false,
      );
      reveal(d);
      d.observe(const GazeSample(faceCount: 2, yawDeg: 0));

      expect(d.isScreenVisible, isTrue);
    });

    test('the setting can be toggled at runtime', () {
      final GazeDetectorService d = GazeDetectorService(
        detectShoulderSurfers: false,
      );
      reveal(d);

      d.detectShoulderSurfers = true;
      d.observe(const GazeSample(faceCount: 2, yawDeg: 0));

      expect(d.isScreenVisible, isFalse);
    });
  });

  group('detector failure and staleness', () {
    test(
      'a detector error protects and is distinguished from an empty room',
      () {
        final GazeDetectorService d = GazeDetectorService();
        reveal(d);
        d.observeError();

        expect(d.isScreenVisible, isFalse);
        expect(d.reason, ProtectionReason.detectorError);
      },
    );

    test('the screen re-protects when samples stop arriving', () {
      DateTime now = DateTime(2026, 1, 1, 12);
      final GazeDetectorService d = GazeDetectorService(
        staleAfter: const Duration(seconds: 3),
      )..clock = () => now;

      reveal(d);

      now = now.add(const Duration(seconds: 2));
      expect(d.isScreenVisible, isTrue, reason: 'still fresh');

      now = now.add(const Duration(seconds: 2));
      expect(d.isScreenVisible, isFalse, reason: 'sample went stale');
      expect(d.reason, ProtectionReason.stale);
    });

    test('a fresh sample clears staleness', () {
      DateTime now = DateTime(2026, 1, 1, 12);
      final GazeDetectorService d = GazeDetectorService(
        staleAfter: const Duration(seconds: 3),
      )..clock = () => now;

      reveal(d);
      now = now.add(const Duration(seconds: 10));
      expect(d.isScreenVisible, isFalse);

      d.observe(attentive);
      expect(d.isScreenVisible, isTrue);
    });
  });

  group('sensitivity', () {
    test('stricter settings narrow the angular tolerance', () {
      final GazeDetectorService lenient = GazeDetectorService(sensitivity: 0.0);
      final GazeDetectorService strict = GazeDetectorService(sensitivity: 1.0);

      expect(strict.maxYawDeg, lessThan(lenient.maxYawDeg));
      expect(strict.maxPitchDeg, lessThan(lenient.maxPitchDeg));
      expect(strict.maxPitchDeviation, lessThan(lenient.maxPitchDeviation));
    });

    test('out-of-range values are clamped rather than rejected', () {
      final GazeDetectorService low = GazeDetectorService(sensitivity: -5);
      final GazeDetectorService high = GazeDetectorService(sensitivity: 99);

      expect(low.maxYawDeg, GazeDetectorService(sensitivity: 0).maxYawDeg);
      expect(high.maxYawDeg, GazeDetectorService(sensitivity: 1).maxYawDeg);
    });

    test('setSensitivity takes effect on later samples', () {
      final GazeDetectorService d = GazeDetectorService(sensitivity: 0.0);
      reveal(d);

      // A 20° turn is within the lenient tolerance...
      d.observe(const GazeSample(faceCount: 1, yawDeg: 20));
      expect(d.isScreenVisible, isTrue);

      // ...but not the strict one.
      d.setSensitivity(1.0);
      d.observe(const GazeSample(faceCount: 1, yawDeg: 20));
      expect(d.isScreenVisible, isFalse);
    });

    test(
      'hiding never needs more frames than revealing, at any sensitivity',
      () {
        for (double s = 0; s <= 1.0001; s += 0.1) {
          final GazeDetectorService d = GazeDetectorService(sensitivity: s);
          expect(
            d.framesToProtect,
            lessThanOrEqualTo(d.framesToReveal),
            reason: 'sensitivity $s must not reveal faster than it hides',
          );
        }
      },
    );
  });

  group('confidence', () {
    test('is zero while protected with no attentive frames', () {
      expect(GazeDetectorService().confidence, 0);
    });

    test('ramps toward 1 as attentive frames accumulate', () {
      final GazeDetectorService d = GazeDetectorService();
      final double start = d.confidence;
      d.observe(attentive);

      expect(d.confidence, greaterThan(start));
    });

    test('is 1 once the screen is visible', () {
      final GazeDetectorService d = GazeDetectorService();
      reveal(d);

      expect(d.confidence, 1.0);
    });
  });
}
