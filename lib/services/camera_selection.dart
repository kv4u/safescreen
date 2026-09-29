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

/// A camera name as the Windows camera plugin reports it, split into parts.
///
/// The plugin reports `Friendly Name <device path>`, for example
/// `Integrated Webcam <\\?\usb#vid_0c45&pid_6a10&mi_00#...\global>`. The
/// device path is the camera's exact identity; the friendly name is what a
/// person should see. Showing the raw string put the device path on screen as
/// gibberish.
class CameraName {
  const CameraName({required this.display, this.deviceId});

  /// Human-readable name, for the UI and for the virtual-camera check.
  final String display;

  /// Exact device path, for opening this specific camera. Null when the
  /// platform reported only a plain name.
  final String? deviceId;

  @override
  String toString() => 'CameraName($display, $deviceId)';
}

/// Splits a raw camera name into its display name and device path.
CameraName parseCameraName(String raw) {
  final String trimmed = raw.trim();
  final int open = trimmed.lastIndexOf('<');
  if (open <= 0 || !trimmed.endsWith('>')) {
    return CameraName(display: trimmed);
  }
  final String display = trimmed.substring(0, open).trim();
  final String id = trimmed.substring(open + 1, trimmed.length - 1).trim();
  if (display.isEmpty) return CameraName(display: trimmed);
  return CameraName(display: display, deviceId: id.isEmpty ? null : id);
}

/// A camera as the platform enumerated it.
class CameraOption {
  const CameraOption({
    required this.name,
    required this.isFront,
    this.deviceId,
  });

  /// Builds an option from the plugin's raw `Friendly Name <device path>`.
  factory CameraOption.fromRaw(String raw, {required bool isFront}) {
    final CameraName parsed = parseCameraName(raw);
    return CameraOption(
      name: parsed.display,
      isFront: isFront,
      deviceId: parsed.deviceId,
    );
  }

  /// Human-readable name. The virtual-camera check runs on this alone, so a
  /// marker that happens to appear inside a device path cannot misfire.
  final String name;
  final bool isFront;

  /// Exact device path, when known.
  final String? deviceId;

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
