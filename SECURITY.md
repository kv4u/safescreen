# Security

SafeScreen is a privacy tool, so it owes you a precise account of what it does
to your machine — including the parts that are not good yet.

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](https://github.com/kv4u/safescreen/security/advisories/new)
rather than opening a public issue. Include the version, your Windows build, and
the steps to reproduce. Expect an initial response within a week.

Do not report findings that require an attacker who already has code execution
or administrator rights on the machine — at that point the screen is the least
of your problems.

---

## How camera frames are handled

**This is the most important thing to understand about how SafeScreen works.**

### The default: nothing is written to disk

SafeScreen captures through its own Media Foundation path,
`windows/runner/mf_camera.cpp`. It opens the camera directly, reads each frame
into memory, and passes it to Dart over a method channel. Frames are wrapped in
a BMP container in memory (`lib/services/bmp_encoder.dart`) purely because the
face detector's only entry point accepts an encoded image.

**No file is created at any point.** There is nothing to sync, index, snapshot,
back up or recover.

This path is attempted before any `camera_windows` controller exists, and that
ordering is load-bearing: a webcam is normally exclusive, so opening it through
the plugin first would leave Media Foundation unable to open it and the better
path would silently never be used.

### The fallback, and why it still exists

If in-memory capture cannot start — no Media Foundation, or a camera that will
not produce RGB32 — SafeScreen falls back to the Flutter camera plugin rather
than leaving you unprotected. **The status console reports which path is live:
`Frames: In memory` or `Frames: Via disk (fallback)`.** The rest of this section
applies only to the fallback.

`camera_windows` has no image-streaming API. The only way to obtain a frame is
`takePicture()`, whose native code writes it to disk before returning a path,
and upstream that path is inside `FOLDERID_Pictures` — your Pictures library:

```cpp
// camera_plugin.cpp, upstream
SHGetKnownFolderPath(FOLDERID_Pictures, KF_FLAG_CREATE, nullptr, &known_folder_path);
```

A detector sampling several times a second would therefore write thousands of
photographs of you into a folder that is Search-indexed, thumbnailed by
Explorer, and on most consumer machines **synced to OneDrive**.

Two layers reduce that:

**1. Frames never go somewhere synced.** A forked `camera_windows` redirects
captures to a private `%TEMP%\SafeScreenFrames` directory. The fork is a single
function, documented in
[`packages/camera_windows/FORK_NOTICE.md`](packages/camera_windows/FORK_NOTICE.md).

**2. Frames do not survive being read.** `lib/services/secure_frame_store.dart`
reads and destroys each file immediately, overwrites it with zeros first,
destroys it even when decoding fails, tracks every path handed over, and sweeps
survivors at shutdown. The status console shows a running count of erased files.

Residual risk on this path only: zeroing is best-effort on copy-on-write
filesystems, wear-levelled SSDs and volumes with VSS snapshots; anything running
as your user could read the directory during the moment a file exists; and a
backup agent configured to include `%TEMP%` would capture frames.

---

## Threat model

### What SafeScreen defends against

An unauthorised person **looking at your screen** while you are not paying
attention to it: someone behind you on a train, a colleague walking past your
desk, or a room you stepped out of without locking.

### What it explicitly does not defend against

- **Anyone with access to your machine.** SafeScreen is not a lock screen. It
  does not require authentication and it will not stop someone who can use your
  keyboard. Use Windows' own lock (`Win`+`L`) for that.
- **Screen capture, remote desktop, or screenshots.** The blackout is a normal
  window. It does not set `WDA_MONITOR` and does not interfere with capture
  APIs.
- **Anyone who can run code as you.** They can terminate SafeScreen.
- **Cameras pointed at your screen.** Obviously.

### Camera effects can silently defeat shoulder-surfer detection

<a id="camera-effects"></a>Anything that processes the video before SafeScreen
receives it can remove the very person shoulder-surfer detection exists to
catch. A person standing behind you *is* the background, so background blur or
background replacement erases them from the frame. The detector then sees one
face, reports "watching", and detects nothing. **This fails silently** — there
is no error, and the feature appears to be working.

Two distinct cases, and only the first is avoidable:

**Virtual camera software** — NVIDIA Broadcast, OBS Virtual Camera, XSplit VCam
and similar. These appear as ordinary webcams, and the previous camera choice
("first front-facing device") could easily land on one. SafeScreen now prefers
a physical camera whenever one exists, and when only a virtual device is
available it says so in the panel rather than claiming protection it cannot
give. See `lib/services/camera_selection.dart`.

**Windows Studio Effects** — on Copilot+ hardware, Windows applies the same
class of processing inside the OS camera pipeline, to the physical device.
SafeScreen cannot detect or avoid this; the device name is unchanged and the
frames simply arrive already processed. Three of its effects matter here:

| Effect | Consequence |
|---|---|
| Background blur | A shoulder surfer is blurred out of the frame |
| Automatic framing | The crop follows you, cutting others out entirely |
| Eye contact | Eyes are synthetically redirected toward the camera, which can make looking away undetectable |

Eye contact correction is the most serious: it attacks look-away detection
itself, not just the shoulder-surfer feature. **If you are on a Copilot+ PC,
turn Studio Effects off for SafeScreen** in Settings → Bluetooth & devices →
Cameras.

More generally: SafeScreen trusts the frames it is given. Any layer between the
sensor and the app can lie to it, and there is no way from user space to prove
that a frame is unmodified.

### Current limitations that have security consequences

- **The taskbar can stay visible across multiple monitors.**
  <a id="multi-monitor"></a>The blackout spans every display. A single display
  uses exclusive fullscreen, which also hides the taskbar; several displays are
  covered by a window sized to the union of their bounds, and that window does
  not suppress the taskbar. Display geometry is computed in physical pixels
  (see `display_geometry.dart`) so mixed scale factors are handled correctly,
  and if the computed rectangle looks implausible SafeScreen falls back to
  single-display fullscreen rather than trusting it.
- **The overlay can be dismissed.** Alt-tab is countered by re-asserting
  always-on-top when the window loses focus, but a determined local user can
  still close or kill the process.
- **Detection is not identity.** SafeScreen knows a face is present and roughly
  where it is pointed. It does not know whose face it is. Shoulder-surfer
  detection triggers on *any* second face, including one on a poster.

## Design decisions that favour safety

- **Fail closed.** The screen starts protected and stays protected whenever
  evidence is missing, stale, or ambiguous. Revealing requires several
  consecutive frames of positive proof; hiding takes one.
- **Staleness expiry.** If samples stop arriving — a wedged capture loop, a
  camera yanked out — the screen re-protects within seconds rather than staying
  exposed on the last known state.
- **Blindness is not attentiveness.** A detector error, a face with unusable
  keypoints, and an unreadable frame all protect the screen. They are reported
  distinctly from "nobody is there" so you can tell the difference.
- **Unmeasured signals are skipped, never assumed.** The Windows path cannot
  see eyelids, so it does not evaluate eye-openness at all rather than
  defaulting it to "open".

## Network and telemetry

SafeScreen makes no network requests. It has no analytics, no crash reporting,
no update check, and no server. There is no networking dependency in
`pubspec.yaml`. See [PRIVACY.md](PRIVACY.md).

## Release integrity

Releases are built by GitHub Actions from a tagged commit, never uploaded from
a developer machine. Each release carries SHA-256 checksums and a build
provenance attestation you can verify with:

```bash
gh attestation verify SafeScreen-windows-x64.zip --repo kv4u/safescreen
```

Binaries are **not** code-signed — a certificate costs more than this project
has. Windows SmartScreen will warn you. Verify the checksum and attestation, or
build from source.
