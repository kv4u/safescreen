import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/camera_selection.dart';

CameraOption cam(String name, {bool front = true}) =>
    CameraOption(name: name, isFront: front);

void main() {
  group('parseCameraName', () {
    test('splits the plugin name into display name and device path', () {
      final CameraName n = parseCameraName(
        r'Integrated Webcam <\?\usb#vid_0c45&pid_6a10&mi_00#6&2a1f#{e5323777-f976-4f5b-9b55-b94699c46e44}\global>',
      );

      expect(n.display, 'Integrated Webcam');
      expect(
        n.deviceId,
        r'\?\usb#vid_0c45&pid_6a10&mi_00#6&2a1f#{e5323777-f976-4f5b-9b55-b94699c46e44}\global',
      );
    });

    test('a plain name is left alone', () {
      final CameraName n = parseCameraName('HD Pro Webcam C920');

      expect(n.display, 'HD Pro Webcam C920');
      expect(n.deviceId, isNull);
    });

    test('a name that is only a bracketed path is not emptied', () {
      expect(parseCameraName(r'<\?\usb#x>').display, r'<\?\usb#x>');
    });

    test('surrounding whitespace is trimmed', () {
      final CameraName n = parseCameraName('  Surface Camera Front <id-1>  ');

      expect(n.display, 'Surface Camera Front');
      expect(n.deviceId, 'id-1');
    });
  });

  group('CameraOption.fromRaw', () {
    test('keeps the device path for opening the exact camera', () {
      final CameraOption o = CameraOption.fromRaw(
        r'Logitech BRIO <\?\usb#vid_046d&pid_085e#abc\global>',
        isFront: true,
      );

      expect(o.name, 'Logitech BRIO');
      expect(o.deviceId, r'\?\usb#vid_046d&pid_085e#abc\global');
    });

    test('the virtual-camera check sees only the display name', () {
      // A marker inside the device path must not flag a real webcam.
      final CameraChoice? c = chooseCamera(<CameraOption>[
        CameraOption.fromRaw(
          r'Integrated Webcam <\?\root#vcam_driver#0000\global>',
          isFront: true,
        ),
      ]);

      expect(c!.isVirtual, isFalse);
    });

    test('a virtual camera is still recognised by its display name', () {
      final CameraChoice? c = chooseCamera(<CameraOption>[
        CameraOption.fromRaw(
          r'NVIDIA Broadcast <\?\root#nvbroadcast#0000\global>',
          isFront: true,
        ),
        CameraOption.fromRaw(
          r'Integrated Webcam <\?\usb#vid_0c45#1\global>',
          isFront: true,
        ),
      ]);

      expect(c!.option.name, 'Integrated Webcam');
      expect(c.option.deviceId, r'\?\usb#vid_0c45#1\global');
    });
  });

  group('looksLikeVirtualCamera', () {
    test('recognises the common effects and virtual camera software', () {
      for (final String name in <String>[
        'NVIDIA Broadcast',
        'OBS Virtual Camera',
        'XSplit VCam',
        'ManyCam Virtual Webcam',
        'Snap Camera',
        'DroidCam Source 3',
        'Reincubate Camo',
        'Zoom Virtual Camera',
      ]) {
        expect(
          looksLikeVirtualCamera(name),
          isTrue,
          reason: '$name should be treated as virtual',
        );
      }
    });

    test('does not flag ordinary webcams', () {
      for (final String name in <String>[
        'Integrated Webcam',
        'HD Pro Webcam C920',
        'Surface Camera Front',
        'USB2.0 HD UVC WebCam',
        'Logitech BRIO',
        'HP TrueVision HD Camera',
      ]) {
        expect(
          looksLikeVirtualCamera(name),
          isFalse,
          reason: '$name is hardware and must not be skipped',
        );
      }
    });

    test('matching ignores case', () {
      expect(looksLikeVirtualCamera('nvidia broadcast'), isTrue);
      expect(looksLikeVirtualCamera('NVIDIA BROADCAST'), isTrue);
    });
  });

  group('chooseCamera', () {
    test('prefers the physical camera over a virtual one listed first', () {
      // The reported failure: NVIDIA Broadcast enumerates first, so the old
      // "first front camera" rule handed the app a blurred background and
      // shoulder-surfer detection silently stopped working.
      final CameraChoice? c = chooseCamera(<CameraOption>[
        cam('NVIDIA Broadcast'),
        cam('Integrated Webcam'),
      ]);

      expect(c!.option.name, 'Integrated Webcam');
      expect(c.isVirtual, isFalse);
      expect(c.index, 1);
    });

    test('prefers a front-facing physical camera over a rear one', () {
      final CameraChoice? c = chooseCamera(<CameraOption>[
        cam('Back Camera', front: false),
        cam('Integrated Webcam'),
      ]);

      expect(c!.option.name, 'Integrated Webcam');
    });

    test(
      'falls back to a non-front physical camera when no front one exists',
      () {
        final CameraChoice? c = chooseCamera(<CameraOption>[
          cam('NVIDIA Broadcast'),
          cam('External USB Camera', front: false),
        ]);

        expect(c!.option.name, 'External USB Camera');
        expect(c.isVirtual, isFalse);
      },
    );

    test('uses a virtual camera when it is the only option, and flags it', () {
      final CameraChoice? c = chooseCamera(<CameraOption>[
        cam('NVIDIA Broadcast'),
      ]);

      expect(c!.option.name, 'NVIDIA Broadcast');
      expect(
        c.isVirtual,
        isTrue,
        reason: 'the caller must be able to warn the user',
      );
    });

    test('an ordinary single webcam is chosen and not flagged', () {
      final CameraChoice? c = chooseCamera(<CameraOption>[
        cam('Integrated Webcam'),
      ]);

      expect(c!.isVirtual, isFalse);
      expect(c.index, 0);
    });

    test('an empty list returns null', () {
      expect(chooseCamera(const <CameraOption>[]), isNull);
    });

    test('picks the first physical camera when several are present', () {
      final CameraChoice? c = chooseCamera(<CameraOption>[
        cam('OBS Virtual Camera'),
        cam('Integrated Webcam'),
        cam('Logitech BRIO'),
      ]);

      expect(c!.option.name, 'Integrated Webcam');
    });
  });
}
