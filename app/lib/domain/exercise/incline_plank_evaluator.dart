/// Incline plank: hands on a counter, a sofa arm or a wall bar.
///
/// The whole reason this variant exists is that the body line is *not* near
/// level, so the one thing that must not be reused from the plank is its
/// horizontality gate. A correct incline plank at 35° would read as "not in
/// position" to `PlankEvaluator` on the first frame.
library;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import 'body_line_evaluator.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

class InclinePlankEvaluator extends BodyLineEvaluator {
  InclinePlankEvaluator()
      : super(
          // A degree looser than the plank on every boundary. The hands are out
          // of the body line and often at the edge of frame, the body sits
          // further from the gravity-perpendicular where the obliquity estimate
          // is slightly less well conditioned, and the elevated surface height
          // varies wildly between users. One degree of slack costs nothing
          // against a 22° broken threshold and buys back the extra measurement
          // noise.
          bands: const FormBands(degradedAt: 13, brokenAt: 23, releaseAt: 10),
          distalJoint: Joint.leftAnkle,
          breadthRatio: kShoulderBreadthOverShoulderAnkle,
          // Shoulders above ankles by anywhere from almost level to 60°, which
          // spans a low sofa arm through to a waist-high counter. The lower
          // bound sits slightly below zero so a very shallow setup is still
          // accepted — that is a harder exercise, not a cheat — while a
          // negative inclination past −5° means the feet are up and this is not
          // an incline plank.
          minInclinationDegrees: -5,
          maxInclinationDegrees: 60,
        );

  @override
  ExerciseId get id => ExerciseId.inclinePlank;

  @override
  String get displayName => 'Incline plank';

  @override
  int get thresholdVersion => 1;

  @override
  SetupRequirement get setup => const SetupRequirement(
        requiredJoints: {
          Joint.leftShoulder,
          Joint.rightShoulder,
          Joint.leftHip,
          Joint.rightHip,
          Joint.leftAnkle,
          Joint.rightAnkle,
        },
        landscape: true,
      );
}
