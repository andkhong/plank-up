/// Seated arm hold: sit tall, arms extended forward at shoulder height, hold.
///
/// This is the evaluator that has to work for a wheelchair user, and the way it
/// does that is by **not asking about the lower body at all**. No hips, no
/// knees, no ankles, in [setup] or in [evaluate]. A chair back, a footplate or a
/// blanket over the legs must not be able to stop someone earning their unlock.
///
/// Arms extended *forward* rather than laterally, because the camera is side-on
/// and a lateral raise points both arms straight at the lens, where its apparent
/// length collapses and nothing can be measured. The exercise is specified to
/// suit the geometry we have.
///
/// Two ways to make it easier, both checked: letting the arms drift down, and
/// bending the elbows.
library;

import 'dart:math' as math;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import '../session/session_machine.dart';
import 'body_line_evaluator.dart' show kMinCalibrationFrames;
import 'evaluator_support.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

class _ArmReading {
  const _ArmReading({
    required this.elevation,
    required this.elbowBend,
    required this.confidence,
  });

  /// Angle of shoulder→wrist away from level, in degrees. Negative is dropped.
  final double elevation;

  /// How far the elbow is from straight, in degrees. 0 is locked out.
  final double elbowBend;

  final double confidence;
}

class _Measurement {
  const _Measurement.ok(this.reading, this.confidence)
      : failure = null,
        foreshortened = false;

  const _Measurement.failed(this.failure, this.confidence)
      : reading = null,
        foreshortened = false;

  const _Measurement.foreshortenedArm(this.confidence)
      : failure = null,
        reading = null,
        foreshortened = true;

  final MeasurementFailure? failure;
  final _ArmReading? reading;
  final bool foreshortened;
  final double confidence;
}

class SeatedArmHoldEvaluator implements ExerciseEvaluator {
  SeatedArmHoldEvaluator();

  /// Dropping the arms is the cheat, so the downward band is the tight one:
  /// good within 15° below level, degraded to 25°, broken past that. For a
  /// 63 cm arm, 15° is about 16 cm of droop at the wrist — plainly visible, and
  /// well outside shoulder-landmark noise.
  static const FormBands dropBands =
      FormBands(degradedAt: 15, brokenAt: 25, releaseAt: 11);

  /// Holding the arms *above* shoulder height is more work, not less, so the
  /// upward band is deliberately generous. It exists only to notice that
  /// someone has stopped doing this exercise and started doing another one.
  static const FormBands raiseBands =
      FormBands(degradedAt: 25, brokenAt: 40, releaseAt: 20);

  /// Measured as departure from a straight arm, so 0 is locked out. Good to
  /// 20° (a 160° elbow), broken past 35° (145°), by which point the forearm is
  /// carrying nothing.
  static const FormBands elbowBands =
      FormBands(degradedAt: 20, brokenAt: 35, releaseAt: 15);

  /// Beyond this the arm is by the user's side and they have stopped.
  static const double outOfPositionElevation = 60;
  static const double outOfPositionRelease = 52;

  /// Apparent shoulder→wrist length as a fraction of the two segment lengths.
  /// A straight arm scores 1 and a right-angled elbow about 0.7; anything this
  /// low means the arm is pointing at the camera, which is a framing problem,
  /// not a form problem.
  static const double minExtensionRatio = 0.25;

  /// Confidence the *far* arm must clear before it is allowed to fail the user.
  /// In a side-on view the far arm is occluded and the model infers it from a
  /// learned prior; a hallucinated limb must never cost anyone their hold.
  static const double farArmConfidence = 0.6;

  static const double maxCalibrationDegrees = 6;

  final HysteresisLadder _ladder = HysteresisLadder();
  double _baselineDegrees = 0;
  Obliquity _obliquity = Obliquity.sideOn;

  double get baselineDegrees => _baselineDegrees;

  FormLevel get level => FormLevel.values[_ladder.level];

  @override
  ExerciseId get id => ExerciseId.seatedArmHold;

  @override
  String get displayName => 'Seated arm hold';

  @override
  int get thresholdVersion => 1;

  @override
  SetupRequirement get setup => const SetupRequirement(
        // Upper body only, on purpose. Adding hips here would silently exclude
        // every wheelchair user, which is the population this exercise exists
        // for.
        requiredJoints: {
          Joint.leftShoulder,
          Joint.rightShoulder,
          Joint.leftElbow,
          Joint.rightElbow,
          Joint.leftWrist,
          Joint.rightWrist,
        },
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
      final reading = measurement.reading;
      if (reading == null) continue;
      if (reading.elevation < -dropBands.brokenAt) continue;
      if (reading.elevation > raiseBands.brokenAt) continue;
      samples.add(reading.elevation);
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
    if (measurement.foreshortened) {
      _ladder.hold();
      return EvalOutput(
        presence: Presence.present,
        verdict: FormVerdict.indeterminate,
        faults: const {FaultCode.notSideOn},
        confidence: measurement.confidence,
      );
    }

    final reading = measurement.reading!;
    final elevation = reading.elevation - _baselineDegrees;

    final observed = math.max(
      _elevationLevel(elevation, release: false),
      elbowBands.entryLevel(reading.elbowBend),
    );
    final release = math.max(
      _elevationLevel(elevation, release: true),
      elbowBands.releaseLevel(reading.elbowBend),
    );

    final level =
        FormLevel.values[_ladder.update(observed: observed, release: release)];

    final fault = elbowBands.entryLevel(reading.elbowBend) >
            _elevationLevel(elevation, release: false)
        ? FaultCode.noLockout
        : FaultCode.armsDropped;

    return switch (level) {
      FormLevel.good => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          primaryMetric: elevation,
          confidence: reading.confidence,
        ),
      FormLevel.degraded => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.good,
          faults: {fault},
          primaryMetric: elevation,
          confidence: reading.confidence,
        ),
      FormLevel.broken => EvalOutput(
          presence: Presence.present,
          verdict: FormVerdict.broken,
          faults: {fault},
          primaryMetric: elevation,
          confidence: reading.confidence,
        ),
      FormLevel.outOfPosition => EvalOutput(
          presence: Presence.partial,
          verdict: FormVerdict.outOfPosition,
          faults: const {FaultCode.armsDropped},
          primaryMetric: elevation,
          confidence: reading.confidence,
        ),
    };
  }

  int _elevationLevel(double elevation, {required bool release}) {
    if (!elevation.isFinite) return FormLevel.good.index;
    final limit = release ? outOfPositionRelease : outOfPositionElevation;
    if (elevation.abs() > limit) return FormLevel.outOfPosition.index;
    if (elevation < 0) {
      final magnitude = -elevation;
      return release
          ? dropBands.releaseLevel(magnitude)
          : dropBands.entryLevel(magnitude);
    }
    return release
        ? raiseBands.releaseLevel(elevation)
        : raiseBands.entryLevel(elevation);
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

    _updateObliquity(frame, gravity);
    if (_obliquity.degrees > setup.maxObliquityDegrees) {
      return const _Measurement.failed(MeasurementFailure.oblique, 0);
    }

    final near = dominantSideFor(frame, const <Joint>[
      Joint.leftShoulder,
      Joint.leftElbow,
      Joint.leftWrist,
    ]);
    final far = near == BodySide.left ? BodySide.right : BodySide.left;

    final readings = <_ArmReading>[];
    var foreshortened = false;
    var bestConfidence = 0.0;

    for (final entry in <(BodySide, double)>[
      (near, kMinJointConfidence),
      (far, farArmConfidence),
    ]) {
      final arm = _readArm(frame, gravity, entry.$1, entry.$2);
      if (arm == null) continue;
      bestConfidence = math.max(bestConfidence, arm.confidence);
      if (arm.elbowBend.isNaN) {
        foreshortened = true;
        continue;
      }
      readings.add(arm);
    }

    // Last resort: the near side failed its floor but the far side is at least
    // present. Better a low-confidence measurement than refusing to evaluate.
    if (readings.isEmpty && !foreshortened) {
      final fallback = _readArm(frame, gravity, far, kMinJointConfidence);
      if (fallback != null) {
        bestConfidence = math.max(bestConfidence, fallback.confidence);
        if (fallback.elbowBend.isNaN) {
          foreshortened = true;
        } else {
          readings.add(fallback);
        }
      }
    }

    if (readings.isEmpty) {
      return foreshortened
          ? _Measurement.foreshortenedArm(bestConfidence)
          : _Measurement.failed(MeasurementFailure.joints, bestConfidence);
    }

    // Both arms are supposed to be up. Judge on whichever is worse, so dropping
    // one arm is not free.
    readings.sort((a, b) => _severity(b).compareTo(_severity(a)));
    return _Measurement.ok(readings.first, readings.first.confidence);
  }

  int _severity(_ArmReading reading) => math.max(
        _elevationLevel(reading.elevation - _baselineDegrees, release: false),
        elbowBands.entryLevel(reading.elbowBend),
      );

  void _updateObliquity(PoseFrame frame, GravityFrame gravity) {
    // Hips are optional here, so obliquity is refined only when they happen to
    // be visible. When they are not — a wheelchair, a blanket, a desk — the
    // estimate stays at whatever framing left it, and per-user calibration
    // absorbs the residual systematic offset instead.
    final resolver = JointResolver(frame);
    final shoulder = resolver.resolve(Joint.leftShoulder);
    final hip = resolver.resolve(Joint.leftHip);
    if (shoulder == null || hip == null) return;
    final trunk = shoulder - hip;
    final inclination = gravity.inclinationDegrees(trunk);
    if (inclination == null || (90 - inclination).abs() > 20) return;
    final measured = measureObliquity(
      frame: frame,
      referenceLength: trunk.length,
      breadthRatio: kShoulderBreadthOverTrunk,
      reference: ObliquityReference.upright,
    );
    if (measured != null) _obliquity = measured;
  }

  /// Reads one arm, or null when its three landmarks are not all above
  /// [minConfidence]. A returned reading with a NaN [_ArmReading.elbowBend]
  /// means the arm is pointing at the camera and cannot be measured.
  _ArmReading? _readArm(
    PoseFrame frame,
    GravityFrame gravity,
    BodySide side,
    double minConfidence,
  ) {
    final shoulder = frame[onSide(Joint.leftShoulder, side)];
    final elbow = frame[onSide(Joint.leftElbow, side)];
    final wrist = frame[onSide(Joint.leftWrist, side)];
    for (final landmark in [shoulder, elbow, wrist]) {
      if (!landmark.confidence.isFinite) return null;
      if (landmark.confidence < minConfidence) return null;
      if (!isFiniteVec(landmark.position)) return null;
    }
    final confidence =
        (shoulder.confidence + elbow.confidence + wrist.confidence) / 3;

    final upper = elbow.position - shoulder.position;
    final fore = wrist.position - elbow.position;
    final whole = wrist.position - shoulder.position;
    final spans = upper.length + fore.length;
    if (!spans.isFinite || spans < kMinSegmentLength) return null;
    if (!whole.length.isFinite) return null;
    if (whole.length / spans < minExtensionRatio) {
      return _ArmReading(
        elevation: 0,
        elbowBend: double.nan,
        confidence: confidence.clamp(0.0, 1.0).toDouble(),
      );
    }

    final elevation =
        gravity.inclinationDegrees(deskew(whole, gravity, _obliquity.cosine));
    final elbowAngle = angleBetweenDegrees(
      deskew(shoulder.position - elbow.position, gravity, _obliquity.cosine),
      deskew(wrist.position - elbow.position, gravity, _obliquity.cosine),
    );
    if (elevation == null || elbowAngle == null) return null;

    return _ArmReading(
      elevation: elevation,
      elbowBend: 180 - elbowAngle,
      confidence: confidence.clamp(0.0, 1.0).toDouble(),
    );
  }
}
