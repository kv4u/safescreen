# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-08-13

First public release. Windows is the supported platform.

### Added

- **Head-pose estimation from facial keypoints.** Yaw and roll are recovered
  analytically from BlazeFace's six keypoints via a cylindrical head model,
  replacing a heuristic that only checked whether the face bounding box sat
  near the middle of the frame.
- **Per-user pitch calibration.** The neutral nose-below-eyes ratio is learned
  from frames where the user faces the screen squarely, so detection adapts to
  facial proportions instead of assuming a constant.
- **Shoulder-surfer detection.** A second face in view protects the screen.
  Toggleable; on by default.
- **Staleness expiry.** If samples stop arriving, the screen re-protects within
  seconds rather than holding the last known state indefinitely.
- **Distinct protection reasons** surfaced in the UI — no face, looked away,
  eyes closed, multiple faces, detector error, stale feed.
- **Capture-file accounting** shown live in the status card, so the erasure
  described in SECURITY.md is observable.
- **Persisted settings** via `shared_preferences`.
- Unit test suite covering the pose estimator and the detection state machine.
- CI running `flutter analyze` and `flutter test`; tagged releases built by
  GitHub Actions with SHA-256 checksums and build provenance attestation.

### Changed

- **The detector now fails closed.** Previously the screen started *visible*
  and stayed visible until the first "away" reading — meaning it was unprotected
  during startup and after any detector failure. It now starts protected and
  requires positive evidence to reveal.
- **Hysteresis is asymmetric again.** Hiding takes one frame at default
  sensitivity; revealing takes several. A previous refactor had collapsed both
  directions to the same frame count, removing the anti-flicker guarantee.
- **Sensitivity now affects Windows.** The Windows path previously passed zeroed
  rotation values into the detector, so the angular thresholds could never
  trigger and the slider did nothing on that platform.
- **Windows detection runs in `fast` mode.** The previous code used the
  package's default `FaceDetectionMode.full`, which runs a 468-point face mesh
  and two iris models per frame — none of whose output was used.
- Sampling now slows while the screen is already protected, roughly halving
  disk writes while the user is away.
- The capture loop is self-scheduling rather than a fixed `Timer.periodic`, so
  a slow frame cannot cause work to pile up behind it.

### Fixed

- **Captured frames no longer land in the user's Pictures folder.** The
  upstream `camera_windows` plugin writes every `takePicture()` frame to
  `FOLDERID_Pictures`, which is Search-indexed, thumbnailed, and typically
  OneDrive-synced — so a gaze detector sampling several times a second would
  upload thousands of photographs of the user. SafeScreen now vendors a forked
  plugin whose sole change is to redirect captures to a private
  `%TEMP%\SafeScreenFrames` directory. See
  [`packages/camera_windows/FORK_NOTICE.md`](packages/camera_windows/FORK_NOTICE.md).
- **Captured frames are now erased.** Each JPEG is overwritten with zeros and
  deleted immediately, on every path including errors, with a sweep on shutdown
  for anything that survived a crash. See
  [SECURITY.md](SECURITY.md#how-camera-frames-are-handled) for what this does
  and does not solve.
- **Window transitions no longer race.** Overlapping async `window_manager`
  calls could interleave and leave the window state disagreeing with the
  detector state. Transitions are now serialised.
- The blackout re-asserts always-on-top when it loses focus, so alt-tab no
  longer reveals the screen it is meant to be covering.
- The Android overlay is now closed when protection stops. Previously it
  outlived the camera and could remain stuck on a black screen indefinitely.

### Known issues

- Camera frames still touch the disk briefly, in private temp storage, before
  being erased. Eliminating disk writes entirely requires a native Media
  Foundation capture path. See
  [SECURITY.md](SECURITY.md#how-camera-frames-are-handled).
- Only the primary monitor is covered by the blackout.
- Android support is experimental and unsupported.

[1.0.0]: https://github.com/kv4u/safescreen/releases/tag/v1.0.0
