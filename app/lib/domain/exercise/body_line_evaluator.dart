/// The shared machinery behind plank, knee plank and incline plank.
///
/// All three ask the same question — how far has the hip fallen away from the
/// line joining the two ends of the body, and in which direction — so all three
/// are the same code with a different distal joint, a different accepted body
/// inclination and a different band. Writing them three times would be three
/// places for the thresholds to drift apart.
library;

import 'dart:math' as math;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import '../session/session_machine.dart';
import 'evaluator_support.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

/// Frames a baseline needs before it is allowed to move the zero point. Five
/// frames is a third of a second at 15 Hz — enough to median away a bad one,
/// short enough that framing does not stall.
const int kMinCalibrationFrames = 5;

/// How far per-user calibration may move the zero point, in degrees.
///
/// The design asks for a baseline "clamped so a genuinely sagging baseline
/// can't be legitimised" without naming the number. Half the good band is the
/// defensible choice: it absorbs the real few-degree spread in neutral lumbar
/// curve and in hip-landmark placement across body types, while a user who
/// frames up at the very edge of good (12°) can still only push the good
/// boundary to 18° — inside the degraded band, never into broken. A clamp equal
/// to the good band would have let 12° + 12° = 24° read as good, which is
/// already past the broken threshold, and that is exactly the outcome the clamp
/// exists to prevent.
const double kMaxCalibrationDegrees = 6;

class _Measurement {
  const _Measurement.ok({
    required this.degrees,
    required this.obliquity,
    required this.inclination,
    required this.confidence,
  }) : failure = null;

  const _Measurement.failed(this.failure, this.confidence)
      : degrees = 0,
        obliquity = Obliquity.sideOn,
        inclination = 0;

  final MeasurementFailure? failure;
  final double degrees;
  final Obliquity obliquity;
  final double inclination;
  final double confidence;
}

abstract class BodyLineEvaluator implements ExerciseEvaluator {
  BodyLineEvaluator({
    required this.bands,
    required this.distalJoint,
    required this.breadthRatio,
    required this.minInclinationDegrees,
    required this.maxInclinationDegrees,
    this.inclinationReleaseMargin = 6,
    this.maxCalibrationDegrees = kMaxCalibrationDegrees,
  });

  /// Bands on the signed hip deviation, in degrees.
  final FormBands bands;

  /// The far end of the body line: ankle for a plank, knee for a knee plank.
  final Joint distalJoint;

  /// Shoulder breadth over this exercise's body length, for the obliquity
  /// estimate. It differs per exercise because the body length does.
  final double breadthRatio;

  /// Accepted inclination of the body line — how far the shoulder sits above
  /// the distal joint, in degrees. Outside this range the user is not in the
  /// position at all.
  final double minInclinationDegrees;
  final double maxInclinationDegrees;

  /// How much the accepted inclination range tightens before a return to "in
  /// position" is granted.
  final double inclinationReleaseMargin;

  final double maxCalibrationDegrees;

  final HysteresisLadder _ladder = HysteresisLadder();
  double _baselineDegrees = 0;
  Obliquity _fallbackObliquity = Obliquity.sideOn;

  /// The user's own zero, after clamping. Exposed for tests and for the
  /// debug fixture recorder.
  double get baselineDegrees => _baselineDegrees;

  /// The debounced level currently in force.
  FormLevel get level => FormLevel.values[_ladder.level];

  @override
  void reset() {
    _ladder.reset();
    _baselineDegrees = 0;
    _fallbackObliquity = Obliquity.sideOn;
  }

  @override
  void calibrate(List<PoseFrame> baseline) {
    final deviations = <double>[];
    final cosines = <double>[];

    for (final frame in baseline) {
      final measurement = _measure(frame);
      if (measurement.failure != null) continue;
      // Only frames that are plausibly the exercise may set the zero. Framing
      // starts before the user is in position, and a baseline taken while they
      // were still walking into shot would be worse than no baseline at all.
      if (_inclinationLevel(measurement.inclination, release: false) !=
          FormLevel.good.index) {
        continue;
      }
      if (measurement.degrees.abs() >= bands.brokenAt) continue;
      deviations.add(measurement.degrees);
      cosines.add(measurement.obliquity.cosine);
    }

    if (deviations.length < kMinCalibrationFrames) return;
    final median = medianOf(deviations);
    if (median == null) return;
    _baselineDegrees =
        median.clamp(-maxCalibrationDegrees, maxCalibrationDegrees).toDouble();

    final cosine = medianOf(cosines);
    if (cosine != null && cosine > 0 && cosine <= 1) {
      _fallbackObliquity =
          Obliquity(radiansToDegrees(math.acos(cosine)), cosine);
    }
  }

  @override
  EvalOutput evaluate(PoseFrame frame) {
    final measurement = _measure(frame);

    final failure = measurement.failure;
    if (failure != null) {
      // The voting window is held, not fed: an unreadable frame must not vote
      // on form in either direction.
      _ladder.hold();
      return outputForFailure(failure, measurement.confidence);
    }

    final deviation = measurement.degrees - _baselineDegrees;
    final magnitude = deviation.abs();

    final observed = math.max(
      _inclinationLevel(measurement.inclination, release: false),
      bands.entryLevel(magnitude),
    );
    final release = math.max(
      _inclinationLevel(measurement.inclination, release: true),
      bands.releaseLevel(magnitude),
    );

    final level =
        FormLevel.values[_ladder.update(observed: observed, release: release)];
    final fault = deviation < 0 ? FaultCode.hipSag : FaultCode.hipPike;

    return switch (level) {
      FormLevel.good => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          primaryMetric: deviation,
          confidence: measurement.confidence,
        ),
      // Degraded coaches without stopping the clock. The design's two form
      // colours are good and fault; the three bands earn their keep by making
      // the cue arrive before the credit stops, which is the whole point of
      // live coaching and is also the cheapest false-reject reduction
      // available.
      FormLevel.degraded => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          faults: {fault},
          primaryMetric: deviation,
          confidence: measurement.confidence,
        ),
      FormLevel.broken => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.broken,
          faults: {fault},
          primaryMetric: deviation,
          confidence: measurement.confidence,
        ),
      FormLevel.outOfPosition => EvalOutput(
          presence: Presence.partial,
          verdict: FormVerdict.outOfPosition,
          faults: const {FaultCode.torsoLean},
          primaryMetric: deviation,
          confidence: measurement.confidence,
        ),
    };
  }

  int _inclinationLevel(double inclination, {required bool release}) {
    final margin = release ? inclinationReleaseMargin : 0.0;
    final low = minInclinationDegrees + margin;
    final high = maxInclinationDegrees - margin;
    if (!inclination.isFinite) return FormLevel.outOfPosition.index;
    return inclination >= low && inclination <= high
        ? FormLevel.good.index
        : FormLevel.outOfPosition.index;
  }

  _Measurement _measure(PoseFrame frame) {
    if (!frame.detectionConfidence.isFinite ||
        frame.detectionConfidence < kMinDetectionConfidence ||
        frame.personCount < 1) {
      return const _Measurement.failed(MeasurementFailure.unusable, 0);
    }

    final gravity = GravityFrame.from(frame.gravity);
    if (gravity == null) {
      return const _Measurement.failed(MeasurementFailure.unusable, 0);
    }

    final side = dominantSideFor(
      frame,
      <Joint>[Joint.leftShoulder, Joint.leftHip, distalJoint],
    );
    final resolver = JointResolver(frame);
    final shoulder = resolver.resolve(onSide(Joint.leftShoulder, side));
    final hip = resolver.resolve(onSide(Joint.leftHip, side));
    final distal = resolver.resolve(onSide(distalJoint, side));
    if (shoulder == null || hip == null || distal == null) {
      return _Measurement.failed(MeasurementFailure.joints, resolver.confidence);
    }

    final apparentLength = (distal - shoulder).length;
    if (!apparentLength.isFinite || apparentLength < kMinSegmentLength) {
      return _Measurement.failed(MeasurementFailure.geometry, resolver.confidence);
    }

    final obliquity = measureObliquity(
          frame: frame,
          referenceLength: apparentLength,
          breadthRatio: breadthRatio,
          reference: ObliquityReference.compressed,
        ) ??
        _fallbackObliquity;
    if (obliquity.degrees > setup.maxObliquityDegrees) {
      return _Measurement.failed(MeasurementFailure.oblique, resolver.confidence);
    }

    final deviation = bodyLineDeviation(
      proximal: shoulder,
      middle: hip,
      distal: distal,
      gravity: gravity,
      cosObliquity: obliquity.cosine,
    );
    if (deviation == null) {
      return _Measurement.failed(MeasurementFailure.geometry, resolver.confidence);
    }

    final inclination = gravity.inclinationDegrees(shoulder - distal);
    if (inclination == null) {
      return _Measurement.failed(MeasurementFailure.geometry, resolver.confidence);
    }

    return _Measurement.ok(
      degrees: deviation.degrees,
      obliquity: obliquity,
      inclination: inclination,
      confidence: resolver.confidence,
    );
  }
}
