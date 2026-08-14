// The SafeScreen design system.
//
// One source of truth. These values were previously copy-pasted into three
// screens "for file independence", which is exactly how a palette drifts apart.
//
// The look is a measurement instrument, not a consumer app: paper ground, ink
// text, square corners, hairline rules, monospace for anything the machine is
// reporting, and a single accent colour that only ever means "attention".
//
// It matches the project's website deliberately — one product, one voice — and
// the light ground is what gives the blackout its force. A screen going black
// against paper reads far harder than one going black against dark grey.

import 'package:flutter/material.dart';

abstract final class C {
  static const paper = Color(0xFFE9E5DD);
  static const paperRaised = Color(0xFFF2EFE9);
  static const paperSunken = Color(0xFFE3DED4);

  static const ink = Color(0xFF16161A);
  static const inkSoft = Color(0xFF3D3B38);
  static const inkMuted = Color(0xFF6F6B63);

  static const rule = Color(0xFFC6C0B4);
  static const ruleFaint = Color(0xFFD5CFC4);

  /// Attention. Protected states, warnings, live indicators. Nothing else.
  static const signal = Color(0xFFB3350F);

  /// The screen is safe to read.
  static const clear = Color(0xFF1F6F3F);

  /// The blackout itself.
  static const black = Color(0xFF0A0A0B);
}

/// Window geometry.
///
/// Sized to the panel's content rather than picked arbitrarily, and shared so
/// the home and protection screens cannot drift into different window sizes and
/// make the window jump when you navigate between them.
abstract final class W {
  /// Natural size: fits the panel without scrolling at 100% text scale.
  static const Size panel = Size(400, 620);

  /// Below this the spec rows begin to truncate, so the window refuses to go
  /// smaller rather than letting the layout break.
  static const Size minimum = Size(340, 420);
}

/// One spacing scale. Pick from it rather than inventing a number.
abstract final class S {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 24;
  static const double x6 = 32;
  static const double x7 = 48;
}

abstract final class F {
  /// Monospace for machine-reported values, labels and controls.
  static const List<String> mono = <String>[
    'Cascadia Mono',
    'Consolas',
    'Courier New',
  ];

  /// The grotesk appears only at display size.
  static const List<String> sans = <String>[
    'Segoe UI Variable Display',
    'Segoe UI',
    'Arial',
  ];
}

abstract final class T {
  /// Small uppercase label. The left column of every readout.
  static const label = TextStyle(
    fontFamilyFallback: F.mono,
    fontSize: 11,
    height: 1.4,
    letterSpacing: 1.1,
    fontWeight: FontWeight.w500,
    color: C.inkMuted,
  );

  /// A machine-reported value.
  static const readout = TextStyle(
    fontFamilyFallback: F.mono,
    fontSize: 12.5,
    height: 1.4,
    color: C.ink,
  );

  /// The one big word: PROTECTED / VISIBLE / READY.
  static const state = TextStyle(
    fontFamilyFallback: F.sans,
    fontSize: 30,
    height: 1.0,
    letterSpacing: -1.1,
    fontWeight: FontWeight.w800,
    color: C.ink,
  );

  static const heading = TextStyle(
    fontFamilyFallback: F.sans,
    fontSize: 15,
    height: 1.2,
    letterSpacing: -0.3,
    fontWeight: FontWeight.w700,
    color: C.ink,
  );

  static const body = TextStyle(
    fontFamilyFallback: F.mono,
    fontSize: 12,
    height: 1.55,
    color: C.inkSoft,
  );

  static const button = TextStyle(
    fontFamilyFallback: F.mono,
    fontSize: 12,
    letterSpacing: 0.9,
    fontWeight: FontWeight.w600,
  );
}

/// A hairline. Used instead of card borders — the page is ruled, not boxed.
class Rule extends StatelessWidget {
  const Rule({super.key, this.faint = false});

  final bool faint;

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: faint ? C.ruleFaint : C.rule);
}

/// One row of the spec table: uppercase label, machine value.
///
/// The label column is fixed so every row in a panel aligns, but it shrinks on
/// narrow windows rather than forcing the value off the edge.
class SpecRow extends StatelessWidget {
  const SpecRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(label.toUpperCase(), style: T.label),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(
              value,
              style: T.readout.copyWith(
                color: valueColor ?? C.ink,
                fontWeight: emphasis ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A segmented progress meter, in the manner of a level indicator.
///
/// Discrete segments rather than a continuous bar because the underlying value
/// genuinely is discrete — it counts frames toward a threshold.
class SegmentMeter extends StatelessWidget {
  const SegmentMeter({
    super.key,
    required this.filled,
    required this.total,
    required this.color,
  });

  final int filled;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List<Widget>.generate(total, (int i) {
        return Expanded(
          child: Container(
            height: 6,
            margin: EdgeInsets.only(right: i == total - 1 ? 0 : 3),
            color: i < filled ? color : C.ruleFaint,
          ),
        );
      }),
    );
  }
}

/// A flat, square, monospace control. No rounded corners, no elevation.
class PanelButton extends StatelessWidget {
  const PanelButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color edge = danger ? C.signal : C.ink;
    final Color fg = primary ? C.paper : (danger ? C.signal : C.ink);
    final Color bg = primary ? C.ink : Colors.transparent;

    return SizedBox(
      width: double.infinity,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: edge),
          borderRadius: BorderRadius.zero,
        ),
        child: InkWell(
          onTap: onPressed,
          hoverColor: primary ? C.inkSoft : C.paperSunken,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: S.x2),
                ],
                Flexible(
                  child: Text(
                    label.toUpperCase(),
                    style: T.button.copyWith(color: fg),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The window's own title strip. Square, ruled, monospace.
class TitleStrip extends StatelessWidget {
  const TitleStrip({
    super.key,
    required this.title,
    this.statusColor,
    this.onBack,
    this.onMinimise,
    this.onClose,
  });

  final String title;
  final Color? statusColor;
  final VoidCallback? onBack;
  final VoidCallback? onMinimise;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              if (onBack != null)
                _StripButton(icon: Icons.arrow_back, onTap: onBack!),
              const SizedBox(width: S.x4),
              if (statusColor != null) ...[
                Container(width: 7, height: 7, color: statusColor),
                const SizedBox(width: S.x2),
              ],
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: T.label.copyWith(color: C.ink, letterSpacing: 1.6),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onMinimise != null)
                _StripButton(icon: Icons.remove, onTap: onMinimise!),
              if (onClose != null)
                _StripButton(icon: Icons.close, onTap: onClose!),
            ],
          ),
        ),
        const Rule(),
      ],
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: InkWell(
        onTap: onTap,
        hoverColor: C.paperSunken,
        child: Icon(icon, size: 15, color: C.inkMuted),
      ),
    );
  }
}
