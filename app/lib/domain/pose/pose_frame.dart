/// One inference result, normalised into a backend-agnostic shape.
///
/// iOS emits 19 joints via Vision, Android 33 via MediaPipe. Both adapters map
/// onto the canonical set below before anything crosses the platform channel,
/// so evaluators never learn which backend produced a frame.
///
/// Camera pixels never appear here. Native owns capture and inference and sends
/// roughly 20 KB/s of landmarks; shipping frames would be ~13.8 MB/s.
library;

import 'dart:math' as math;

enum Joint {
  nose,
  leftEar,
  rightEar,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
}

enum BodySide { left, right }

extension JointSide on Joint {
  Joint mirrored() => switch (this) {
        Joint.leftEar => Joint.rightEar,
        Joint.rightEar => Joint.leftEar,
        Joint.leftShoulder => Joint.rightShoulder,
        Joint.rightShoulder => Joint.leftShoulder,
        Joint.leftElbow => Joint.rightElbow,
        Joint.rightElbow => Joint.leftElbow,
        Joint.leftWrist => Joint.rightWrist,
        Joint.rightWrist => Joint.leftWrist,
        Joint.leftHip => Joint.rightHip,
        Joint.rightHip => Joint.leftHip,
        Joint.leftKnee => Joint.rightKnee,
        Joint.rightKnee => Joint.leftKnee,
        Joint.leftAnkle => Joint.rightAnkle,
        Joint.rightAnkle => Joint.leftAnkle,
        Joint.nose => Joint.nose,
      };
}

/// A 2D point in normalised image space, origin top-left, y increasing downward.
class Landmark {
  const Landmark(this.x, this.y, this.confidence);

  final double x;
  final double y;
  final double confidence;

  static const Landmark absent = Landmark(0, 0, 0);

  Vec2 get position => Vec2(x, y);
}

class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator *(double scalar) => Vec2(x * scalar, y * scalar);

  double get length => math.sqrt(x * x + y * y);
  double dot(Vec2 other) => x * other.x + y * other.y;

  /// Positive when [other] lies counter-clockwise of this vector.
  double cross(Vec2 other) => x * other.y - y * other.x;

  Vec2 get normalized {
    final len = length;
    return len == 0 ? const Vec2(0, 0) : Vec2(x / len, y / len);
  }

  Vec2 get perpendicular => Vec2(-y, x);
}

class PoseFrame {
  const PoseFrame({
    required this.monotonic,
    required this.landmarks,
    required this.gravity,
    required this.detectionConfidence,
    this.personCount = 1,
  });

  final Duration monotonic;
  final Map<Joint, Landmark> landmarks;

  /// Measured "down" in image space, from the accelerometer. The phone is
  /// propped at an arbitrary angle on the floor, so image-space up cannot be
  /// assumed — it has to be measured. Every geometric check is taken relative
  /// to this, which is what makes the evaluators orientation-independent.
  final Vec2 gravity;

  final double detectionConfidence;

  /// Vision reports multiple bodies; MediaPipe is single-person and reports 1.
  final int personCount;

  Landmark operator [](Joint joint) => landmarks[joint] ?? Landmark.absent;

  bool has(Joint joint, {double minConfidence = 0.5}) =>
      this[joint].confidence >= minConfidence;

  bool hasAll(Iterable<Joint> joints, {double minConfidence = 0.5}) =>
      joints.every((j) => has(j, minConfidence: minConfidence));

  /// Mean confidence over one side's shoulder, hip, knee and ankle. Used to
  /// pick the camera-facing side, since in a true side-on view the far limbs
  /// are occluded but still emitted by the model.
  double sideConfidence(BodySide side) {
    final joints = side == BodySide.left
        ? const [
            Joint.leftShoulder,
            Joint.leftHip,
            Joint.leftKnee,
            Joint.leftAnkle
          ]
        : const [
            Joint.rightShoulder,
            Joint.rightHip,
            Joint.rightKnee,
            Joint.rightAnkle
          ];
    final total =
        joints.fold<double>(0, (sum, j) => sum + this[j].confidence);
    return total / joints.length;
  }
}
