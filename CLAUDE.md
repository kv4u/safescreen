# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run -d windows   # Run on Windows (the supported target)
flutter test             # Run tests
flutter analyze          # Lint with rules from analysis_options.yaml
dart format lib test     # CI enforces this
flutter build windows --release
```

Building requires **Developer Mode enabled** (`start ms-settings:developers`) —
Flutter needs symlink support for plugins, and the build fails outright without
it.

## Architecture

SafeScreen is a privacy screen protector: the front camera detects whether the
user is looking at the screen, and blacks it out when they are not. **Windows is
the supported platform.** Android code is present but experimental, unsupported,
and not built by CI.

### Entry Points

`lib/main.dart`:
- `main()` — the app; loads settings, then the home screen
- `overlayMain()` — Android-only separate process for the overlay window

### Detection pipeline

1. **CameraGazeService** (`lib/services/camera_gaze_service.dart`) — camera and
   detector plumbing. On Windows: a self-scheduling `takePicture` loop (there is
   no image-stream API on that platform), running TFLite in
   `FaceDetectionMode.fast`. On Android: an ML Kit image stream.

2. **SecureFrameStore** (`lib/services/secure_frame_store.dart`) — reads and
   destroys each captured file. See "Frame handling" below.

3. **estimateHeadPose** (`lib/services/head_pose_estimator.dart`) — converts the
   detector's six keypoints into yaw/roll/pitch. Pure Dart, no imports beyond
   `dart:math`.

4. **GazeDetectorService** (`lib/services/gaze_detector_service.dart`) — the
   state machine. Takes `GazeSample`s, applies thresholds and hysteresis,
   exposes `isScreenVisible` and a `ProtectionReason`. Pure Dart.

5. **Screens** consume state via an `onGazeStateChanged` callback plus a 500 ms
   watchdog timer. No state management library — plain `setState()`.

**Keep steps 3 and 4 free of Flutter and plugin imports.** That is what makes
the security-critical logic unit-testable, and it is easy to break by accident.

### Invariants that must not be broken

These encode the security properties, and several were bugs that got fixed:

- **Fail closed.** `isScreenVisible` starts false and requires positive evidence
  of exactly one attentive face. Any new path that reveals without that evidence
  is a bug.
- **Hysteresis stays asymmetric.** `framesToProtect <= framesToReveal` at every
  sensitivity. There is a test asserting this across the range.
- **Blindness ≠ attentiveness.** Detector errors, unusable keypoints, and
  unreadable frames all protect.
- **Unmeasured signals are skipped, not assumed.** Windows has no eye-openness
  signal, so nulls mean "not measured" and the check is skipped entirely.
- **Samples go stale.** If frames stop arriving, the screen re-protects.
- **No network calls, ever.** PRIVACY.md promises this.

### Frame handling (important)

`camera_windows` has no image-stream API, so each frame is written to disk
natively by `takePicture()` before Dart sees a path. Upstream writes to
`FOLDERID_Pictures` — usually OneDrive-synced.

`packages/camera_windows/` is a **vendored fork** whose only change redirects
captures to `%TEMP%\SafeScreenFrames`. It is wired in via `dependency_overrides`
in `pubspec.yaml`. See `packages/camera_windows/FORK_NOTICE.md` before touching
it, and re-apply the patch when syncing with upstream.

`SecureFrameStore` then zeroes and deletes each file, on every path including
errors, and sweeps survivors on shutdown.

### Windows specifics

- Fullscreen always-on-top blackout via `window_manager`; re-asserts on-top when
  the window loses focus.
- Window transitions are serialised through a `Future` chain (`_windowOp`) —
  overlapping async `window_manager` calls previously raced.
- System tray via `tray_manager`.
- Face detection uses `face_detection_tflite` (ML Kit is Android/iOS only).
- `camera_windows` is pinned to `0.2.6+2`; later versions require Dart ≥ 3.8.
- Only the primary monitor is covered — a known limitation.

### Operation Modes

| Mode | File | Description |
|------|------|-------------|
| Windows fullscreen | `screens/protection_active_screen.dart` | Fullscreen blackout + tray |
| In-app only | `screens/privacy_screen.dart` | `BackdropFilter` blur within the app |
| Android overlay | `screens/protection_active_screen.dart` + `overlay/overlay_screen.dart` | Experimental |

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `face_detection_tflite` | Windows face detection + keypoints |
| `google_mlkit_face_detection` | Android head pose + eye open probability |
| `camera` / `camera_windows` (forked) | Front camera access |
| `window_manager` | Windows fullscreen + always-on-top |
| `tray_manager` | Windows system tray |
| `shared_preferences` | Settings persistence |
| `flutter_overlay_window` | Android overlay (experimental) |
