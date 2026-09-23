// Start with Windows.
//
// A tray utility that has to be launched by hand after every reboot protects
// nobody on the mornings it is forgotten — and nothing tells you it is not
// running. This registers SafeScreen under the per-user Run key so it starts at
// sign-in and goes straight into protection.
//
// Implemented by shelling out to reg.exe rather than adding a registry package:
// reg.exe ships with every Windows install, needs no admin rights for HKCU, and
// adds no dependency with its own Dart SDK constraints to fight. It is a local
// process, not a network call, so the no-network promise in PRIVACY.md holds.
//
// The executable path is re-checked on every launch. SafeScreen is distributed
// as an unzip-anywhere folder, so moving that folder would otherwise leave a Run
// entry pointing at nothing, and autostart would fail silently — the exact
// failure this feature exists to prevent.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Passed on the command line when Windows starts SafeScreen at sign-in.
const String kAutostartFlag = '--autostart';

const String kRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String kRunValueName = 'SafeScreen';

/// The command line stored in the Run key for [exePath].
///
/// The path is quoted because the default unzip location commonly contains
/// spaces ("Downloads\SafeScreen-windows-x64"), and an unquoted path with a
/// space in a Run entry is both broken and a classic hijack vector.
String buildRunCommand(String exePath) => '"$exePath" $kAutostartFlag';

/// Extracts the value data from `reg query` output, or null if absent.
///
/// The output looks like:
///
///     HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run
///         SafeScreen    REG_SZ    "C:\Apps\SafeScreen\safe_screen.exe" --autostart
String? parseRunValue(
  String regQueryOutput, {
  String valueName = kRunValueName,
}) {
  for (final String raw in regQueryOutput.split(RegExp(r'\r?\n'))) {
    final String line = raw.trimLeft();
    if (!line.startsWith(valueName)) continue;
    final int type = line.indexOf('REG_SZ');
    if (type < 0) continue;
    final String data = line.substring(type + 'REG_SZ'.length).trim();
    return data.isEmpty ? null : data;
  }
  return null;
}

class AutostartService {
  AutostartService({
    this.runKey = kRunKey,
    this.valueName = kRunValueName,
    String? executablePath,
  }) : _exePath = executablePath;

  /// Overridable so tests can use a throwaway key instead of the real Run key.
  final String runKey;
  final String valueName;
  final String? _exePath;

  String get _executable => _exePath ?? Platform.resolvedExecutable;

  /// The command currently registered, or null when autostart is off.
  Future<String?> currentCommand() async {
    if (!Platform.isWindows) return null;
    try {
      final ProcessResult r = await Process.run('reg', <String>[
        'query',
        runKey,
        '/v',
        valueName,
      ]);
      if (r.exitCode != 0) return null;
      return parseRunValue(r.stdout.toString(), valueName: valueName);
    } catch (e) {
      debugPrint('SafeScreen: could not read autostart entry: $e');
      return null;
    }
  }

  Future<bool> isEnabled() async => (await currentCommand()) != null;

  /// Turns autostart on or off. Returns whether the registry now matches.
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return false;
    try {
      final ProcessResult r =
          enabled
              ? await Process.run('reg', <String>[
                'add',
                runKey,
                '/v',
                valueName,
                '/t',
                'REG_SZ',
                '/d',
                buildRunCommand(_executable),
                '/f',
              ])
              : await Process.run('reg', <String>[
                'delete',
                runKey,
                '/v',
                valueName,
                '/f',
              ]);
      if (r.exitCode != 0) {
        debugPrint('SafeScreen: reg exited ${r.exitCode}: ${r.stderr}');
      }
      return (await isEnabled()) == enabled;
    } catch (e) {
      debugPrint('SafeScreen: could not change autostart: $e');
      return false;
    }
  }

  /// Rewrites the entry if the app has moved since it was registered.
  ///
  /// Does nothing when autostart is off — this must never turn it on.
  Future<void> repairIfMoved() async {
    final String? current = await currentCommand();
    if (current == null) return;
    final String wanted = buildRunCommand(_executable);
    if (current != wanted) {
      debugPrint('SafeScreen: app moved, updating autostart entry');
      await setEnabled(true);
    }
  }
}
