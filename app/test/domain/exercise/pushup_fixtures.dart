import 'dart:math' as math;

import 'package:plank_up/domain/pose/pose_frame.dart';

import 'evaluator_fixtures.dart';

/// A pushup built from real proportions, the way one actually happens: the
/// ankle is planted, the hand is planted, and the shoulder descends between
/// them. The elbow angle *follows* from that geometry rather than being
/// asserted. Faking the angle directly would let a test pass against an
/// evaluator that could never work on a body.
///
/// Scaled from a 1.75 m adult: upper arm 0.326 m, forearm 0.256 m, shoulder to
/// ankle 1.418 m. At lockout the shoulder sits a straight arm above the hand;
/// at a 90° elbow it has descended by 0.118 of the shoulder-ankle span, which
/// is where the evaluator's travel threshold comes from.
const double _span = 0.55;
const double _upperArm = 0.326 / 1.418 * _span;
const double _forearm = 0.256 / 1.418 * _span;
const double _armStraight = _upperArm + _forearm;

/// Shoulder descent from lockout to a 90° elbow.
final double _fullDescent =
    _armStraight - math.sqrt(_upperArm * _upperArm + _forearm * _forearm);

const Vec2 _ankle = Vec2(0.86, 0.60);

/// The planted hand: directly below the shoulder at lockout, and fixed in space
/// for the whole rep. Everything about the descent follows from this not moving.
final Vec2 _hand = Vec2(
  _ankle.x - math.sqrt(_span * _span - _armStraight * _armStraight),
  _ankle.y,
);

/// [depth] runs 0 at lockout to 1 at a 90° elbow.
PoseFrame pushupFrame({
  required double depth,
  double confidence = 0.9,
  double forearmConfidence = 0.9,
  double deviationDegrees = 0,
  Duration monotonic = Duration.zero,
}) {
  final d = depth.clamp(0.0, 1.0);

  final rise = _armStraight - _fullDescent * d;
  final run = math.sqrt(math.max(_span * _span - rise * rise, 1e-9));
  final shoulder = Vec2(_ankle.x - run, _ankle.y - rise);

  final axis = (_ankle - shoulder).normalized;
  final perpendicular = axis.perpendicular;

  // Hip offset for the requested body-line deviation, matching the convention
  // the plank fixtures use.
  final ratio = offsetRatioForDegrees(deviationDegrees.abs());
  final sign = deviationDegrees < 0 ? 1.0 : -1.0;
  final hip = shoulder + axis * (_span * 0.45) + perpendicular * (ratio * _span * sign);
  final knee = shoulder + axis * (_span * 0.72);

  final elbow = _elbowBetween(shoulder, _hand, _upperArm, _forearm);

  final head = shoulder - axis * (_span * 0.18);

  Landmark lm(Vec2 p, double c) => Landmark(p.x, p.y, c);
  final far = confidence * 0.7;

  return frameOf(
    {
      Joint.nose: lm(head, confidence),
      Joint.leftEar: lm(head, confidence),
      Joint.rightEar: lm(head, far),
      Joint.leftShoulder: lm(shoulder, confidence),
      Joint.rightShoulder: lm(shoulder, far),
      Joint.leftElbow: lm(elbow, forearmConfidence),
      Joint.rightElbow: lm(elbow, forearmConfidence * 0.7),
      Joint.leftWrist: lm(_hand, forearmConfidence),
      Joint.rightWrist: lm(_hand, forearmConfidence * 0.7),
      Joint.leftHip: lm(hip, confidence),
      Joint.rightHip: lm(hip, far),
      Joint.leftKnee: lm(knee, confidence),
      Joint.rightKnee: lm(knee, far),
      Joint.leftAnkle: lm(_ankle, confidence),
      Joint.rightAnkle: lm(_ankle, far),
    },
    monotonic: monotonic,
  );
}

/// Intersection of the circle of radius [a] about [s] with the circle of radius
/// [f] about [w] — the physically possible elbow positions. Picks the one bent
/// away from the torso.
Vec2 _elbowBetween(Vec2 s, Vec2 w, double a, double f) {
  final delta = w - s;
  final d = delta.length;
  if (d < 1e-9) return s;
  if (d >= a + f) return s + delta.normalized * a;

  final along = (a * a - f * f + d * d) / (2 * d);
  final heightSq = a * a - along * along;
  final height = heightSq > 0 ? math.sqrt(heightSq) : 0.0;
  final unit = delta.normalized;
  return s + unit * along + unit.perpendicular * height;
}

/// One full rep as a frame stream.
List<PoseFrame> pushupRep({
  required Duration start,
  Duration descent = const Duration(milliseconds: 700),
  Duration ascent = const Duration(milliseconds: 700),
  double bottomDepth = 1.0,
  double forearmConfidence = 0.9,
  int fps = 30,
}) {
  final frames = <PoseFrame>[];
  final step = Duration(milliseconds: (1000 / fps).round());

  void sweep(Duration span, double from, double to) {
    final count = math.max(span.inMilliseconds ~/ step.inMilliseconds, 2);
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      frames.add(pushupFrame(
        depth: from + (to - from) * t,
        forearmConfidence: forearmConfidence,
        monotonic: start + step * frames.length,
      ));
    }
  }

  sweep(descent, 0, bottomDepth);
  sweep(ascent, bottomDepth, 0);
  return frames;
}

/// Holds lockout, so a rep can be closed and the next begun.
List<PoseFrame> pushupTop({
  required Duration start,
  Duration span = const Duration(milliseconds: 400),
  double forearmConfidence = 0.9,
  int fps = 30,
}) {
  final frames = <PoseFrame>[];
  final step = Duration(milliseconds: (1000 / fps).round());
  final count = math.max(span.inMilliseconds ~/ step.inMilliseconds, 1);
  for (var i = 0; i < count; i++) {
    frames.add(pushupFrame(
      depth: 0,
      forearmConfidence: forearmConfidence,
      monotonic: start + step * i,
    ));
  }
  return frames;
}
