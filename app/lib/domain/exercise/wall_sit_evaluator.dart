/// Wall sit: back flat against a wall, thighs level, knees at a right angle.
///
/// The failure mode this exercise actually has is *rising* — sliding a few
/// centimetres up the wall opens the knee and takes most of the load off the
/// quads. So the measured quantity is the signed departure of the knee angle
/// from 90°, and a positive departure is the cheat.
///
/// The subject is upright, so this one frames portrait.
library;

import 'dart:math' as math;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import '../session/session_machine.dart';
import 'body_line_evaluator.dart' show kMinCalibrationFrames;
import 'evaluator_support.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

class _Measurement {
  const _Measurement.ok({
    required this.kneeDeparture,
    required this.trunkLean,
    required this.confidence,
  }) : failure = null;

  const _Measurement.failed(this.failure, this.confidence)
      : kneeDeparture = 0,
        trunkLean = 0;

  final MeasurementFailure? failure;

  /// Knee angle minus 90°. Positive means the knee has opened — the hips have
  /// risen. Negative means they have sunk below a right angle.
  final double kneeDeparture;

  /// How far the trunk is from vertical, in degrees, unsigned.
  final double trunkLean;

  final double confidence;
}

class WallSitEvaluator implements ExerciseEvaluator {
  WallSitEvaluator();

  /// A wall sit is held, not hit, and the knee landmark is among the noisier
  /// ones at five feet. 15/25/11 is looser than the plank's 12/22/9 for that
  /// reason and because 15° of knee angle is about 4 cm of slide — visible, but
  /// not yet a different exercise. Past 25° (a 115° knee) the load has moved
  /// off the quads and we stop crediting.
  static const FormBands kneeBands =
      FormBands(degradedAt: 15, brokenAt: 25, releaseAt: 11);

  static const double targetKneeDegrees = 90;

  /// Trunk further than this from vertical means they have peeled off the wall
  /// and are squatting or standing, not wall sitting.
  static const double maxTrunkLeanDegrees = 35;
  static const double trunkLeanReleaseDegrees = 28;

  /// Only trust the obliquity estimate while the trunk is near vertical; the
  /// estimate divides by trunk length, and a leaning trunk foreshortens it and
  /// would read as obliquity that is not there.
  static const double obliquityTrunkLeanLimit = 20;

  /// Same reasoning as the plank's clamp: half the good band. A user who frames
  /// up at a 105° knee cannot turn that into their new right angle.
  static const double maxCalibrationDegrees = 6;

  final HysteresisLadder _ladder = HysteresisLadder();
  double _baselineDegrees = 0;
  Obliquity _obliquity = Obliquity.sideOn;

  double get baselineDegrees => _baselineDegrees;

  FormLevel get level => FormLevel.values[_ladder.level];

  @override
  ExerciseId get id => ExerciseId.wallSit;

  @override
  String get displayName => 'Wall sit';

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
          Joint.leftAnkle,
          Joint.rightAnkle,
        },
        // An upright subject wastes most of a landscape frame and pushes the
        // head and ankles toward the short edges.
        landscape: false,
      );

  @override
  void reset() {
    _ladder.reset();
    _baselineDegrees = 0;
    _obliquity = Obliquity.sideOn;
  }

  @override
  void calibrate(List<PoseFrame> baseline) {
    final samples = <double>[];
    for (final frame in baseline) {
      final measurement = _measure(frame);
      if (measurement.failure != null) continue;
      if (measurement.trunkLean > maxTrunkLeanDegrees) continue;
      if (measurement.kneeDeparture.abs() >= kneeBands.brokenAt) continue;
      samples.add(measurement.kneeDeparture);
    }
    if (samples.length < kMinCalibrationFrames) return;
    final median = medianOf(samples);
    if (median == null) return;
    _baselineDegrees =
        median.clamp(-maxCalibrationDegrees, maxCalibrationDegrees).toDouble();
  }

  @override
  EvalOutput evaluate(PoseFrame frame) {
    final measurement = _measure(frame);
    final failure = measurement.failure;
    if (failure != null) {
      _ladder.hold();
      return outputForFailure(failure, measurement.confidence);
    }

    final departure = measurement.kneeDeparture - _baselineDegrees;
    final magnitude = departure.abs();

    final trunkEntry = measurement.trunkLean > maxTrunkLeanDegrees
        ? FormLevel.outOfPosition.index
        : FormLevel.good.index;
    final trunkRelease = measurement.trunkLean > trunkLeanReleaseDegrees
        ? FormLevel.outOfPosition.index
        : FormLevel.good.index;

    final level = FormLevel.values[_ladder.update(
      observed: math.max(trunkEntry, kneeBands.entryLevel(magnitude)),
      release: math.max(trunkRelease, kneeBands.releaseLevel(magnitude)),
    )];

    final fault =
        departure > 0 ? FaultCode.hipsRisen : FaultCode.kneesBent;

    return switch (level) {
      FormLevel.good => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          primaryMetric: departure,
          confidence: measurement.confidence,
        ),
      FormLevel.degraded => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          faults: {fault},
          primaryMetric: departure,
          confidence: measurement.confidence,
        ),
      FormLevel.broken => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.broken,
          faults: {fault},
          primaryMetric: departure,
          confidence: measurement.confidence,
        ),
      FormLevel.outOfPosition => EvalOutput(
          presence: Presence.partial,
          verdict: FormVerdict.outOfPosition,
          faults: const {FaultCode.torsoLean},
          primaryMetric: departure,
          confidence: measurement.confidence,
        ),
    };
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

    final side = dominantSideFor(frame, const <Joint>[
      Joint.leftShoulder,
      Joint.leftHip,
      Joint.leftKnee,
      Joint.leftAnkle,
    ]);
    final resolver = JointResolver(frame);
    final shoulder = resolver.resolve(onSide(Joint.leftShoulder, side));
    final hip = resolver.resolve(onSide(Joint.leftHip, side));
    final knee = resolver.resolve(onSide(Joint.leftKnee, side));
    final ankle = resolver.resolve(onSide(Joint.leftAnkle, side));
    if (shoulder == null || hip == null || knee == null || ankle == null) {
      return _Measurement.failed(
          MeasurementFailure.joints, resolver.confidence);
    }

    final trunk = shoulder - hip;
    final trunkInclination = gravity.inclinationDegrees(trunk);
    if (trunkInclination == null) {
      return _Measurement.failed(
          MeasurementFailure.geometry, resolver.confidence);
    }
    final trunkLean = (90 - trunkInclination).abs();

    if (trunkLean <= obliquityTrunkLeanLimit) {
      final measured = measureObliquity(
        frame: frame,
        referenceLength: trunk.length,
        breadthRatio: kShoulderBreadthOverTrunk,
        // The trunk is gravity-vertical here, so obliquity does not shorten it.
        reference: ObliquityReference.upright,
      );
      if (measured != null) _obliquity = measured;
    }
    if (_obliquity.degrees > setup.maxObliquityDegrees) {
      return _Measurement.failed(
          MeasurementFailure.oblique, resolver.confidence);
    }

    // Joint angles, unlike ratios, are sheared by obliquity, so the segments
    // are stretched back into the sagittal plane before the angle is taken.
    final kneeAngle = angleBetweenDegrees(
      deskew(hip - knee, gravity, _obliquity.cosine),
      deskew(ankle - knee, gravity, _obliquity.cosine),
    );
    if (kneeAngle == null) {
      return _Measurement.failed(
          MeasurementFailure.geometry, resolver.confidence);
    }

    return _Measurement.ok(
      kneeDeparture: kneeAngle - targetKneeDegrees,
      trunkLean: trunkLean,
      confidence: resolver.confidence,
    );
  }
}
