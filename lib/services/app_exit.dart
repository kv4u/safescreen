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

  // close(), not destroy(). close() posts an ordinary close request, which is
  // handled the same whether the window is visible, hidden in the tray or
  // fullscreen behind the blackout. The window then shuts down in order while
  // the message loop is still running: camera stopped, capture thread joined,
  // engine shut down, then exit.
  //
  // destroy() only calls PostQuitMessage. The message loop ends with the window
  // and engine still alive, they are torn down afterwards with nothing pumping
  // messages, and the engine's shutdown stalls until internal timeouts expire --
  // five to ten seconds of a frozen app on every exit.
  await windowManager.setPreventClose(false);
  await windowManager.close();
}
