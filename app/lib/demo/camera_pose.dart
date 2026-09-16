/// Real camera pose, where the platform has one.
///
/// Web gets a MediaPipe-backed implementation; everything else gets a stub,
/// because on device this job belongs to the native module rather than to a
/// demo harness.
library;

export 'camera_pose_stub.dart'
    if (dart.library.js_interop) 'camera_pose_web.dart';
