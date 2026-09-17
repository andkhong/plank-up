import '../domain/pose/pose_frame.dart';

enum CameraStatus { unsupported, idle, starting, running, ended, error }

enum PoseSource { none, camera, file }

/// Non-web build. Real capture on iOS and Android belongs in the native module,
/// not here — this harness only ever runs in a browser.
class CameraPose {
  CameraStatus get status => CameraStatus.unsupported;
  PoseSource get source => PoseSource.none;
  String get error => 'camera capture is web-only in this harness';
  String get label => '';
  double get progress => 0;
  int get recordedFrames => 0;

  void start() {}
  void startFile() {}
  void stop() {}
  void setRecording(bool on) {}
  void downloadFixture([String? name]) {}

  PoseFrame? read(Duration at) => null;
}
