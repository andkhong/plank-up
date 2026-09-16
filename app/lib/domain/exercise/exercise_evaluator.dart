/// The seam that makes every exercise interchangeable to the session machine.
///
/// The machine consumes only [EvalOutput]; it never knows whether the user is
/// holding a plank, a wall sit or a seated arm hold. Accessibility is the
/// product's differentiator, so this abstraction is load-bearing from day one
/// rather than speculative.
library;

import '../pose/pose_frame.dart';
import '../session/session_machine.dart';

enum ExerciseId {
  plank,
  kneePlank,
  inclinePlank,
  wallSit,
  seatedArmHold,
  chairSitToStand,
}

enum FaultCode {
  hipSag,
  hipPike,
  shoulderCollapse,
  kneesBent,
  kneesDropped,
  torsoLean,
  armsDropped,
  hipsRisen,
  notSideOn,
  tooOblique,
  outOfFrame,
  lowConfidence,
  shallowDepth,
  noLockout,
}

/// Whether the user is recognisably attempting the exercise at all.
enum Presence { present, partial, absent }

class EvalOutput {
  const EvalOutput({
    required this.presence,
    required this.verdict,
    this.faults = const {},
    this.primaryMetric,
    this.confidence = 1.0,
  });

  final Presence presence;
  final FormVerdict verdict;
  final Set<FaultCode> faults;

  /// The single number the UI visualises — signed hip deviation for holds,
  /// joint angle for the others. Positive and negative carry meaning per
  /// evaluator; see each implementation.
  final double? primaryMetric;

  final double confidence;

  static const EvalOutput unusable = EvalOutput(
    presence: Presence.absent,
    verdict: FormVerdict.indeterminate,
    faults: {FaultCode.lowConfidence},
    confidence: 0,
  );
}

/// What the framing gate must confirm before a countdown may start.
class SetupRequirement {
  const SetupRequirement({
    required this.requiredJoints,
    required this.landscape,
    this.requiresFaceVisible = true,
    this.maxObliquityDegrees = 35,
  });

  final Set<Joint> requiredJoints;

  /// Frame orientation is a property of the exercise: a horizontal body wants
  /// landscape, an upright one wants portrait.
  final bool landscape;

  /// BlazePose uses a face detector as its person-detector proxy and assumes a
  /// visible head. A tucked chin at floor level can drop detection entirely, so
  /// the gate refuses to start rather than beginning a timer about to evaporate.
  final bool requiresFaceVisible;

  /// Beyond this many degrees off side-on, 2D angle measurement stops being
  /// trustworthy and the gate asks the user to reposition.
  final double maxObliquityDegrees;
}

abstract class ExerciseEvaluator {
  ExerciseId get id;

  String get displayName;

  SetupRequirement get setup;

  /// Bumped whenever thresholds change, so a stored attempt records which rules
  /// judged it.
  int get thresholdVersion;

  /// Clears per-attempt state. Evaluators are stateful across frames only for
  /// smoothing and hysteresis; they hold nothing that outlives an attempt.
  void reset();

  /// Records the user's own baseline during framing, so deviation is measured
  /// against their body rather than a population average.
  void calibrate(List<PoseFrame> baseline);

  /// Pure given internal state. Must never throw on degenerate input — a
  /// missing joint or a zero-length body yields [EvalOutput.unusable].
  EvalOutput evaluate(PoseFrame frame);
}
