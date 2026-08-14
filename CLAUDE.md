# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter pub get          # Install dependencies
flutter run              # Run on Android
flutter run -d windows   # Run on Windows
flutter test             # Run tests
flutter analyze          # Lint with rules from analysis_options.yaml
```

## Architecture

SafeScreen is a privacy screen protector that uses the front camera to detect gaze and blur/overlay the screen when the user looks away. It targets Android (overlay over other apps) and Windows (fullscreen always-on-top window).

### Entry Points

`lib/main.dart` has two entry points:
- `main()` — Standard app, loads the home screen
- `overlayMain()` — Android-only separate process for the overlay window (`@pragma("vm:entry-point")`)

### Data Flow

1. **CameraGazeService** (`lib/services/camera_gaze_service.dart`) — Captures camera frames and extracts face data. On Android uses ML Kit FaceDetector for head pose (yaw/pitch) and eye open probability; processes every 3rd frame. On Windows uses TFLite with bounding-box-based centering logic at ~220ms intervals.

2. **GazeDetectorService** (`lib/services/gaze_detector_service.dart`) — Pure logic layer. Takes head pose angles and face/eye data, returns whether the user is looking at the screen. Uses ±28° yaw/pitch thresholds and hysteresis (3 consecutive "looking" frames to unlock, 1 "away" frame to lock) to prevent flicker.

3. **Screens** consume gaze state via an `onGazeStateChanged` callback. No external state management library — plain stateful widgets with `setState()`.

### Platform Differences

**Android:**
- Overlay runs in a separate process via `flutter_overlay_window`
- `ProtectionActiveScreen` shares gaze state with the overlay via `FlutterOverlayWindow.shareData('looking'/'away')`
- `overlay_screen.dart` is the UI for that separate overlay process; it listens on `FlutterOverlayWindow.overlayListener`
- Requires camera permission + "Display over other apps" permission

**Windows:**
- No multi-app overlay — uses a fullscreen always-on-top window with `window_manager`
- System tray via `tray_manager`; window hides to tray and auto-restores when gaze-away is detected
- Face detection uses `face_detection_tflite` (ML Kit is not available on Windows)
- `camera_windows` is pinned to `^0.2.6+2` because newer versions require Dart ≥3.8

### Operation Modes

| Mode | File | Description |
|------|------|-------------|
| Android overlay | `screens/protection_active_screen.dart` + `overlay/overlay_screen.dart` | Overlay over other apps |
| Windows fullscreen | `screens/protection_active_screen.dart` | Fullscreen + tray integration |
| In-app only | `screens/privacy_screen.dart` | BackdropFilter blur within the app only, no overlay permission needed |

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `google_mlkit_face_detection` | Android head pose (yaw/pitch) + eye open probability |
| `face_detection_tflite` | Windows face bounding-box detection |
| `flutter_overlay_window` | Android overlay-over-other-apps |
| `window_manager` | Windows fullscreen + always-on-top control |
| `tray_manager` | Windows system tray |
| `camera` / `camera_windows` | Front camera access |
