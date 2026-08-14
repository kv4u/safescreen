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

**However:** on Windows, frames pass through your Pictures folder on the way in,
because of a limitation in the underlying camera plugin. SafeScreen destroys
each file immediately and overwrites it first, but it cannot prevent the write.
If your Pictures folder syncs to OneDrive, there is a window in which a frame
could be uploaded.

This is described in full, without softening, in
[SECURITY.md](SECURITY.md#known-issue-captured-frames-are-written-to-your-pictures-folder).
Read it before deciding whether to run this.

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
