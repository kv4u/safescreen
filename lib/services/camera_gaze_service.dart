// Camera + face detection pipeline.
//
// Windows (the supported target): there is no image-stream API in
// `camera_windows`, so frames come from a self-scheduling `takePicture` loop.
// Each frame is destroyed immediately — see `secure_frame_store.dart` for why
// that matters. Detection runs in `FaceDetectionMode.fast`, which yields the
// bounding box plus six keypoints; those keypoints are converted to real head
// pose by `head_pose_estimator.dart`.
//
// Android (experimental): live image stream into ML Kit, which reports Euler
// angles and eye-open probabilities directly.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:face_detection_tflite/face_detection_tflite.dart' as tflite;

import 'gaze_detector_service.dart';
import 'head_pose_estimator.dart';
import 'secure_frame_store.dart';

class CameraGazeService {
  CameraGazeService({
    required this.gazeDetector,
    this.onGazeStateChanged,
    this.onError,
  });

  final GazeDetectorService gazeDetector;

  /// Fired only when the protected/visible state actually flips.
  final VoidCallback? onGazeStateChanged;

  /// Called on unrecoverable camera or detector errors with a readable message.
  final void Function(String message)? onError;

  CameraController? _controller;
  FaceDetector? _faceDetector;
  bool _isProcessing = false;
  int _frameCount = 0;

  // Windows
  tflite.FaceDetector? _tfliteDetector;
  final SecureFrameStore _frameStore = SecureFrameStore();
  final PitchBaseline _pitchBaseline = PitchBaseline();
  Timer? _nextCapture;
  bool _stopping = false;

  static const int _frameSkip = 2;

  /// Capture modes to try, cheapest first.
  ///
  /// Windows negotiates a mode by requiring `frame_height <= max` for the
  /// preset — 240px for `low` — at 15fps or better (see
  /// `FindBestMediaType` in capture_controller.cpp). Plenty of webcams have no
  /// mode that small; their lowest is 360p or 480p. When nothing matches, the
  /// plugin does not fall back, it fails outright with "Failed to initialize
  /// video preview", and `availableCameras()` gives no warning because
  /// enumeration never negotiates a mode.
  ///
  /// Face detection is happy with a small frame, so try low first for the CPU
  /// saving, then climb until the hardware agrees to something.
  static const List<ResolutionPreset> _resolutionLadder = <ResolutionPreset>[
    ResolutionPreset.low, // 240p
    ResolutionPreset.medium, // 480p
    ResolutionPreset.high, // 720p
    ResolutionPreset.veryHigh, // 1080p
  ];

  ResolutionPreset? _activeResolution;

  /// The mode the camera actually accepted, once running.
  ResolutionPreset? get activeResolution => _activeResolution;

  /// Sampling cadence. Faster while the screen is exposed, because that is when
  /// a missed look-away actually costs something; slower while already
  /// protected, which halves the number of frames written to disk when the user
  /// is away from the machine.
  static const Duration _intervalWhileVisible = Duration(milliseconds: 200);
  static const Duration _intervalWhileProtected = Duration(milliseconds: 400);

  bool get isRunning =>
      _controller != null &&
      (_controller!.value.isStreamingImages || _nextCapture != null);

  CameraController? get controller => _controller;

  /// Diagnostics surfaced in the UI so the user can see the capture files are
  /// actually being destroyed.
  int get framesShredded => _frameStore.shreddedCount;
  int get shredFailures => _frameStore.shredFailureCount;
  String? get captureDirectory => _frameStore.captureDirectory?.path;
  bool get isPitchCalibrated => _pitchBaseline.isCalibrated;

  Future<void> start() async {
    if (_controller != null) return;
    _stopping = false;

    final List<CameraDescription> cameras = await availableCameras();
    if (cameras.isEmpty) {
      onError?.call('No camera found on this device.');
      return;
    }
    final Iterable<CameraDescription> front = cameras.where(
      (c) => c.lensDirection == CameraLensDirection.front,
    );
    final CameraDescription camera =
        front.isNotEmpty ? front.first : cameras.first;

    _controller = await _initializeWithFallback(camera);
    if (_controller == null) return; // onError already reported

    if (Platform.isWindows) {
      await _startWindows();
    } else {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: 0.15,
        ),
      );
      await _controller!.startImageStream(_onImage);
    }
  }

  /// Opens the camera at the first mode it will accept.
  ///
  /// Each failed attempt is disposed before the next is tried — an undisposed
  /// controller keeps the device open, so skipping that would make every
  /// subsequent attempt fail with the camera already in use.
  Future<CameraController?> _initializeWithFallback(
    CameraDescription camera,
  ) async {
    Object? lastError;

    for (final ResolutionPreset preset in _resolutionLadder) {
      final CameraController candidate = CameraController(
        camera,
        preset,
        enableAudio: false,
        imageFormatGroup: Platform.isWindows ? null : ImageFormatGroup.yuv420,
      );
      try {
        await candidate.initialize();
        _activeResolution = preset;
        debugPrint('SafeScreen: camera opened at $preset');
        return candidate;
      } catch (e) {
        lastError = e;
        debugPrint('SafeScreen: $preset rejected by camera ($e)');
        try {
          await candidate.dispose();
        } catch (_) {}
      }
    }

    onError?.call(
      'The camera refused every capture mode SafeScreen tried.\n\n'
      'This usually means another app is already using it — close Teams, Zoom, '
      'or your browser and try again. Check Windows camera privacy settings '
      'too.\n\nLast error: $lastError',
    );
    return null;
  }

  // ── Windows ───────────────────────────────────────────────────────────────

  Future<void> _startWindows() async {
    try {
      final tflite.FaceDetector detector = tflite.FaceDetector();
      await detector.initialize(model: tflite.FaceDetectionModel.frontCamera);
      _tfliteDetector = detector;
    } catch (e) {
      debugPrint('SafeScreen TFLite init failed: $e');
      onError?.call('Face detection failed to initialise: $e');
      return;
    }
    _scheduleNextCapture(Duration.zero);
  }

  /// Self-scheduling instead of `Timer.periodic`: the next capture is only
  /// queued once the previous one has finished, so a slow frame can never let
  /// work pile up behind it.
  void _scheduleNextCapture(Duration delay) {
    if (_stopping) return;
    _nextCapture?.cancel();
    _nextCapture = Timer(delay, _captureAndDetectWindows);
  }

  Future<void> _captureAndDetectWindows() async {
    if (_stopping) return;
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _tfliteDetector == null) {
      return;
    }
    if (_isProcessing) {
      _scheduleNextCapture(_currentInterval);
      return;
    }

    _isProcessing = true;
    final bool wasVisible = gazeDetector.isScreenVisible;
    try {
      final XFile file = await _controller!.takePicture();
      final Uint8List? bytes = await _frameStore.takeAndShred(file.path);
      if (bytes == null) {
        gazeDetector.observeError();
      } else {
        // `fast` mode is deliberate. The package defaults to
        // FaceDetectionMode.full, which additionally runs a 468-point mesh and
        // two iris models per face — none of which this app uses.
        final List<tflite.Face> faces = await _tfliteDetector!.detectFaces(
          bytes,
          mode: tflite.FaceDetectionMode.fast,
        );
        _observeWindowsFaces(faces);
      }
    } catch (e) {
      debugPrint('SafeScreen Windows capture: $e');
      gazeDetector.observeError();
    } finally {
      _isProcessing = false;
      if (gazeDetector.isScreenVisible != wasVisible) {
        onGazeStateChanged?.call();
      }
      _scheduleNextCapture(_currentInterval);
    }
  }

  Duration get _currentInterval =>
      gazeDetector.isScreenVisible
          ? _intervalWhileVisible
          : _intervalWhileProtected;

  void _observeWindowsFaces(List<tflite.Face> faces) {
    if (faces.isEmpty) {
      gazeDetector.observe(const GazeSample.noFace());
      return;
    }

    // More than one face is itself disqualifying, so pose does not matter.
    if (faces.length > 1) {
      gazeDetector.observe(GazeSample(faceCount: faces.length));
      return;
    }

    final FaceKeypoints? keypoints = _keypointsOf(faces.first);
    if (keypoints == null) {
      // A face without usable keypoints tells us nothing about where it is
      // looking. Treat that as blindness, not as attentiveness.
      gazeDetector.observeError();
      return;
    }

    final HeadPose? pose = estimateHeadPose(keypoints);
    if (pose == null) {
      gazeDetector.observeError();
      return;
    }

    final double deviation = _pitchBaseline.deviation(pose.pitchRatio);
    gazeDetector.observe(
      GazeSample(
        faceCount: 1,
        yawDeg: pose.yaw,
        pitchDeviation: deviation,
        rollDeg: pose.roll,
      ),
    );

    // Only learn the neutral pose from frames where the user is squarely facing
    // the screen, otherwise the baseline drifts toward whatever angle they
    // happen to hold while looking away.
    if (pose.yaw.abs() < 10.0 && pose.roll.abs() < 15.0) {
      _pitchBaseline.observe(pose.pitchRatio);
    }
  }

  /// Extracts the five keypoints the pose estimator needs, or null if the
  /// detector did not supply all of them.
  FaceKeypoints? _keypointsOf(tflite.Face face) {
    final tflite.FaceLandmarks marks = face.landmarks;
    final tflite.Point? leftEye = marks.leftEye;
    final tflite.Point? rightEye = marks.rightEye;
    final tflite.Point? nose = marks.noseTip;
    final tflite.Point? leftTragion = marks.leftEyeTragion;
    final tflite.Point? rightTragion = marks.rightEyeTragion;

    if (leftEye == null ||
        rightEye == null ||
        nose == null ||
        leftTragion == null ||
        rightTragion == null) {
      return null;
    }
    return FaceKeypoints(
      leftEye: Pt(leftEye.x, leftEye.y),
      rightEye: Pt(rightEye.x, rightEye.y),
      noseTip: Pt(nose.x, nose.y),
      leftTragion: Pt(leftTragion.x, leftTragion.y),
      rightTragion: Pt(rightTragion.x, rightTragion.y),
    );
  }

  // ── Android (experimental) ────────────────────────────────────────────────

  void _onImage(CameraImage image) {
    if (_isProcessing) return;
    _frameCount++;
    if (_frameCount % _frameSkip != 0) return;

    _isProcessing = true;
    _processImage(image).whenComplete(() => _isProcessing = false);
  }

  Future<void> _processImage(CameraImage image) async {
    final bool wasVisible = gazeDetector.isScreenVisible;
    try {
      final InputImage? inputImage = _imageToInputImage(image);
      if (inputImage == null) {
        gazeDetector.observeError();
        return;
      }

      final List<Face> faces = await _faceDetector!.processImage(inputImage);
      if (faces.isEmpty) {
        gazeDetector.observe(const GazeSample.noFace());
      } else {
        final Face face = faces.first;
        gazeDetector.observe(
          GazeSample(
            faceCount: faces.length,
            yawDeg: face.headEulerAngleY,
            pitchDeg: face.headEulerAngleX,
            rollDeg: face.headEulerAngleZ,
            leftEyeOpen: face.leftEyeOpenProbability,
            rightEyeOpen: face.rightEyeOpenProbability,
          ),
        );
      }
    } catch (e) {
      debugPrint('SafeScreen processImage: $e');
      gazeDetector.observeError();
    } finally {
      if (gazeDetector.isScreenVisible != wasVisible) {
        onGazeStateChanged?.call();
      }
    }
  }

  InputImage? _imageToInputImage(CameraImage image) {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final Uint8List bytes = allBytes.done().buffer.asUint8List();
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation270deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Teardown ──────────────────────────────────────────────────────────────

  Future<void> stop() async {
    _stopping = true;
    _nextCapture?.cancel();
    _nextCapture = null;

    try {
      _tfliteDetector?.dispose();
    } catch (_) {}
    _tfliteDetector = null;

    try {
      if (_controller?.value.isStreamingImages ?? false) {
        await _controller?.stopImageStream();
      }
    } catch (_) {}
    try {
      await _controller?.dispose();
    } catch (_) {}
    try {
      await _faceDetector?.close();
    } catch (_) {}

    _controller = null;
    _faceDetector = null;
    _isProcessing = false;
    _activeResolution = null;

    // Last line of defence: destroy any capture file that outlived its read.
    await _frameStore.sweep();
  }
}
