import 'dart:js_interop';

import '../domain/pose/pose_frame.dart';

enum CameraStatus { unsupported, idle, starting, running, ended, error }

enum PoseSource { none, camera, file }

@JS('plankupPose')
external _Bridge? get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external void start();
  external void startFile();
  external void stop();
  external JSString status();
  external JSString error();
  external JSString source();
  external JSString label();
  external JSNumber progress();
  external void setRecording(bool on);
  external JSNumber recordedFrames();
  external void downloadFixture(JSString? name);
  external JSArray<JSNumber>? latest();
}

/// Reads landmarks produced by `web/pose_bridge.js`.
///
/// The bridge emits exactly the fifteen joints of the canonical schema, in
/// `Joint.values` order, as a flat `[x, y, visibility]` triple per joint —
/// the same shape the platform channel will carry on device. Pixels stay on
/// the JS side; only this array crosses.
class CameraPose {
  List<double>? _last;

  CameraStatus get status {
    final b = _bridge;
    if (b == null) return CameraStatus.unsupported;
    return switch (b.status().toDart) {
      'starting' => CameraStatus.starting,
      'running' => CameraStatus.running,
      'ended' => CameraStatus.ended,
      'error' => CameraStatus.error,
      _ => CameraStatus.idle,
    };
  }

  PoseSource get source => switch (_bridge?.source().toDart) {
        'camera' => PoseSource.camera,
        'file' => PoseSource.file,
        _ => PoseSource.none,
      };

  String get error => _bridge?.error().toDart ?? 'pose bridge not loaded';

  String get label => _bridge?.label().toDart ?? '';

  double get progress => _bridge?.progress().toDartDouble ?? 0;

  int get recordedFrames => _bridge?.recordedFrames().toDartInt ?? 0;

  void start() => _bridge?.start();

  /// Opens a file picker and runs the same pipeline over a recorded clip.
  /// Reproducible input at the real geometry, without needing a body on a floor.
  void startFile() => _bridge?.startFile();

  void stop() => _bridge?.stop();

  void setRecording(bool on) => _bridge?.setRecording(on);

  void downloadFixture([String? name]) =>
      _bridge?.downloadFixture(name?.toJS);

  PoseFrame? read(Duration at) {
    final raw = _bridge?.latest();
    if (raw == null) return null;

    final flat = raw.toDart.map((n) => n.toDartDouble).toList(growable: false);
    if (flat.length < Joint.values.length * 3) return null;

    // Hold the previous reading when inference has not produced a new one, so
    // a slow frame reads as "unchanged" rather than as the body vanishing.
    _last = flat;

    final landmarks = <Joint, Landmark>{};
    var confidenceSum = 0.0;
    for (var i = 0; i < Joint.values.length; i++) {
      final x = flat[i * 3];
      final y = flat[i * 3 + 1];
      final v = flat[i * 3 + 2];
      landmarks[Joint.values[i]] = Landmark(x, y, v);
      confidenceSum += v;
    }

    return PoseFrame(
      monotonic: at,
      landmarks: landmarks,
      // A laptop webcam is upright and fixed, so image-space down is world
      // down. On device this comes from the accelerometer, because a phone
      // propped on a floor is at an arbitrary angle and "up" must be measured.
      gravity: const Vec2(0, 1),
      detectionConfidence: confidenceSum / Joint.values.length,
    );
  }

  bool get hasEverSeenBody => _last != null;
}
