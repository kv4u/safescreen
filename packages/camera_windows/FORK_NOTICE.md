# Vendored fork of `camera_windows`

This directory is a copy of
[`camera_windows` 0.2.6+2](https://pub.dev/packages/camera_windows/versions/0.2.6+2)
from the Flutter `packages` repository, with **one behavioural change**.

It is licensed under the original BSD-3-Clause terms — see [LICENSE](LICENSE)
and [AUTHORS](AUTHORS). Copyright remains with The Flutter Authors. SafeScreen
claims no ownership of this code.

## The change

`GetFilePathForPicture()` in [`windows/camera_plugin.cpp`](windows/camera_plugin.cpp)
previously returned a path inside `FOLDERID_Pictures`:

```cpp
SHGetKnownFolderPath(FOLDERID_Pictures, KF_FLAG_CREATE, nullptr, &known_folder_path);
...
return path + "\\" + "PhotoCapture_" + GetCurrentTimeString() + ".jpeg";
```

It now returns a path inside a private `SafeScreenFrames` directory under
`%TEMP%`.

## Why

`camera_windows` exposes no image-streaming API, so the only way to obtain a
frame is `takePicture()` — and that writes the frame to disk natively before
returning a path. SafeScreen samples the webcam several times a second and
discards every frame immediately after deciding whether someone is looking at
the screen.

Sending those frames to the Pictures library means writing thousands of
photographs of the user into a folder that is:

- indexed by Windows Search,
- thumbnailed by Explorer,
- and, on most consumer machines, **synced to OneDrive** — that is, uploaded.

For a tool whose purpose is stopping people from seeing your screen, silently
uploading photographs of your face is an unacceptable default. It cannot be
fixed from Dart, because the write happens before any path reaches Dart code.

`%TEMP%` is not a sync target, so the frames stay on the machine. SafeScreen
additionally overwrites and deletes each file the moment it has been read — see
[`lib/services/secure_frame_store.dart`](../../lib/services/secure_frame_store.dart).
The two mitigations are independent: the fork keeps frames out of the cloud, the
shredder keeps them off the disk.

## What was deliberately left alone

`GetFilePathForVideo()` still writes to `FOLDERID_Videos`. SafeScreen never
records video, and for an app that does, a user-initiated recording genuinely
belongs in the user's library. Narrowing the change keeps the diff against
upstream to a single function.

## Upstreaming

This is not a good general-purpose patch — most camera apps *want* photos in
Pictures. The upstream-appropriate fix is an image-streaming API on Windows, or
a way for the caller to choose the destination path. Either would let SafeScreen
drop this fork.

## Re-syncing with upstream

1. Download the new version of `camera_windows`.
2. Copy `lib/`, `windows/`, `pigeons/`, `pubspec.yaml`, `LICENSE`, `AUTHORS`,
   `CHANGELOG.md`, `README.md` over this directory.
3. Re-apply the `GetFilePathForPicture()` change; the block is marked with a
   `SAFESCREEN FORK` comment.
4. Check that the version still satisfies the SDK constraint in the root
   `pubspec.yaml` (0.2.6+3 and later require Dart ≥ 3.8).
