/// Synthetic [PoseFrame] builders for the evaluator tests.
///
/// Every builder works in a canonical frame where gravity points along +y, then
/// optionally rolls the whole thing — landmarks *and* gravity — by
/// `rollDegrees`. That is how the gravity-independence tests are written: the
/// same body, the same form, a differently-propped phone.
///
/// Obliquity is modelled the way the design derives it: rotating the subject
/// about the vertical axis by φ compresses gravity-horizontal extents by
/// `cos φ`, leaves gravity-vertical extents alone, and swings the
/// shoulder-to-shoulder line — which points straight at the camera when
/// side-on — out to an apparent `W·sin φ`.
library;

import 'dart:math' as math;

import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/pose/pose_geometry.dart';

/// Gravity in the canonical frame: image y increases downward, and so does
/// real-world down.
const Vec2 canonicalGravity = Vec2(0, 1);

/// A level direction in the canonical frame.
const Vec2 canonicalLevel = Vec2(1, 0);

/// Unit vector [degreesAboveLevel] above level, in the canonical frame.
Vec2 dirAt(double degreesAboveLevel) {
  final radians = degreesToRadians(degreesAboveLevel);
  return Vec2(math.cos(radians), -math.sin(radians));
}

/// The perpendicular-offset ratio that produces a given signed hip deviation.
///
/// Inverts `atan(δ/t) + atan(δ/(1−t))` by bisection so the tests can say "build
/// me an 18° sag" and mean it, instead of hard-coding offsets that would have
/// to move every time the lever-arm maths is touched.
double offsetRatioForDegrees(double degrees, {double hipFraction = 0.45}) {
  if (degrees <= 0) return 0;
  double at(double ratio) => radiansToDegrees(
        math.atan(ratio / hipFraction) + math.atan(ratio / (1 - hipFraction)),
      );
  var low = 0.0;
  var high = 20.0;
  for (var i = 0; i < 200; i++) {
    final mid = (low + high) / 2;
    if (at(mid) < degrees) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2;
}

PoseFrame frameOf(
  Map<Joint, Landmark> landmarks, {
  Vec2 gravity = canonicalGravity,
  Duration monotonic = Duration.zero,
  double detectionConfidence = 0.95,
  int personCount = 1,
  double rollDegrees = 0,
}) {
  final frame = PoseFrame(
    monotonic: monotonic,
    landmarks: landmarks,
    gravity: gravity,
    detectionConfidence: detectionConfidence,
    personCount: personCount,
  );
  return rollDegrees == 0 ? frame : rolled(frame, rollDegrees);
}

/// Rotates landmarks and gravity together — the phone knocked onto its side
/// with the user unchanged.
PoseFrame rolled(PoseFrame frame, double degrees) {
  final radians = degreesToRadians(degrees);
  final cosine = math.cos(radians);
  final sine = math.sin(radians);
  Vec2 rotate(Vec2 v) =>
      Vec2(v.x * cosine - v.y * sine, v.x * sine + v.y * cosine);

  return PoseFrame(
    monotonic: frame.monotonic,
    landmarks: {
      for (final entry in frame.landmarks.entries)
        entry.key: Landmark(
          rotate(entry.value.position).x,
          rotate(entry.value.position).y,
          entry.value.confidence,
        ),
    },
    gravity: rotate(frame.gravity),
    detectionConfidence: frame.detectionConfidence,
    personCount: frame.personCount,
  );
}

/// A shoulder→hip→distal body line, for the three plank variants.
PoseFrame bodyLineFrame({
  Joint distal = Joint.leftAnkle,
  double deviationDegrees = 0,
  double inclinationDegrees = 13,
  double obliquityDegrees = 0,
  double bodyLength = 0.6,
  double hipFraction = 0.45,
  double breadthRatio = kShoulderBreadthOverShoulderAnkle,
  double confidence = 0.9,
  double farShoulderConfidence = 0.7,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
  double detectionConfidence = 0.95,
  int personCount = 1,
  bool mirrored = false,
  Map<Joint, Landmark> extra = const {},
}) {
  final phi = degreesToRadians(obliquityDegrees);
  final apparentLength = bodyLength * math.cos(phi);

  final axis = dirAt(-inclinationDegrees);
  final perpendicularUp = Vec2(axis.y, -axis.x);

  const shoulder = Vec2(0.30, 0.45);
  final distalPoint = shoulder + axis * apparentLength;

  final ratio = offsetRatioForDegrees(
    deviationDegrees.abs(),
    hipFraction: hipFraction,
  );
  final sign = deviationDegrees < 0 ? -1.0 : 1.0;
  final hip = shoulder +
      axis * (hipFraction * apparentLength) +
      perpendicularUp * (sign * ratio * bodyLength);

  // The far shoulder swings out along the same image direction the body runs,
  // because both are horizontal and both rotate about the same vertical axis.
  final separation = breadthRatio * bodyLength * math.sin(phi);
  final farShoulder = shoulder + canonicalLevel * separation;

  Joint side(Joint left) => mirrored ? left.mirrored() : left;

  return frameOf(
    {
      side(Joint.leftShoulder):
          Landmark(shoulder.x, shoulder.y, confidence),
      side(Joint.rightShoulder):
          Landmark(farShoulder.x, farShoulder.y, farShoulderConfidence),
      side(Joint.leftHip): Landmark(hip.x, hip.y, confidence),
      side(distal): Landmark(distalPoint.x, distalPoint.y, confidence),
      ...extra,
    },
    monotonic: monotonic,
    detectionConfidence: detectionConfidence,
    personCount: personCount,
    rollDegrees: rollDegrees,
  );
}

PoseFrame plankFrame({
  double deviationDegrees = 0,
  double inclinationDegrees = 13,
  double obliquityDegrees = 0,
  double confidence = 0.9,
  double farShoulderConfidence = 0.7,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
  double detectionConfidence = 0.95,
  int personCount = 1,
  bool mirrored = false,
  Map<Joint, Landmark> extra = const {},
}) =>
    bodyLineFrame(
      deviationDegrees: deviationDegrees,
      inclinationDegrees: inclinationDegrees,
      obliquityDegrees: obliquityDegrees,
      confidence: confidence,
      farShoulderConfidence: farShoulderConfidence,
      rollDegrees: rollDegrees,
      monotonic: monotonic,
      detectionConfidence: detectionConfidence,
      personCount: personCount,
      mirrored: mirrored,
      extra: extra,
    );

PoseFrame kneePlankFrame({
  double deviationDegrees = 0,
  double inclinationDegrees = 24,
  double obliquityDegrees = 0,
  double confidence = 0.9,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
}) =>
    bodyLineFrame(
      distal: Joint.leftKnee,
      deviationDegrees: deviationDegrees,
      inclinationDegrees: inclinationDegrees,
      obliquityDegrees: obliquityDegrees,
      bodyLength: 0.42,
      breadthRatio: kShoulderBreadthOverShoulderKnee,
      confidence: confidence,
      rollDegrees: rollDegrees,
      monotonic: monotonic,
    );

PoseFrame inclinePlankFrame({
  double deviationDegrees = 0,
  double inclinationDegrees = 35,
  double obliquityDegrees = 0,
  double confidence = 0.9,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
}) =>
    bodyLineFrame(
      deviationDegrees: deviationDegrees,
      inclinationDegrees: inclinationDegrees,
      obliquityDegrees: obliquityDegrees,
      confidence: confidence,
      rollDegrees: rollDegrees,
      monotonic: monotonic,
    );

/// An upright, seated-against-a-wall body: ankle below knee, thigh set by the
/// knee angle, trunk set by the lean.
PoseFrame wallSitFrame({
  double kneeAngleDegrees = 90,
  double trunkLeanDegrees = 0,
  double obliquityDegrees = 0,
  double thighLength = 0.18,
  double shinLength = 0.18,
  double trunkLength = 0.22,
  double confidence = 0.9,
  double farShoulderConfidence = 0.7,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
  double detectionConfidence = 0.95,
  int personCount = 1,
  Set<Joint> omit = const {},
}) {
  const knee = Vec2(0.5, 0.55);
  final ankle = knee + dirAt(-90) * shinLength;
  final hip = knee + dirAt(kneeAngleDegrees - 90) * thighLength;
  final shoulder = hip + dirAt(90 - trunkLeanDegrees) * trunkLength;

  final phi = degreesToRadians(obliquityDegrees);
  final cosine = math.cos(phi);
  Vec2 compress(Vec2 point) {
    final offset = point - knee;
    return knee + Vec2(offset.x * cosine, offset.y);
  }

  final compressedShoulder = compress(shoulder);
  final separation =
      kShoulderBreadthOverTrunk * trunkLength * math.sin(phi);
  final farShoulder = compressedShoulder + canonicalLevel * separation;

  final landmarks = <Joint, Landmark>{
    Joint.leftShoulder: Landmark(
        compressedShoulder.x, compressedShoulder.y, confidence),
    Joint.rightShoulder:
        Landmark(farShoulder.x, farShoulder.y, farShoulderConfidence),
    Joint.leftHip: _at(compress(hip), confidence),
    Joint.leftKnee: _at(compress(knee), confidence),
    Joint.leftAnkle: _at(compress(ankle), confidence),
  }..removeWhere((joint, _) => omit.contains(joint));

  return frameOf(
    landmarks,
    monotonic: monotonic,
    detectionConfidence: detectionConfidence,
    personCount: personCount,
    rollDegrees: rollDegrees,
  );
}

/// The same body, used for chair sit-to-stand where the knee angle sweeps.
PoseFrame sitToStandFrame({
  required double kneeAngleDegrees,
  required Duration monotonic,
  double trunkLeanDegrees = 0,
  double confidence = 0.9,
  double rollDegrees = 0,
  double detectionConfidence = 0.95,
  Set<Joint> omit = const {},
}) =>
    wallSitFrame(
      kneeAngleDegrees: kneeAngleDegrees,
      trunkLeanDegrees: trunkLeanDegrees,
      confidence: confidence,
      rollDegrees: rollDegrees,
      monotonic: monotonic,
      detectionConfidence: detectionConfidence,
      omit: omit,
    );

/// Shoulder, elbow and wrist only by default — the wheelchair case, where the
/// lower body may be behind a footplate, a desk or a blanket.
PoseFrame seatedArmFrame({
  double elevationDegrees = 0,
  double elbowBendDegrees = 0,
  double armLength = 0.30,
  bool includeLowerBody = false,
  double trunkLength = 0.22,
  double obliquityDegrees = 0,
  double confidence = 0.9,
  double farShoulderConfidence = 0.7,
  double? farArmElevationDegrees,
  double farArmConfidence = 0.8,
  double rollDegrees = 0,
  Duration monotonic = Duration.zero,
  double detectionConfidence = 0.95,
  int personCount = 1,
  Set<Joint> omit = const {},
}) {
  const shoulder = Vec2(0.45, 0.40);
  final half = armLength / 2;

  (Vec2, Vec2) arm(double elevation) {
    final elbow =
        shoulder + dirAt(elevation + elbowBendDegrees / 2) * half;
    final wrist = elbow + dirAt(elevation - elbowBendDegrees / 2) * half;
    return (elbow, wrist);
  }

  final phi = degreesToRadians(obliquityDegrees);
  final cosine = math.cos(phi);
  Vec2 compress(Vec2 point) {
    final offset = point - shoulder;
    return shoulder + Vec2(offset.x * cosine, offset.y);
  }

  final (elbow, wrist) = arm(elevationDegrees);

  final landmarks = <Joint, Landmark>{
    Joint.leftShoulder: _at(shoulder, confidence),
    Joint.leftElbow: _at(compress(elbow), confidence),
    Joint.leftWrist: _at(compress(wrist), confidence),
  };

  if (farArmElevationDegrees != null) {
    final (farElbow, farWrist) = arm(farArmElevationDegrees);
    // The far shoulder is all but coincident with the near one when side-on.
    landmarks[Joint.rightShoulder] = _at(shoulder, farArmConfidence);
    landmarks[Joint.rightElbow] = _at(compress(farElbow), farArmConfidence);
    landmarks[Joint.rightWrist] = _at(compress(farWrist), farArmConfidence);
  }

  if (includeLowerBody) {
    final hip = shoulder + dirAt(-90) * trunkLength;
    final separation =
        kShoulderBreadthOverTrunk * trunkLength * math.sin(phi);
    landmarks[Joint.leftHip] = _at(compress(hip), confidence);
    landmarks[Joint.rightShoulder] =
        _at(shoulder + canonicalLevel * separation, farShoulderConfidence);
  }

  landmarks.removeWhere((joint, _) => omit.contains(joint));

  return frameOf(
    landmarks,
    monotonic: monotonic,
    detectionConfidence: detectionConfidence,
    personCount: personCount,
    rollDegrees: rollDegrees,
  );
}

Landmark _at(Vec2 point, double confidence) =>
    Landmark(point.x, point.y, confidence);

/// A frame full of garbage, for fuzzing. Nothing here should ever throw, and
/// nothing here should ever come back as bad form.
PoseFrame garbageFrame(math.Random random) {
  double wild() {
    switch (random.nextInt(8)) {
      case 0:
        return double.nan;
      case 1:
        return double.infinity;
      case 2:
        return double.negativeInfinity;
      case 3:
        return 0;
      case 4:
        return 1e18;
      case 5:
        return -1e18;
      default:
        return random.nextDouble() * 2 - 0.5;
    }
  }

  final landmarks = <Joint, Landmark>{};
  for (final joint in Joint.values) {
    if (random.nextBool()) continue;
    landmarks[joint] = Landmark(
      wild(),
      wild(),
      random.nextInt(5) == 0 ? wild() : random.nextDouble(),
    );
  }

  return PoseFrame(
    monotonic: Duration(milliseconds: random.nextInt(100000) - 500),
    landmarks: landmarks,
    gravity: Vec2(wild(), wild()),
    detectionConfidence: random.nextInt(4) == 0 ? wild() : random.nextDouble(),
    personCount: random.nextInt(4) - 1,
  );
}
