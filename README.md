<div align="center">

# SafeScreen

**Your screen goes dark when you look away.**

A privacy screen protector for Windows that uses your webcam to tell whether
you are actually looking at your display — and blacks it out the moment you are
not.

[![CI](https://github.com/kv4u/safescreen/actions/workflows/ci.yml/badge.svg)](https://github.com/kv4u/safescreen/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kv4u/safescreen?include_prereleases&sort=semver)](https://github.com/kv4u/safescreen/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2B-0078D6)](https://github.com/kv4u/safescreen/releases/latest)

[Download](https://github.com/kv4u/safescreen/releases/latest) ·
[Website](https://kv4u.github.io/safescreen/) ·
[Security](SECURITY.md) ·
[Privacy](PRIVACY.md)

</div>

---

> [!NOTE]
> **How frames are handled.** The Windows camera plugin has no streaming API, so
> each frame is written to disk before SafeScreen can see it. SafeScreen ships a
> [forked plugin](packages/camera_windows/FORK_NOTICE.md) that redirects those
> writes away from your (OneDrive-synced) Pictures folder into private temp
> storage, then overwrites and deletes each file the instant it is read. Frames
> stay on your machine and do not outlive their read — but they are written
> briefly. [SECURITY.md](SECURITY.md#how-camera-frames-are-handled) has the
> complete account.

## What it does

Look at your screen, and nothing happens. Turn your head, lean out of frame,
walk away, or let someone else's face appear over your shoulder — the screen
goes black until you are the only one looking at it again.

- **Real head-pose detection.** Not "is there a face somewhere in frame". The
  detector recovers yaw and roll from facial geometry and learns your neutral
  head position over time.
- **Shoulder-surfer detection.** A second face in view protects the screen,
  even while you are still looking at it.
- **Covers every display.** The blackout spans the whole desktop, not just the
  monitor the app happens to sit on.
- **Fails closed.** Camera unplugged, detector wedged, frames stopped arriving?
  The screen protects itself. It never stays exposed because something broke.
- **Tray-resident.** Minimises out of the way and keeps working.
- **No network. No telemetry. No account.** Nothing leaves your machine.

## Install

Download `SafeScreen-windows-x64.zip` from the
[latest release](https://github.com/kv4u/safescreen/releases/latest), unzip it
anywhere, and run `safe_screen.exe`. No installer, no admin rights.

Windows 10 (1809 or newer) or Windows 11, x64, plus a webcam.

### Verifying your download

Binaries are unsigned, so **SmartScreen will warn you** ("Windows protected
your PC" → *More info* → *Run anyway*). Rather than clicking through blindly,
verify what you downloaded:

```powershell
Get-FileHash .\SafeScreen-windows-x64.zip -Algorithm SHA256
```

Compare against `SHA256SUMS.txt` in the same release. Releases are built by
GitHub Actions from a tagged commit and carry a provenance attestation:

```bash
gh attestation verify SafeScreen-windows-x64.zip --repo kv4u/safescreen
```

## How it works

```
webcam ──► takePicture ──► SecureFrameStore ──► BlazeFace (TFLite, fast mode)
             (to private        │                        │
              temp, not      erase the file        6 keypoints
              Pictures)
                                                         │
                                                 HeadPoseEstimator
                                                  yaw · roll · pitch
                                                         │
                                                 GazeDetectorService
                                              hysteresis · staleness
                                                         │
                                              screen visible / protected
```

**Head pose from keypoints.** The Windows detector reports six facial
keypoints, not Euler angles. Modelling the head as a cylinder — nose at the
front, tragions (ear points) at ±90° — the nose's normalised position between
the tragions gives `t = 0.5 + 0.5·tan θ`, so yaw falls straight out as
`atan((t − 0.5)·2)`. Roll comes from the inclination of the eye line, and pitch
is measured perpendicular to it so head tilt does not contaminate it. See
[`head_pose_estimator.dart`](lib/services/head_pose_estimator.dart).

**Pitch is calibrated to you.** How far your nose sits below your eye line is a
fact about your face, not your attention, so a fixed threshold misfires on
real people. SafeScreen learns your neutral value from frames where you are
squarely facing the screen and measures deviation from that.

**Hysteresis is deliberately asymmetric.** Hiding takes one bad frame; revealing
takes several consecutive good ones. Flickering to "protected" is an annoyance.
Flickering to "visible" is a privacy failure. They are not weighted equally.

## Configuration

| Setting | Default | Effect |
|---|---|---|
| Sensitivity | Strict | Angular tolerance (±40° lenient → ±15° strict) and how many frames each transition needs |
| Shoulder-surfer detection | On | Protect when a second face appears |

## Known limitations

- **Mixed-DPI multi-monitor is approximate.** All displays are covered, but
  when monitors run at different scale factors the cover can land slightly off.
  See [SECURITY.md](SECURITY.md#multi-monitor).
- **Frames touch disk briefly.** In private temp storage, erased immediately —
  but written. In-memory capture is roadmap item #1. See
  [SECURITY.md](SECURITY.md#how-camera-frames-are-handled).
- **Not a lock screen.** SafeScreen does not authenticate anyone and will not
  stop someone using your keyboard. Use `Win`+`L`.
- **Poor lighting degrades detection.** Backlighting in particular. The failure
  direction is safe — it protects rather than exposes — but it can be annoying.
- **Android is experimental.** The code is present and roughly works, but it is
  unsupported, untested in this release, and not built by CI.

## Roadmap

1. **In-memory capture** via a native Media Foundation plugin, removing disk
   writes entirely and letting the vendored `camera_windows` fork be dropped.
2. Optional session lock after a configurable absence.
3. Start-with-Windows option.
4. Signed binaries, if funding for a certificate ever appears.

## Building from source

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)
(Dart ≥ 3.7, < 3.8 — see the `camera_windows` note in `pubspec.yaml`), Visual
Studio 2022 with the *Desktop development with C++* workload, and **Developer
Mode enabled** (`start ms-settings:developers`) so plugin symlinks work.

```bash
flutter pub get
flutter test
flutter analyze
flutter run -d windows
```

Release build:

```bash
flutter build windows --release
```

Output lands in `build\windows\x64\runner\Release\`.

## Contributing

Bug reports and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
The detection logic is pure Dart with no plugin dependencies, so it is
straightforward to test; please keep it that way, and add cases for behaviour
you change.

## License

[MIT](LICENSE).

Face detection uses [`face_detection_tflite`](https://pub.dev/packages/face_detection_tflite),
which bundles MediaPipe BlazeFace models.
