// In-memory webcam capture via Media Foundation.
//
// SafeScreen's default capture path goes through `camera_windows`, whose only
// way to obtain a frame is takePicture() -- which encodes a JPEG to disk before
// Dart ever sees it. For a tool whose whole purpose is privacy, writing
// thousands of photographs of the user to the filesystem is the wrong default,
// however quickly they are erased afterwards.
//
// This reads frames straight out of Media Foundation into a buffer and hands
// them to Dart over a method channel. Nothing touches the disk.
//
// It is deliberately additive: Dart tries this first and falls back to the
// existing takePicture path if anything here fails, so a machine where Media
// Foundation misbehaves keeps working exactly as before.

#ifndef RUNNER_MF_CAMERA_H_
#define RUNNER_MF_CAMERA_H_

#include <flutter/binary_messenger.h>

// Registers the "safescreen/camera" method channel on the engine's messenger.
//
// Methods:
//   start(deviceName: String?) -> {width: int, height: int, device: String}
//   grab()                     -> {bytes: Uint8List, width, height, stride}
//   stop()                     -> null
void RegisterMfCameraChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_MF_CAMERA_H_
