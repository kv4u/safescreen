# Contributing

Thanks for considering it. SafeScreen is small, and the areas that most need
help are listed in the [roadmap](README.md#roadmap).

## Getting set up

Requires the Flutter SDK (Dart ≥ 3.7, < 3.8), Visual Studio 2022 with the
*Desktop development with C++* workload, and Developer Mode enabled so plugin
symlinks work:

```bash
start ms-settings:developers   # enable Developer Mode
flutter pub get
flutter test
flutter analyze
flutter run -d windows
```

## Before opening a PR

```bash
flutter analyze   # must report no issues
flutter test      # must pass
```

CI runs both and will block the merge otherwise.

## Where the logic lives

The detection pipeline is deliberately split so the interesting parts have no
plugin dependencies and can be tested in milliseconds:

| File | Responsibility | Testable |
|---|---|---|
| `head_pose_estimator.dart` | Keypoints → yaw/roll/pitch. Pure Dart. | Yes, directly |
| `gaze_detector_service.dart` | Samples → protected/visible. Pure Dart. | Yes, directly |
| `secure_frame_store.dart` | Reading and destroying capture files | Partly — touches the filesystem |
| `camera_gaze_service.dart` | Camera and TFLite plumbing | Not really — needs hardware |

**Please keep the first two free of Flutter and plugin imports.** That property
is what makes the security-critical behaviour testable, and it is easy to lose
by accident.

## Things to be careful about

This is a privacy tool, so some changes carry more weight than their diff size
suggests:

- **Never make the detector fail open.** Any new state where evidence is
  missing, stale, or unreadable must protect the screen. If you add a code path
  that returns "visible" without positive proof of an attentive single face, it
  will be rejected.
- **Do not weaken the hysteresis asymmetry.** Revealing must never take fewer
  frames than hiding. There is a test asserting this across the whole
  sensitivity range; do not delete it to make a change pass.
- **Do not add network calls.** No analytics, no update checks, no crash
  reporting. PRIVACY.md makes a promise and it should stay true.
- **Frames must never outlive their read.** If you touch the capture path,
  ensure every file is destroyed on every path, including error paths.

## Reporting bugs

Include your Windows version, webcam model, whether you use multiple monitors,
and what the status card reported at the time. If detection behaves oddly, the
reason string ("Looking away", "No one detected", "Detector unavailable") is
the most useful single detail.

For security issues, do not open a public issue — see [SECURITY.md](SECURITY.md).

## Commit style

Short imperative subject lines. Explain *why* in the body when the reason is not
obvious from the diff.
