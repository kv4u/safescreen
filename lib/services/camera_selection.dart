// Choosing which camera to watch through.
//
// Pure Dart, no plugin imports, because this decision has a security
// consequence and should be testable.
//
// ── Why this file exists ───────────────────────────────────────────────────
//
// Virtual camera software — NVIDIA Broadcast, OBS, XSplit VCam and friends —
// presents itself as an ordinary webcam and applies effects before any
// application sees a frame. Background blur and background replacement are the
// common ones, and both are catastrophic here: a person standing behind the
// user is *part of the background*. Blurred or replaced, they never reach the
// face detector, so shoulder-surfer detection reports "watching" and quietly
// detects nothing.
//
// A silent defeat is worse than an absent feature. Someone who believes the
// screen will hide when a colleague walks up behaves differently from someone
// who knows it will not.
//
// So SafeScreen prefers a physical camera when one exists, and when it has to
// use a virtual one it says so rather than pretending.
//
// This does NOT cover Windows Studio Effects, which applies the same class of
// processing inside the OS camera pipeline on Copilot+ hardware. That affects
// the physical device itself and is invisible from here — see SECURITY.md.

/// A camera as the platform enumerated it.
class CameraOption {
  const CameraOption({required this.name, required this.isFront});

  final String name;
  final bool isFront;

  @override
  String toString() => 'CameraOption($name, front: $isFront)';
}

/// The camera to use, and whether it is one that processes frames first.
class CameraChoice {
  const CameraChoice({
    required this.index,
    required this.option,
    required this.isVirtual,
  });

  /// Index into the list that was passed in.
  final int index;
  final CameraOption option;

  /// True when the chosen device looks like virtual-camera software rather
  /// than hardware. Callers should surface this, not hide it.
  final bool isVirtual;
}

/// Name fragments belonging to software that sits between a real sensor and
/// the application.
///
/// Matching on device names is inherently approximate, so the list is
/// deliberately conservative: fragments distinctive enough that a physical
/// webcam is unlikely to carry them. A missed virtual camera degrades to
/// today's behaviour; a false positive would push someone off their only real
/// camera, which is worse.
const List<String> kVirtualCameraMarkers = <String>[
  'nvidia broadcast',
  'obs virtual',
  'obs-camera',
  'xsplit',
  'manycam',
  'splitcam',
  'altercam',
  'e2esoft',
  'vcam',
  'snap camera',
  'streamlabs',
  'droidcam',
  'epoccam',
  'iriun',
  'reincubate camo',
  'camo camera',
  'virtual camera',
  'virtualcam',
  'zoom virtual',
  'google meet camera',
];

/// Whether [name] looks like virtual-camera software.
bool looksLikeVirtualCamera(String name) {
  final String n = name.toLowerCase();
  for (final String marker in kVirtualCameraMarkers) {
    if (n.contains(marker)) return true;
  }
  return false;
}

/// Picks a camera, preferring hardware over virtual devices.
///
/// Order of preference:
///   1. physical, front-facing — what we actually want
///   2. physical, any direction
///   3. virtual, front-facing — better than nothing, but flagged
///   4. virtual, any direction
///
/// Returns null for an empty list.
CameraChoice? chooseCamera(List<CameraOption> options) {
  if (options.isEmpty) return null;

  int? physicalFront;
  int? physicalAny;
  int? virtualFront;

  for (int i = 0; i < options.length; i++) {
    final CameraOption o = options[i];
    final bool isVirtual = looksLikeVirtualCamera(o.name);

    if (!isVirtual) {
      if (o.isFront) {
        physicalFront ??= i;
      } else {
        physicalAny ??= i;
      }
    } else if (o.isFront) {
      virtualFront ??= i;
    }
  }

  final int index = physicalFront ?? physicalAny ?? virtualFront ?? 0;
  return CameraChoice(
    index: index,
    option: options[index],
    isVirtual: looksLikeVirtualCamera(options[index].name),
  );
}
