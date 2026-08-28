import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:safe_screen/services/bmp_encoder.dart';

/// Builds a BGRA buffer, optionally padded, filled by a per-pixel colour
/// function so that orientation errors are detectable rather than invisible.
Uint8List buildBgra({
  required int width,
  required int height,
  int extraStride = 0,
  required List<int> Function(int x, int y) colour,
}) {
  final int stride = width * 4 + extraStride;
  final Uint8List buf = Uint8List(stride * height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final List<int> bgr = colour(x, y);
      final int i = y * stride + x * 4;
      buf[i] = bgr[2]; // B
      buf[i + 1] = bgr[1]; // G
      buf[i + 2] = bgr[0]; // R
      buf[i + 3] = 255; // A
    }
  }
  return buf;
}

void main() {
  group('encodeBgraAsBmp', () {
    test('produces something package:image actually decodes', () {
      // This is the point of the test: the detector's only entry decodes with
      // package:image, so a header mistake here would blind it silently.
      final Uint8List bgra = buildBgra(
        width: 8,
        height: 4,
        colour: (int x, int y) => <int>[10, 20, 30],
      );

      final Uint8List? bmp = encodeBgraAsBmp(bgra, width: 8, height: 4);
      expect(bmp, isNotNull);

      final img.Image? decoded = img.decodeImage(bmp!);
      expect(decoded, isNotNull, reason: 'package:image must decode this');
      expect(decoded!.width, 8);
      expect(decoded.height, 4);
    });

    test('colours survive the round trip', () {
      final Uint8List bgra = buildBgra(
        width: 2,
        height: 2,
        colour: (int x, int y) => <int>[200, 100, 50],
      );

      final img.Image decoded =
          img.decodeImage(encodeBgraAsBmp(bgra, width: 2, height: 2)!)!;
      final img.Pixel p = decoded.getPixel(0, 0);

      expect(p.r, 200);
      expect(p.g, 100);
      expect(p.b, 50);
    });

    test('the image is not written upside down', () {
      // BMP stores rows bottom-up. Getting the flip wrong would leave the
      // detector looking at a vertically mirrored face, which still detects
      // *something* — so this must be asserted rather than eyeballed.
      final Uint8List bgra = buildBgra(
        width: 1,
        height: 2,
        // Top row red, bottom row blue.
        colour: (int x, int y) => y == 0 ? <int>[255, 0, 0] : <int>[0, 0, 255],
      );

      final img.Image decoded =
          img.decodeImage(encodeBgraAsBmp(bgra, width: 1, height: 2)!)!;

      expect(decoded.getPixel(0, 0).r, 255, reason: 'top row should be red');
      expect(
        decoded.getPixel(0, 1).b,
        255,
        reason: 'bottom row should be blue',
      );
    });

    test('padded strides are handled', () {
      // Media Foundation buffers are commonly padded past width * 4.
      final Uint8List bgra = buildBgra(
        width: 3,
        height: 2,
        extraStride: 16,
        colour: (int x, int y) => <int>[x * 10, y * 10, 5],
      );

      final img.Image decoded =
          img.decodeImage(
            encodeBgraAsBmp(bgra, width: 3, height: 2, stride: 3 * 4 + 16)!,
          )!;

      expect(decoded.width, 3);
      expect(decoded.getPixel(2, 0).r, 20);
      expect(decoded.getPixel(0, 1).g, 10);
    });

    test('a negative stride means the source is already bottom-up', () {
      final Uint8List bgra = buildBgra(
        width: 1,
        height: 2,
        colour: (int x, int y) => y == 0 ? <int>[255, 0, 0] : <int>[0, 0, 255],
      );

      final img.Image decoded =
          img.decodeImage(
            encodeBgraAsBmp(bgra, width: 1, height: 2, stride: -4)!,
          )!;

      // No flip applied, so what was row 0 in the buffer is now the bottom.
      expect(decoded.getPixel(0, 1).r, 255);
    });

    test('the header is the expected size and pixel offset', () {
      final Uint8List bmp =
          encodeBgraAsBmp(
            buildBgra(width: 2, height: 2, colour: (_, _) => <int>[0, 0, 0]),
            width: 2,
            height: 2,
          )!;

      expect(bmp[0], 0x42); // 'B'
      expect(bmp[1], 0x4D); // 'M'
      expect(bmpHeaderSize, 54);
      final ByteData d = ByteData.view(bmp.buffer);
      expect(d.getUint32(10, Endian.little), 54, reason: 'pixel offset');
      expect(d.getUint32(30, Endian.little), 0, reason: 'BI_RGB');
      expect(d.getUint16(28, Endian.little), 32, reason: 'bits per pixel');
      expect(bmp.length, 54 + 2 * 2 * 4);
    });

    group('refuses to produce a malformed image', () {
      test('zero or negative dimensions', () {
        final Uint8List any = Uint8List(64);
        expect(encodeBgraAsBmp(any, width: 0, height: 4), isNull);
        expect(encodeBgraAsBmp(any, width: 4, height: 0), isNull);
        expect(encodeBgraAsBmp(any, width: -4, height: 4), isNull);
      });

      test('a stride narrower than the row', () {
        expect(
          encodeBgraAsBmp(Uint8List(64), width: 8, height: 2, stride: 8),
          isNull,
        );
      });

      test('a buffer shorter than the frame it claims to hold', () {
        expect(
          encodeBgraAsBmp(Uint8List(16), width: 8, height: 4),
          isNull,
          reason: 'a truncated frame must be refused, not read out of bounds',
        );
      });
    });
  });
}
