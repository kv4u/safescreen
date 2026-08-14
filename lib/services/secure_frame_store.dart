// Damage control for the Windows capture path.
//
// `camera_windows` has no image-stream API. The only way to get a frame is
// `takePicture()`, and the native plugin writes that frame as a JPEG to
// FOLDERID_Pictures — the user's Pictures library — before handing back a path
// (see camera_plugin.cpp, GetFilePathForPicture). Files are named
// `PhotoCapture_<timestamp>.jpeg`.
//
// That folder is Search-indexed, thumbnailed by Explorer, and on most machines
// synced to OneDrive. A gaze detector sampling several times a second therefore
// scatters photographs of the user through a cloud-synced directory. For a
// privacy tool this is the single worst property of the current design.
//
// This class cannot prevent the write — it happens natively, before Dart sees
// anything. What it can do:
//
//   * shrink the exposure window to the minimum by reading and destroying each
//     file the instant it appears;
//   * overwrite the bytes with zeros before unlinking, so the contents are not
//     trivially recoverable from free space or lifted by an indexer later;
//   * account for every file it creates, and sweep survivors on shutdown so a
//     crash mid-capture does not leave frames lying around.
//
// It cannot close the race entirely. A sync client that reads the file within
// the few milliseconds it exists may still copy it. The real fix is in-memory
// capture via a native Media Foundation plugin — see SECURITY.md.

import 'dart:io';

import 'package:flutter/foundation.dart';

class SecureFrameStore {
  /// Directory the native plugin writes into. Learned from the first captured
  /// path rather than guessed, so folder redirection (OneDrive moving the
  /// Pictures library) can never point the sweep at the wrong place.
  Directory? _captureDir;

  /// Paths handed to us that we have not yet confirmed destroyed.
  final Set<String> _outstanding = <String>{};

  /// Only files modified after this instant are ever considered ours.
  final DateTime _sessionStart = DateTime.now();

  int _shredded = 0;
  int _shredFailures = 0;

  /// Number of capture files successfully destroyed this session.
  int get shreddedCount => _shredded;

  /// Number that could not be destroyed. Non-zero means frames may persist.
  int get shredFailureCount => _shredFailures;

  Directory? get captureDirectory => _captureDir;

  /// Reads a captured frame and destroys the file before returning.
  ///
  /// The file is destroyed whether or not the read succeeds — a frame we could
  /// not decode is still a photograph of the user sitting on disk.
  Future<Uint8List?> takeAndShred(String path) async {
    final File file = File(path);
    _captureDir ??= file.parent;
    _outstanding.add(path);

    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      debugPrint('SafeScreen: could not read capture: $e');
    } finally {
      await _shred(file);
    }
    return bytes;
  }

  /// Overwrites a file with zeros, then deletes it.
  ///
  /// Zeroing is best-effort and defeats casual recovery only: on a
  /// copy-on-write or wear-levelled device the original blocks may survive.
  /// It is strictly better than a bare delete, which leaves the JPEG intact in
  /// free space.
  Future<void> _shred(File file) async {
    try {
      if (!await file.exists()) {
        _outstanding.remove(file.path);
        return;
      }
      try {
        final int length = await file.length();
        if (length > 0) {
          final RandomAccessFile raf = await file.open(mode: FileMode.write);
          try {
            await raf.writeFrom(Uint8List(length));
            await raf.flush();
          } finally {
            await raf.close();
          }
        }
      } catch (e) {
        // Overwrite failed; still attempt the delete below.
        debugPrint('SafeScreen: could not overwrite capture: $e');
      }
      await file.delete();
      _outstanding.remove(file.path);
      _shredded++;
    } catch (e) {
      _shredFailures++;
      debugPrint('SafeScreen: could not delete capture ${file.path}: $e');
    }
  }

  /// Destroys any capture files that outlived their read.
  ///
  /// Deliberately conservative. It only touches files that are all of:
  /// in the directory the plugin actually wrote to, named with the plugin's
  /// `PhotoCapture_` prefix and `.jpeg` extension, and modified after this
  /// session began. A user's own photographs cannot satisfy the third
  /// condition, so this will not eat unrelated files.
  Future<void> sweep() async {
    for (final String path in List<String>.of(_outstanding)) {
      await _shred(File(path));
    }

    final Directory? dir = _captureDir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      await for (final FileSystemEntity entity in dir.list(
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!name.startsWith('PhotoCapture_') || !name.endsWith('.jpeg')) {
          continue;
        }
        FileStat stat;
        try {
          stat = await entity.stat();
        } catch (_) {
          continue;
        }
        if (stat.modified.isBefore(_sessionStart)) continue;
        await _shred(entity);
      }
    } catch (e) {
      debugPrint('SafeScreen: sweep failed: $e');
    }
  }
}
