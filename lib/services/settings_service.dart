// Persisted user settings.
//
// Values are cached in memory so widget builds and the detection loop never
// touch disk; `load()` runs once at startup and each setter writes through.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  static const String _kSensitivity = 'sensitivity';
  static const String _kShoulderSurfer = 'detect_shoulder_surfers';

  SharedPreferences? _prefs;

  /// 0.0 = lenient, 1.0 = strict.
  double sensitivity = 0.75;

  /// Protect the screen when a second face appears.
  bool detectShoulderSurfers = true;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      sensitivity = (prefs.getDouble(_kSensitivity) ?? sensitivity).clamp(
        0.0,
        1.0,
      );
      detectShoulderSurfers =
          prefs.getBool(_kShoulderSurfer) ?? detectShoulderSurfers;
    } catch (e) {
      // Settings are a convenience; defaults are safe, so a failure here must
      // not stop the app from protecting the screen.
      debugPrint('SafeScreen: could not load settings: $e');
    }
  }

  Future<void> setSensitivity(double value) async {
    sensitivity = value.clamp(0.0, 1.0);
    try {
      await _prefs?.setDouble(_kSensitivity, sensitivity);
    } catch (e) {
      debugPrint('SafeScreen: could not save sensitivity: $e');
    }
  }

  Future<void> setDetectShoulderSurfers(bool value) async {
    detectShoulderSurfers = value;
    try {
      await _prefs?.setBool(_kShoulderSurfer, value);
    } catch (e) {
      debugPrint('SafeScreen: could not save shoulder-surfer setting: $e');
    }
  }
}
