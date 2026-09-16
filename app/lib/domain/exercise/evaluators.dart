/// One import for the six verified exercises, plus the factory the session
/// layer uses so it never names a concrete evaluator.
///
/// Every exercise here is camera-verified with real failure conditions and
/// earns the identical reward. There is no second-class path.
library;

import 'chair_sit_to_stand_evaluator.dart';
import 'exercise_evaluator.dart';
import 'incline_plank_evaluator.dart';
import 'knee_plank_evaluator.dart';
import 'plank_evaluator.dart';
import 'seated_arm_hold_evaluator.dart';
import 'wall_sit_evaluator.dart';

export 'body_line_evaluator.dart';
export 'chair_sit_to_stand_evaluator.dart';
export 'evaluator_support.dart';
export 'exercise_evaluator.dart';
export 'form_hysteresis.dart';
export 'incline_plank_evaluator.dart';
export 'knee_plank_evaluator.dart';
export 'plank_evaluator.dart';
export 'seated_arm_hold_evaluator.dart';
export 'wall_sit_evaluator.dart';

ExerciseEvaluator evaluatorFor(ExerciseId id) => switch (id) {
      ExerciseId.plank => PlankEvaluator(),
      ExerciseId.kneePlank => KneePlankEvaluator(),
      ExerciseId.inclinePlank => InclinePlankEvaluator(),
      ExerciseId.wallSit => WallSitEvaluator(),
      ExerciseId.seatedArmHold => SeatedArmHoldEvaluator(),
      ExerciseId.chairSitToStand => ChairSitToStandEvaluator(),
    };
