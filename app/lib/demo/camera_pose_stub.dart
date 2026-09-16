import '../domain/pose/pose_frame.dart';

enum CameraStatus { unsupported, idle, starting, running, error }

/// Non-web build. Real capture on iOS and Android belongs in the native module,
/// not here — this harness only ever runs in a browser.
class CameraPose {
  CameraStatus get status => CameraStatus.unsupported;
  String get error => 'camera capture is web-only in this harness';

  void start() {}
  void stop() {}

  PoseFrame? read(Duration at) => null;
}
