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
view — and is then discarded. No images, embeddings, face templates, or
biometric identifiers are stored anywhere.

**Frames are captured in memory and never written to disk.** SafeScreen reads
the camera directly through Windows Media Foundation, so there is no file to
sync, index or recover.

With **Camera preview** on, the most recent frame is held in memory so it can be
drawn in the status console, and replaced by the next one. With it off, no frame
outlives the detection call that used it.

**One exception:** if in-memory capture cannot start on your machine, SafeScreen
falls back to the Flutter camera plugin rather than leaving you unprotected, and
that plugin can only produce a frame by writing it to disk first. On that path
frames go to a private temp folder rather than your OneDrive-synced Pictures
library, and each is overwritten and deleted the moment it has been read. The
status console shows **Frames: Via disk (fallback)** when this is happening.
Full detail in [SECURITY.md](SECURITY.md#how-camera-frames-are-handled).

## What is stored

Three settings, via `shared_preferences`, in your local app data:

- `sensitivity` — a number between 0 and 1
- `detect_shoulder_surfers` — a boolean
- `show_camera_preview` — a boolean

And, **only if you turn on Start with Windows**, one registry value:

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\SafeScreen` — the
  path to `safe_screen.exe`, so Windows launches it at sign-in. Turning the
  setting off deletes it. It is also listed in Task Manager's Startup tab,
  where it can be disabled without opening SafeScreen at all.

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
