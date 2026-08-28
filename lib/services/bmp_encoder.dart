// Wraps raw camera pixels in a BMP container, in memory.
//
// ── Why this exists ────────────────────────────────────────────────────────
//
// The native capture path hands back raw BGRA rows. The face detector's only
// public entry point is `detectFaces(Uint8List)`, which runs the bytes through
// `package:image`'s format-sniffing decoder — so it needs an *encoded* image,
// not a pixel buffer.
//
// BMP is the right container here precisely because it is not a compression
// format: a 54-byte header followed by the pixel rows. Encoding costs a header
// write and a row copy rather than a JPEG compress, and nothing touches the
// disk. The decoder immediately unpacks it again, which sounds wasteful and is
// still far cheaper than the JPEG encode/write/read/delete cycle it replaces.
//
// This lives in Dart rather than in the native plugin on purpose. It is the
// part of the in-memory path that can be verified — the test decodes what this
// produces with the same `package:image` decoder the detector uses, so a header
// mistake fails in CI instead of silently blinding the detector on a user's
// machine.

import 'dart:typed_data';

/// Bytes in a BITMAPFILEHEADER.
const int _fileHeaderSize = 14;

/// Bytes in a BITMAPINFOHEADER.
const int _infoHeaderSize = 40;

/// Total header size, and therefore the pixel data offset.
const int bmpHeaderSize = _fileHeaderSize + _infoHeaderSize;

/// Wraps [bgra] in an uncompressed 32-bit BMP.
///
/// [bgra] holds [height] rows of [width] BGRA pixels, each row [stride] bytes
/// long. Stride may exceed `width * 4`: Media Foundation buffers are commonly
/// padded, and a negative stride means the source is already bottom-up.
///
/// Rows are written bottom-up with a positive height — the classic layout every
/// BMP decoder handles — rather than top-down with a negative height, which is
/// legal but less uniformly supported.
///
/// Returns null rather than a malformed image when the inputs do not describe a
/// buffer that is actually there. A caller must treat null as "no frame", which
/// the detector already handles by protecting the screen.
Uint8List? encodeBgraAsBmp(
  Uint8List bgra, {
  required int width,
  required int height,
  int? stride,
}) {
  if (width <= 0 || height <= 0) return null;

  final int rowBytes = width * 4;
  final int srcStride =
      (stride == null || stride == 0) ? rowBytes : stride.abs();
  if (srcStride < rowBytes) return null;

  // A negative stride is Media Foundation's way of saying the buffer is already
  // stored bottom-up, which is the order BMP wants, so no flip is needed.
  final bool sourceIsBottomUp = stride != null && stride < 0;

  if (bgra.length < srcStride * height) return null;

  final int pixelBytes = rowBytes * height;
  final Uint8List out = Uint8List(bmpHeaderSize + pixelBytes);
  final ByteData header = ByteData.view(out.buffer, 0, bmpHeaderSize);

  // BITMAPFILEHEADER
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  header.setUint32(2, out.length, Endian.little);
  header.setUint32(6, 0, Endian.little); // reserved
  header.setUint32(10, bmpHeaderSize, Endian.little); // pixel data offset

  // BITMAPINFOHEADER
  header.setUint32(14, _infoHeaderSize, Endian.little);
  header.setInt32(18, width, Endian.little);
  header.setInt32(22, height, Endian.little); // positive: bottom-up
  header.setUint16(26, 1, Endian.little); // planes
  header.setUint16(28, 32, Endian.little); // bits per pixel
  header.setUint32(30, 0, Endian.little); // BI_RGB, no compression
  header.setUint32(34, pixelBytes, Endian.little);
  header.setUint32(38, 2835, Endian.little); // 72 DPI, x
  header.setUint32(42, 2835, Endian.little); // 72 DPI, y
  header.setUint32(46, 0, Endian.little); // palette entries
  header.setUint32(50, 0, Endian.little); // important colours

  for (int row = 0; row < height; row++) {
    // Destination row 0 is the bottom of the image.
    final int srcRow = sourceIsBottomUp ? row : height - 1 - row;
    final int srcStart = srcRow * srcStride;
    final int dstStart = bmpHeaderSize + row * rowBytes;
    out.setRange(dstStart, dstStart + rowBytes, bgra, srcStart);
  }

  return out;
}
