/// Knee plank: the same body line, cut short at the knee.
///
/// Knees down is the *point* of this variant, not a fault, so the body line
/// runs shoulder→knee and nothing checks the ankles at all.
library;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import 'body_line_evaluator.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

class KneePlankEvaluator extends BodyLineEvaluator {
  KneePlankEvaluator()
      : super(
          // Wider than the plank's 12/22/9 for two reasons that point the same
          // way. The lever is shorter — shoulder→knee is ~0.68 of
          // shoulder→ankle — so the *same* absolute hip droop produces a larger
          // angle here; judging it on the plank's numbers would silently make
          // the accessible variant the strictest exercise in the app. And the
          // people choosing it are by definition less able to hold a rigid
          // line. 14/25/11 keeps the same 3° release margin.
          bands: const FormBands(degradedAt: 14, brokenAt: 25, releaseAt: 11),
          distalJoint: Joint.leftKnee,
          breadthRatio: kShoulderBreadthOverShoulderKnee,
          // Knees on the floor put the shoulders ~45 cm above the knees over
          // ~0.92 m, around +24°, appreciably steeper than a full plank. ±40°
          // accepts that; the plank's ±30° would have rejected a correct knee
          // plank outright.
          minInclinationDegrees: -40,
          maxInclinationDegrees: 40,
          inclinationReleaseMargin: 7,
        );

  @override
  ExerciseId get id => ExerciseId.kneePlank;

  @override
  String get displayName => 'Knee plank';

  @override
  int get thresholdVersion => 1;

  @override
  SetupRequirement get setup => const SetupRequirement(
        requiredJoints: {
          Joint.leftShoulder,
          Joint.rightShoulder,
          Joint.leftHip,
          Joint.rightHip,
          Joint.leftKnee,
          Joint.rightKnee,
        },
        landscape: true,
      );
}
