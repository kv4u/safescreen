// Geometry for the multi-monitor blackout.
//
// Pure Dart on purpose. This arithmetic decides whether a monitor stays exposed
// while the user is away, which makes it exactly the kind of code that should be
// unit-testable rather than only observable by dragging windows around a desk
// with three monitors on it.
//
// The problem it solves: `screen_retriever` reports each monitor's geometry
// already divided by *that monitor's own* scale factor, while
// `window_manager.setBounds` multiplies whatever it is given by *the window's*
// device pixel ratio. Unioning the reported values directly therefore mixes
// coordinate spaces, and on a desk with mixed scale factors the resulting cover
// is wrong — potentially by hundreds of pixels, leaving part of a screen
// readable.
//
// The fix is to convert every display back to physical pixels, union there
// (physical pixels are the one space all monitors genuinely share), and convert
// once into the window's space at the end.

import 'dart:math' as math;

/// One display, as reported by `screen_retriever`.
///
/// [left], [top], [width] and [height] are that display's own logical pixels —
/// i.e. already divided by [scaleFactor].
class DisplayBounds {
  const DisplayBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.scaleFactor,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final double scaleFactor;

  @override
  String toString() =>
      'DisplayBounds($left, $top, ${width}x$height @${scaleFactor}x)';
}

/// A rectangle in the window's logical coordinate space, ready to hand to
/// `window_manager.setBounds`.
class CoverRect {
  const CoverRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  @override
  String toString() => 'CoverRect($left, $top, ${width}x$height)';
}

/// Rectangle covering every display, expressed for [windowScaleFactor].
///
/// Returns null when there is nothing trustworthy to return — no displays, a
/// nonsensical window scale, or every display unusable. Callers must treat null
/// as "fall back to something known-safe" rather than as an empty cover, since
/// a missing cover leaves the screen readable.
CoverRect? computeCoverRect(
  List<DisplayBounds> displays, {
  required double windowScaleFactor,
}) {
  if (displays.isEmpty) return null;
  if (!windowScaleFactor.isFinite || windowScaleFactor <= 0) return null;

  double? minX, minY, maxX, maxY;

  for (final DisplayBounds d in displays) {
    final double s = d.scaleFactor;
    if (!s.isFinite || s <= 0) continue;
    if (!d.left.isFinite || !d.top.isFinite) continue;
    if (!d.width.isFinite || !d.height.isFinite) continue;
    if (d.width <= 0 || d.height <= 0) continue;

    // Back to physical pixels: the only space every monitor shares.
    final double left = d.left * s;
    final double top = d.top * s;
    final double right = (d.left + d.width) * s;
    final double bottom = (d.top + d.height) * s;

    minX = minX == null ? left : math.min(minX, left);
    minY = minY == null ? top : math.min(minY, top);
    maxX = maxX == null ? right : math.max(maxX, right);
    maxY = maxY == null ? bottom : math.max(maxY, bottom);
  }

  if (minX == null || minY == null || maxX == null || maxY == null) return null;

  final double width = maxX - minX;
  final double height = maxY - minY;
  if (width <= 0 || height <= 0) return null;

  // Into the window's space. setBounds multiplies by this same ratio natively.
  return CoverRect(
    left: minX / windowScaleFactor,
    top: minY / windowScaleFactor,
    width: width / windowScaleFactor,
    height: height / windowScaleFactor,
  );
}
