/// The one place that decides what a *failure to measure* looks like.
///
/// Separating low confidence from bad form is the single highest-value
/// engineering decision in the product, so the mapping lives once, here, rather
/// than being re-derived in six evaluators. Every branch below returns
/// [FormVerdict.indeterminate]. None of them can return [FormVerdict.broken].
library;

import '../session/session_machine.dart';
import 'exercise_evaluator.dart';

enum MeasurementFailure {
  /// No usable skeleton, no gravity reading, nobody in frame.
  unusable,

  /// A person, but the joints this exercise needs are not visible.
  joints,

  /// A person in position, but rotated too far off side-on for 2D geometry to
  /// mean anything.
  oblique,

  /// Landmarks that produce degenerate geometry — a zero-length body, a NaN.
  geometry,
}

/// The output for a frame we could not judge.
///
/// Note what is absent: there is no path from here to [FormVerdict.broken].
/// "I cannot see you" and "your form is wrong" are different sentences, and
/// conflating them would charge the user for our perception failures.
EvalOutput outputForFailure(MeasurementFailure failure, double confidence) {
  switch (failure) {
    case MeasurementFailure.unusable:
    case MeasurementFailure.geometry:
      return EvalOutput.unusable;
    case MeasurementFailure.joints:
      return EvalOutput(
        presence: Presence.partial,
        verdict: FormVerdict.indeterminate,
        faults: const {FaultCode.outOfFrame},
        confidence: confidence,
      );
    case MeasurementFailure.oblique:
      return EvalOutput(
        presence: Presence.present,
        verdict: FormVerdict.indeterminate,
        faults: const {FaultCode.tooOblique},
        confidence: confidence,
      );
  }
}
