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

The Windows camera plugin (`camera_windows`) has no image-streaming API. The
only way to obtain a frame is `takePicture()`, and the plugin's native code
writes that frame to disk before returning a path. Dart never gets a chance to
intercept it.

Upstream, that path is inside `FOLDERID_Pictures` — your Pictures library:

```cpp
// camera_plugin.cpp, upstream
SHGetKnownFolderPath(FOLDERID_Pictures, KF_FLAG_CREATE, nullptr, &known_folder_path);
```

A gaze detector sampling several times a second would therefore write thousands
of photographs of you into a folder that is Windows Search–indexed, thumbnailed
by Explorer, and — on most consumer machines — **synced to OneDrive**, meaning
uploaded off the device.

### What SafeScreen does about it

Two independent layers:

**1. Frames never go somewhere synced.** SafeScreen vendors a forked
`camera_windows` whose only change is the capture destination: a private
`%TEMP%\SafeScreenFrames` directory instead of the Pictures library. `%TEMP%` is
not a sync target and is not part of the user's media libraries. The fork is a
single function, documented in
[`packages/camera_windows/FORK_NOTICE.md`](packages/camera_windows/FORK_NOTICE.md).

**2. Frames do not survive being read.** `lib/services/secure_frame_store.dart`:

| Mitigation | Effect |
|---|---|
| Read and destroy each file immediately | Lifetime is roughly the duration of one read |
| Overwrite with zeros before unlinking | The JPEG is not left intact in free space |
| Destroy the file even if decoding fails | A frame we could not use is still a photograph of you |
| Track every path handed to us | Nothing is forgotten if a read throws |
| Sweep on shutdown | Files that outlived a crashed capture are cleaned up |
| Sample more slowly while already protected | Roughly halves files written while you are away |

The status screen shows a live count of erased capture files, so this is
observable rather than something you take on faith.

### What is still not solved

**Frames touch the disk.** Briefly, in a non-synced directory, overwritten and
deleted immediately — but they touch it. Specifically:

- On copy-on-write filesystems, wear-levelled SSDs, or volumes with VSS
  snapshots, the zeroing pass may not overwrite the original blocks.
- Anything running as your user could read `%TEMP%\SafeScreenFrames` during the
  window a file exists. (Anything running as your user could also just open the
  webcam directly, so this is not much of an escalation.)
- A backup agent configured to include `%TEMP%` would capture frames. This is an
  unusual configuration, but check yours if it matters.

### The complete fix

Replace `takePicture()` with a native Media Foundation capture path that
delivers frames into memory and never touches the filesystem. This is the top
roadmap item, and it would let the fork be dropped entirely.

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
- **Multi-monitor setups.** See below.

### Current limitations that have security consequences

- **Only one monitor is covered.** The blackout is a single fullscreen window.
  On a multi-monitor setup, your other displays remain fully visible when you
  look away. This is a real hole and it is the second roadmap item.
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
