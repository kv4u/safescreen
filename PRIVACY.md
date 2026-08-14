# Privacy

Short version: SafeScreen watches you through your webcam continuously. It
sends nothing anywhere. It does write frames to disk, briefly, and that is a
problem it does not fully solve yet.

## What is collected

**Nothing leaves your computer.** SafeScreen has no server, no analytics, no
telemetry, no crash reporting, and no update check. It makes no network
requests of any kind, and carries no HTTP client dependency — you can confirm
this by reading `pubspec.yaml`.

## What happens to camera frames

SafeScreen holds the front camera open the entire time protection is active.
Your camera indicator light will stay on. That is expected: the whole product
is "notice when you look away", which requires looking.

Each frame is used to answer one question — is exactly one attentive face in
view — and is then discarded. No frame is retained in memory beyond the
detection call. No images, embeddings, face templates, or biometric identifiers
are stored anywhere.

**One caveat:** on Windows, each frame briefly touches the disk. The underlying
camera plugin has no streaming API, so it writes a JPEG and returns a path —
there is no way to intercept that from Dart. SafeScreen ships a forked plugin
that redirects those writes to a private `%TEMP%\SafeScreenFrames` directory
rather than your Pictures library (which is usually OneDrive-synced), and
overwrites and deletes each file the moment it has been read.

So frames stay on your machine and do not survive their read — but they are
written, briefly, before being erased. The full detail, including what that does
not cover, is in [SECURITY.md](SECURITY.md#how-camera-frames-are-handled).

## What is stored

Two settings, via `shared_preferences`, in your local app data:

- `sensitivity` — a number between 0 and 1
- `detect_shoulder_surfers` — a boolean

That is the complete list. No history, no logs, no usage record.

## Permissions

| Permission | Why |
|---|---|
| Camera | Detecting whether you are looking at the screen |

SafeScreen requests no other permission on Windows.

## Third-party components

Face detection runs locally via TensorFlow Lite models bundled with
[`face_detection_tflite`](https://pub.dev/packages/face_detection_tflite).
The models run on your CPU. They do not call out to any service.

## Changes

Material changes to this policy will be recorded in
[CHANGELOG.md](CHANGELOG.md) and in the release notes, not made silently.
