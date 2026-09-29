// The one way SafeScreen quits.
//
// Every exit path -- the title-bar close button, the tray menu, a window that
// is hidden or covered by the blackout -- goes through here, so they all behave
// the same way.

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> exitSafeScreen() async {
  // Remove the tray icon first. Windows otherwise leaves a dead icon in the
  // notification area until the pointer happens to pass over it.
  try {
    await trayManager.destroy();
  } catch (_) {}

  // destroy() rather than close(): it works whether the window is visible,
  // hidden in the tray, or fullscreen behind the blackout. The runner then
  // stops the camera, joins the capture thread and exits.
  await windowManager.setPreventClose(false);
  await windowManager.destroy();
}
