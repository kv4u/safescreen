import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/camera_effects.dart';

void main() {
  group('CameraEffects.fromReply', () {
    test('reads both effects', () {
      final CameraEffects e = CameraEffects.fromReply(<Object?, Object?>{
        'backgroundBlur': true,
        'autoFraming': false,
      });
      expect(e.backgroundBlur, isTrue);
      expect(e.autoFraming, isFalse);
    });

    test('null stays unreported rather than becoming off', () {
      final CameraEffects e = CameraEffects.fromReply(<Object?, Object?>{
        'backgroundBlur': null,
        'autoFraming': false,
      });
      expect(e.backgroundBlur, isNull);
      expect(e.autoFraming, isFalse);
    });

    test('anything that is not a bool is unreported', () {
      final CameraEffects e = CameraEffects.fromReply(<Object?, Object?>{
        'backgroundBlur': 1,
        'autoFraming': 'on',
      });
      expect(e, CameraEffects.unknown);
    });

    test('a missing or malformed reply is unknown', () {
      expect(CameraEffects.fromReply(null), CameraEffects.unknown);
      expect(CameraEffects.fromReply('nope'), CameraEffects.unknown);
      expect(
        CameraEffects.fromReply(<Object?, Object?>{}),
        CameraEffects.unknown,
      );
    });
  });

  group('hidesOthers', () {
    test('blur hides a second person', () {
      expect(const CameraEffects(backgroundBlur: true).hidesOthers, isTrue);
    });

    test('auto framing hides a second person', () {
      expect(const CameraEffects(autoFraming: true).hidesOthers, isTrue);
    });

    test('both off is clear', () {
      expect(
        const CameraEffects(
          backgroundBlur: false,
          autoFraming: false,
        ).hidesOthers,
        isFalse,
      );
    });

    test('unreported is not assumed to be on', () {
      expect(CameraEffects.unknown.hidesOthers, isFalse);
    });
  });

  group('summary', () {
    test('unknown says so instead of claiming none', () {
      expect(CameraEffects.unknown.summary, 'Not reported');
    });

    test('reported and off', () {
      expect(
        const CameraEffects(backgroundBlur: false, autoFraming: false).summary,
        'None',
      );
    });

    test('one answer is not enough to report none', () {
      expect(
        const CameraEffects(backgroundBlur: false).summary,
        'Framing unknown',
      );
      expect(const CameraEffects(autoFraming: false).summary, 'Blur unknown');
    });

    test('names what is on', () {
      expect(
        const CameraEffects(backgroundBlur: true).summary,
        'Background blur on',
      );
      expect(const CameraEffects(autoFraming: true).summary, 'Auto framing on');
      expect(
        const CameraEffects(backgroundBlur: true, autoFraming: true).summary,
        'Blur + framing on',
      );
    });
  });
}
