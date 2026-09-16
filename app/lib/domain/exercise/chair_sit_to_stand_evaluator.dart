/// Chair sit-to-stand: the one rep-counted exercise in v1.
///
/// Reps are where false positives live. Someone shifting their weight, leaning
/// forward to scratch an ankle, or rocking to build momentum must count
/// **zero** — a rep counter that can be shuffled is worse than no rep counter,
/// because it turns the whole product into a formality. So every phase change
/// needs three consecutive frames to commit, a rep needs both ends of the
/// movement to be reached in order, and a too-fast transition is thrown away.
///
/// The design's hold-vs-rep asymmetry is honoured exactly: a bad rep **voids
/// the rep and cues**. It never pauses the clock and it never fails anything.
/// The only thing that stops the clock here is leaving the exercise, which
/// includes sitting motionless past the stall watchdog.
library;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import '../session/session_machine.dart';
import 'body_line_evaluator.dart' show kMinCalibrationFrames;
import 'evaluator_support.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

enum SitToStandPhase {
  /// Nothing committed yet this attempt.
  unknown,
  seated,
  rising,
  standing,
  lowering,
}

class _Measurement {
  const _Measurement.ok(this.kneeAngle, this.confidence) : failure = null;

  const _Measurement.failed(this.failure, this.confidence) : kneeAngle = 0;

  final MeasurementFailure? failure;
  final double kneeAngle;
  final double confidence;
}

class ChairSitToStandEvaluator implements ExerciseEvaluator {
  ChairSitToStandEvaluator();

  /// Knee angle at or below which the user counts as seated, before
  /// calibration. Chair height moves this a long way, which is what
  /// [calibrate] is for.
  static const double defaultSeatedAt = 100;

  /// Knee angle at or above which the user counts as stood up. A true standing
  /// knee is 175–180°; 160° leaves room for landmark noise and for people who
  /// do not fully lock out, without accepting a half-squat.
  static const double standAt = 160;

  /// How far past the seated threshold the knee must open before we believe a
  /// rise has started, and how far below the standing threshold it must fall
  /// before we believe a descent has. Stops a single band boundary generating
  /// phase chatter.
  static const double phaseMargin = 15;

  /// Frames a phase change needs, on top of the margins. Three frames is
  /// ~200 ms at 15 Hz.
  static const int framesToCommit = 3;

  /// A seated→standing transition faster than this is not a person standing up.
  static const Duration minHalfRep = Duration(milliseconds: 300);

  /// No committed phase change for this long means they have stopped. Straight
  /// from the design's stall watchdog.
  static const Duration stallAfter = Duration(seconds: 20);

  /// How long a voided-rep cue stays on the output so the UI can speak it.
  static const Duration cueHoldsFor = Duration(milliseconds: 1500);

  /// Frame gaps longer than this are credited to nobody, exactly as the session
  /// machine treats them. Without it, a dropped pipeline would manufacture a
  /// stall.
  static const Duration maxFrameGap = Duration(milliseconds: 400);

  /// Chair heights genuinely vary by more than a plank's lumbar curve does, so
  /// this clamp is wider than the holds' — but it is still a clamp, and the
  /// absolute bounds below mean no chair can turn a shallow bob into a rep.
  static const double maxCalibrationDegrees = 12;
  static const double minSeatedThreshold = 88;
  static const double maxSeatedThreshold = 112;

  final HysteresisLadder _ladder = HysteresisLadder();

  double _seatedAt = defaultSeatedAt;
  Obliquity _obliquity = Obliquity.sideOn;

  SitToStandPhase _phase = SitToStandPhase.unknown;
  int _reps = 0;

  int _belowSeated = 0;
  int _aboveStand = 0;
  int _aboveRise = 0;
  int _belowLower = 0;

  Duration? _lastMonotonic;
  Duration _sinceProgress = Duration.zero;
  Duration _inPhase = Duration.zero;
  Duration _sinceCue = Duration.zero;
  FaultCode? _cue;

  SitToStandPhase get phase => _phase;

  int get repCount => _reps;

  /// The seated commit threshold actually in force, after calibration.
  double get seatedThreshold => _seatedAt;

  FormLevel get level => FormLevel.values[_ladder.level];

  @override
  ExerciseId get id => ExerciseId.chairSitToStand;

  @override
  String get displayName => 'Chair sit-to-stand';

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
        landscape: false,
      );

  @override
  void reset() {
    _ladder.reset();
    _seatedAt = defaultSeatedAt;
    _obliquity = Obliquity.sideOn;
    _phase = SitToStandPhase.unknown;
    _reps = 0;
    _belowSeated = 0;
    _aboveStand = 0;
    _aboveRise = 0;
    _belowLower = 0;
    _lastMonotonic = null;
    _sinceProgress = Duration.zero;
    _inPhase = Duration.zero;
    _sinceCue = Duration.zero;
    _cue = null;
  }

  @override
  void calibrate(List<PoseFrame> baseline) {
    final samples = <double>[];
    for (final frame in baseline) {
      final measurement = _measure(frame);
      if (measurement.failure != null) continue;
      // Only frames where they are actually sitting set the seated reference.
      if (measurement.kneeAngle > standAt - phaseMargin) continue;
      samples.add(measurement.kneeAngle);
    }
    if (samples.length < kMinCalibrationFrames) return;
    final median = medianOf(samples);
    if (median == null) return;
    final shifted = median + 10;
    _seatedAt = shifted
        .clamp(minSeatedThreshold, maxSeatedThreshold)
        .clamp(
          defaultSeatedAt - maxCalibrationDegrees,
          defaultSeatedAt + maxCalibrationDegrees,
        )
        .toDouble();
  }

  @override
  EvalOutput evaluate(PoseFrame frame) {
    final measurement = _measure(frame);
    final delta = _advanceClock(frame.monotonic);

    final failure = measurement.failure;
    if (failure != null) {
      _ladder.hold();
      // A dropout is not a stall and is not a missed rep. Nothing about the
      // phase state changes, the stall clock does not run, and the rep count
      // carries through — reps already earned can never be taken back by our
      // failure to see.
      final base = outputForFailure(failure, measurement.confidence);
      return EvalOutput(
        presence: base.presence,
        verdict: base.verdict,
        faults: base.faults,
        primaryMetric: base.primaryMetric,
        confidence: base.confidence,
        reps: _reps,
      );
    }

    _sinceProgress += delta;
    _inPhase += delta;
    if (_cue != null) {
      _sinceCue += delta;
      if (_sinceCue >= cueHoldsFor) _cue = null;
    }

    _step(measurement.kneeAngle);

    final stalled = _sinceProgress >= stallAfter;
    final level = FormLevel.values[_ladder.update(
      observed:
          stalled ? FormLevel.outOfPosition.index : FormLevel.good.index,
      release:
          stalled ? FormLevel.outOfPosition.index : FormLevel.good.index,
    )];

    final faults = <FaultCode>{?_cue};

    return EvalOutput(
      presence: level == FormLevel.outOfPosition
          ? Presence.partial
          : Presence.present,
      verdict: level == FormLevel.outOfPosition
          ? FormVerdict.outOfPosition
          : FormVerdict.good,
      faults: faults,
      primaryMetric: measurement.kneeAngle,
      confidence: measurement.confidence,
      reps: _reps,
    );
  }

  /// One frame of the phase machine. Every transition needs
  /// [framesToCommit] consecutive supporting frames.
  void _step(double kneeAngle) {
    _belowSeated = kneeAngle <= _seatedAt ? _belowSeated + 1 : 0;
    _aboveStand = kneeAngle >= standAt ? _aboveStand + 1 : 0;
    _aboveRise = kneeAngle > _seatedAt + phaseMargin ? _aboveRise + 1 : 0;
    _belowLower = kneeAngle < standAt - phaseMargin ? _belowLower + 1 : 0;

    switch (_phase) {
      case SitToStandPhase.unknown:
        if (_belowSeated >= framesToCommit) {
          _enter(SitToStandPhase.seated);
        } else if (_aboveStand >= framesToCommit) {
          _enter(SitToStandPhase.standing);
        }
      case SitToStandPhase.seated:
        if (_aboveRise >= framesToCommit) _enter(SitToStandPhase.rising);
      case SitToStandPhase.rising:
        if (_aboveStand >= framesToCommit) {
          // The rep is only real if the movement took a plausible amount of
          // time. Anything faster is a landmark glitch or a rock, not a stand.
          if (_inPhase >= minHalfRep) {
            _reps++;
          } else {
            _raiseCue(FaultCode.shallowDepth);
          }
          _enter(SitToStandPhase.standing);
        } else if (_belowSeated >= framesToCommit) {
          // Sat back down without ever standing up. Void and cue; never fail.
          _raiseCue(FaultCode.noLockout);
          _enter(SitToStandPhase.seated);
        }
      case SitToStandPhase.standing:
        if (_belowLower >= framesToCommit) _enter(SitToStandPhase.lowering);
      case SitToStandPhase.lowering:
        if (_belowSeated >= framesToCommit) {
          _enter(SitToStandPhase.seated);
        } else if (_aboveStand >= framesToCommit) {
          // Bobbed without sitting back down. The next rep still has to reach
          // the seat, so shuffling on the spot accumulates nothing.
          _raiseCue(FaultCode.shallowDepth);
          _enter(SitToStandPhase.standing);
        }
    }
  }

  void _enter(SitToStandPhase phase) {
    _phase = phase;
    _sinceProgress = Duration.zero;
    _inPhase = Duration.zero;
  }

  void _raiseCue(FaultCode fault) {
    _cue = fault;
    _sinceCue = Duration.zero;
  }

  Duration _advanceClock(Duration monotonic) {
    final last = _lastMonotonic;
    _lastMonotonic = monotonic;
    if (last == null) return Duration.zero;
    final delta = monotonic - last;
    if (delta.isNegative) return Duration.zero;
    return delta > maxFrameGap ? Duration.zero : delta;
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
    final inclination = gravity.inclinationDegrees(trunk);
    if (inclination != null && (90 - inclination).abs() <= 20) {
      // The trunk swings forward during the movement, which foreshortens it and
      // would read as obliquity. Only refresh the estimate while it is upright.
      final measured = measureObliquity(
        frame: frame,
        referenceLength: trunk.length,
        breadthRatio: kShoulderBreadthOverTrunk,
        reference: ObliquityReference.upright,
      );
      if (measured != null) _obliquity = measured;
    }
    if (_obliquity.degrees > setup.maxObliquityDegrees) {
      return _Measurement.failed(
          MeasurementFailure.oblique, resolver.confidence);
    }

    final kneeAngle = angleBetweenDegrees(
      deskew(hip - knee, gravity, _obliquity.cosine),
      deskew(ankle - knee, gravity, _obliquity.cosine),
    );
    if (kneeAngle == null) {
      return _Measurement.failed(
          MeasurementFailure.geometry, resolver.confidence);
    }

    return _Measurement.ok(kneeAngle, resolver.confidence);
  }
}
