import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/display_geometry.dart';

/// A display described the way screen_retriever reports one: physical geometry
/// already divided by its own scale factor.
DisplayBounds fromPhysical({
  required double physLeft,
  required double physTop,
  required double physWidth,
  required double physHeight,
  double scale = 1.0,
}) {
  return DisplayBounds(
    left: physLeft / scale,
    top: physTop / scale,
    width: physWidth / scale,
    height: physHeight / scale,
    scaleFactor: scale,
  );
}

void main() {
  group('computeCoverRect', () {
    test('a single 100% display passes straight through', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
      ], windowScaleFactor: 1.0);

      expect(r, isNotNull);
      expect(r!.left, 0);
      expect(r.top, 0);
      expect(r.width, 1920);
      expect(r.height, 1080);
    });

    test('two displays at the same scale union side by side', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
        fromPhysical(
          physLeft: 1920,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
      ], windowScaleFactor: 1.0);

      expect(r!.width, 3840);
      expect(r.height, 1080);
    });

    test('mixed scale factors still cover the full desktop', () {
      // 1920x1080 at 100%, plus 2560x1440 at 150% sitting to its right.
      final List<DisplayBounds> displays = <DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
        fromPhysical(
          physLeft: 1920,
          physTop: 0,
          physWidth: 2560,
          physHeight: 1440,
          scale: 1.5,
        ),
      ];

      final CoverRect? r = computeCoverRect(displays, windowScaleFactor: 1.0);

      // The desktop spans 1920 + 2560 = 4480 physical pixels across.
      expect(r!.left, 0);
      expect(r.width, closeTo(4480, 0.01));
      expect(r.height, closeTo(1440, 0.01));
    });

    test('unioning the reported values directly would under-cover, which is '
        'the bug this exists to prevent', () {
      final List<DisplayBounds> displays = <DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
        fromPhysical(
          physLeft: 1920,
          physTop: 0,
          physWidth: 2560,
          physHeight: 1440,
          scale: 1.5,
        ),
      ];

      // What the naive approach produced: union the logical values as-is.
      double naiveRight = 0;
      for (final DisplayBounds d in displays) {
        naiveRight =
            d.left + d.width > naiveRight ? d.left + d.width : naiveRight;
      }

      final CoverRect r = computeCoverRect(displays, windowScaleFactor: 1.0)!;

      expect(naiveRight, lessThan(r.right));
      // Roughly 1500 physical pixels of the second monitor left uncovered.
      expect(r.right - naiveRight, greaterThan(1000));
    });

    test('a display left of the primary yields a negative origin', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        fromPhysical(
          physLeft: -1920,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
      ], windowScaleFactor: 1.0);

      expect(r!.left, -1920);
      expect(r.width, 3840);
    });

    test('vertically stacked displays union downward', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
        fromPhysical(
          physLeft: 0,
          physTop: 1080,
          physWidth: 1920,
          physHeight: 1080,
        ),
      ], windowScaleFactor: 1.0);

      expect(r!.height, 2160);
      expect(r.width, 1920);
    });

    test('the result is expressed in the window scale factor', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 3840,
          physHeight: 2160,
          scale: 2.0,
        ),
      ], windowScaleFactor: 2.0);

      // setBounds multiplies by 2 again natively, landing back on 3840x2160.
      expect(r!.width, 1920);
      expect(r.height, 1080);
    });

    test('no displays returns null rather than an empty cover', () {
      expect(
        computeCoverRect(const <DisplayBounds>[], windowScaleFactor: 1.0),
        isNull,
      );
    });

    test('a nonsensical window scale returns null', () {
      final List<DisplayBounds> one = <DisplayBounds>[
        fromPhysical(
          physLeft: 0,
          physTop: 0,
          physWidth: 1920,
          physHeight: 1080,
        ),
      ];

      expect(computeCoverRect(one, windowScaleFactor: 0), isNull);
      expect(computeCoverRect(one, windowScaleFactor: -1), isNull);
      expect(computeCoverRect(one, windowScaleFactor: double.nan), isNull);
    });

    test('unusable displays are skipped, and usable ones still count', () {
      final CoverRect? r = computeCoverRect(<DisplayBounds>[
        const DisplayBounds(
          left: 0,
          top: 0,
          width: double.nan,
          height: 1080,
          scaleFactor: 1,
        ),
        const DisplayBounds(
          left: 0,
          top: 0,
          width: 0,
          height: 0,
          scaleFactor: 1,
        ),
        const DisplayBounds(
          left: 0,
          top: 0,
          width: 1920,
          height: 1080,
          scaleFactor: 0,
        ),
        fromPhysical(physLeft: 0, physTop: 0, physWidth: 1280, physHeight: 720),
      ], windowScaleFactor: 1.0);

      expect(r, isNotNull);
      expect(r!.width, 1280);
      expect(r.height, 720);
    });

    test('every display being unusable returns null', () {
      expect(
        computeCoverRect(<DisplayBounds>[
          const DisplayBounds(
            left: 0,
            top: 0,
            width: 0,
            height: 0,
            scaleFactor: 1,
          ),
        ], windowScaleFactor: 1.0),
        isNull,
      );
    });
  });
}
