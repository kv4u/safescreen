import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_screen/services/autostart.dart';

void main() {
  group('buildRunCommand', () {
    test('quotes the executable path and appends the flag', () {
      expect(
        buildRunCommand(r'C:\Apps\SafeScreen\safe_screen.exe'),
        r'"C:\Apps\SafeScreen\safe_screen.exe" --autostart',
      );
    });

    test('keeps a path with spaces intact inside the quotes', () {
      // The default unzip location usually has a space in it. Unquoted, a Run
      // entry like this is broken and a well-known hijack vector.
      expect(
        buildRunCommand(r'C:\Users\a b\Downloads\SafeScreen\safe_screen.exe'),
        r'"C:\Users\a b\Downloads\SafeScreen\safe_screen.exe" --autostart',
      );
    });
  });

  group('parseRunValue', () {
    test('extracts the command from reg query output', () {
      const String out =
          '\r\n'
          r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
          '\r\n'
          r'    SafeScreen    REG_SZ    "C:\Apps\SafeScreen\safe_screen.exe" --autostart'
          '\r\n\r\n';

      expect(
        parseRunValue(out),
        r'"C:\Apps\SafeScreen\safe_screen.exe" --autostart',
      );
    });

    test('ignores other programs registered under the same key', () {
      const String out =
          '\n'
          r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
          '\n'
          r'    OneDrive    REG_SZ    "C:\OneDrive.exe" /background'
          '\n'
          r'    SafeScreen    REG_SZ    "C:\S\safe_screen.exe" --autostart'
          '\n';

      expect(parseRunValue(out), r'"C:\S\safe_screen.exe" --autostart');
    });

    test('returns null when the value is absent', () {
      const String out =
          '\n'
          r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
          '\n'
          r'    OneDrive    REG_SZ    "C:\OneDrive.exe"'
          '\n';

      expect(parseRunValue(out), isNull);
    });

    test('returns null for empty output', () {
      expect(parseRunValue(''), isNull);
    });
  });

  group(
    'registry round trip',
    () {
      // Throwaway key, never the real Run key. Runs only in CI, so a local
      // `flutter test` does not write to the developer's registry.
      const String testKey = r'HKCU\Software\SafeScreenAutostartTest';
      const String exe = r'C:\Program Files\Safe Screen\safe_screen.exe';

      final AutostartService service = AutostartService(
        runKey: testKey,
        executablePath: exe,
      );

      tearDown(() async {
        await Process.run('reg', <String>['delete', testKey, '/f']);
      });

      test(
        'a quoted path with spaces survives the trip through reg.exe',
        () async {
          // This is the risky part: Dart escapes arguments on Windows, reg.exe
          // unescapes them, and an error in either direction would store a
          // broken command that silently never starts the app.
          expect(await service.setEnabled(true), isTrue);
          expect(await service.currentCommand(), buildRunCommand(exe));
        },
      );

      test('disabling removes the entry', () async {
        await service.setEnabled(true);
        expect(await service.setEnabled(false), isTrue);
        expect(await service.isEnabled(), isFalse);
      });

      test('repairIfMoved rewrites a stale path', () async {
        await AutostartService(
          runKey: testKey,
          executablePath: r'C:\Old Location\safe_screen.exe',
        ).setEnabled(true);

        await service.repairIfMoved();

        expect(await service.currentCommand(), buildRunCommand(exe));
      });

      test('repairIfMoved never turns autostart on', () async {
        await service.repairIfMoved();
        expect(await service.isEnabled(), isFalse);
      });
    },
    skip:
        Platform.isWindows && Platform.environment['CI'] == 'true'
            ? false
            : 'writes to the registry; runs only on Windows CI',
  );
}
