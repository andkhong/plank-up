/// The reference implementation every other evaluator is measured against.
library;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import 'body_line_evaluator.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

class PlankEvaluator extends BodyLineEvaluator {
  PlankEvaluator()
      : super(
          // Straight from the design: good ≤12°, degraded 12–22°, broken >22°,
          // release at 9°. At a hip fraction of ~0.45 these correspond to a
          // perpendicular hip offset of roughly 5%, 10% and 4% of body length —
          // about 7 cm, 13 cm and 5.5 cm for a 1.75 m adult.
          bands: const FormBands(degradedAt: 12, brokenAt: 22, releaseAt: 9),
          distalJoint: Joint.leftAnkle,
          breadthRatio: kShoulderBreadthOverShoulderAnkle,
          // A real floor plank runs shoulders ~40 cm up, ankles ~8 cm up over
          // ~1.35 m, so about +13°. ±30° accepts that with margin either way
          // (it also accepts a decline plank, which is strictly harder) and
          // rejects a standing or kneeling body.
          minInclinationDegrees: -30,
          maxInclinationDegrees: 30,
        );

  @override
  ExerciseId get id => ExerciseId.plank;

  @override
  String get displayName => 'Plank';

  @override
  int get thresholdVersion => 1;

  @override
  SetupRequirement get setup => const SetupRequirement(
        // Listed as pairs: the evaluator needs one camera-facing side, and the
        // framing gate should treat a pair as satisfied when either member is
        // confident. Both shoulders matter for a second reason — the obliquity
        // estimate is the separation between them.
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
