/// Stands in for the camera until there is one.
///
/// Produces a plausible side-on plank at a requested hip deviation so the real
/// evaluator and the real session machine can be driven end to end without a
/// device. Deliberately lives outside `lib/domain/`, which stays pure.
library;

import 'dart:math' as math;

import '../domain/pose/pose_frame.dart';

const double _hipFraction = 0.45;

/// Perpendicular hip offset that produces [deviationDegrees] of bend at the
/// hip, solved rather than approximated so the slider reads true.
double _offsetForDeviation(double deviationDegrees, double bodyLength) {
  final target = deviationDegrees.abs() * math.pi / 180;
  if (target < 1e-9) return 0;

  double bendFor(double offset) =>
      math.atan(offset / (_hipFraction * bodyLength)) +
      math.atan(offset / ((1 - _hipFraction) * bodyLength));

  var low = 0.0;
  var high = bodyLength;
  for (var i = 0; i < 40; i++) {
    final mid = (low + high) / 2;
    if (bendFor(mid) < target) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2;
}

/// A side-on plank. Negative [deviationDegrees] sags toward the floor,
/// positive pikes away from it.
PoseFrame syntheticPlank({
  required Duration at,
  double deviationDegrees = 0,
  double bodyLength = 0.62,
  double confidence = 0.95,
  bool faceVisible = true,
}) {
  const centre = Vec2(0.5, 0.52);
  const axis = Vec2(1, 0);
  const down = Vec2(0, 1);

  final half = bodyLength / 2;
  final shoulder = centre + axis * -half;
  final ankle = centre + axis * half;

  final offset = _offsetForDeviation(deviationDegrees, bodyLength);
  final signed = deviationDegrees < 0 ? offset : -offset;
  final hip = shoulder + axis * (bodyLength * _hipFraction) + down * signed;

  final knee = shoulder + axis * (bodyLength * 0.72) + down * (signed * 0.45);
  final elbow = shoulder + axis * (bodyLength * 0.02) + down * 0.11;
  final wrist = shoulder + axis * (bodyLength * -0.10) + down * 0.13;
  final nose = shoulder + axis * (bodyLength * -0.20) + down * -0.04;
  final ear = shoulder + axis * (bodyLength * -0.15) + down * -0.01;

  Landmark at2(Vec2 p, [double? c]) => Landmark(p.x, p.y, c ?? confidence);

  // The far side sits behind the near one and the model infers it from a prior,
  // so it is emitted at lower confidence — which is exactly the condition the
  // evaluators are built to distrust.
  final far = confidence * 0.55;

  return PoseFrame(
    monotonic: at,
    gravity: down,
    detectionConfidence: confidence,
    landmarks: {
      Joint.nose: faceVisible ? at2(nose) : Landmark.absent,
      Joint.leftEar: faceVisible ? at2(ear) : Landmark.absent,
      Joint.rightEar: faceVisible ? at2(ear, far) : Landmark.absent,
      Joint.leftShoulder: at2(shoulder),
      Joint.rightShoulder: at2(shoulder, far),
      Joint.leftElbow: at2(elbow),
      Joint.rightElbow: at2(elbow, far),
      Joint.leftWrist: at2(wrist),
      Joint.rightWrist: at2(wrist, far),
      Joint.leftHip: at2(hip),
      Joint.rightHip: at2(hip, far),
      Joint.leftKnee: at2(knee),
      Joint.rightKnee: at2(knee, far),
      Joint.leftAnkle: at2(ankle),
      Joint.rightAnkle: at2(ankle, far),
    },
  );
}

/// What the camera sends when it cannot find anybody.
PoseFrame emptyFrame(Duration at) => PoseFrame(
      monotonic: at,
      gravity: const Vec2(0, 1),
      detectionConfidence: 0.05,
      landmarks: const {},
    );
