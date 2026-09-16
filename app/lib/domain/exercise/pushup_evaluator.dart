/// A pushup is the plank body-line gate plus elbow cycling.
///
/// The body line is inherited wholesale rather than reimplemented — same
/// measurement, same obliquity correction, same per-user baseline — just a
/// looser band, because a pushup legitimately travels through positions a
/// static plank would call degraded.
///
/// **The accuracy problem this file exists to solve.** In a floor-level side-on
/// view the elbow and wrist are the *least* reliable landmarks on the body, not
/// the most. The forearm is underneath the torso and frequently crossing it in
/// the camera's line of sight, and the far arm is inferred from a learned prior
/// rather than seen. Treating elbow angle as authoritative would make rep
/// counting fail exactly at the bottom of a rep — the moment it most needs to
/// be right.
///
/// So depth is decided by two independent measurements, and either one counts:
/// elbow flexion, and the shoulder's descent toward the planted ankle measured
/// along gravity. The second needs nothing below the shoulder but the ankle,
/// both of which track well, so it survives the forearm being invisible.
/// Taking the union is deliberately the false-reject-minimising choice — an
/// honest rep that goes uncounted is the failure this product can least afford.
library;

import '../pose/pose_frame.dart';
import '../pose/pose_geometry.dart';
import '../session/session_machine.dart';
import 'body_line_evaluator.dart';
import 'exercise_evaluator.dart';
import 'form_hysteresis.dart';

enum PushupPhase { unknown, top, descending, bottom, ascending }

class PushupEvaluator extends BodyLineEvaluator {
  PushupEvaluator()
      : super(
          // Looser than the plank's 12/22/9. The hips travel as the arms cycle,
          // and holding a moving body to a static plank's tolerance would flag
          // honest reps.
          bands: const FormBands(degradedAt: 14, brokenAt: 20, releaseAt: 11),
          distalJoint: Joint.leftAnkle,
          breadthRatio: kShoulderBreadthOverShoulderAnkle,
          minInclinationDegrees: -30,
          maxInclinationDegrees: 30,
        );

  static const double lockoutDegrees = 160;
  static const double depthDegrees = 95;

  /// Hysteresis either side of both gates, so an elbow resting on a threshold
  /// cannot chatter the phase machine.
  static const double phaseMargin = 12;

  /// Shoulder descent toward the ankle that counts as depth, as a fraction of
  /// shoulder-to-ankle length.
  ///
  /// Derived so the two paths agree in strictness, which matters more than it
  /// first appears. For a 1.75 m adult — upper arm 0.326 m, forearm 0.256 m,
  /// shoulder-to-ankle 1.418 m — a straight arm holds the shoulder 0.411 spans
  /// above the hand, and closing the elbow to the gate's effective 107° (95°
  /// plus hysteresis) drops it by 0.079 spans.
  ///
  /// An earlier value of 0.12 came from the design's "0.55 of an upper arm"
  /// heuristic, and was wrong twice over: it sits above the 0.118 a genuine 90°
  /// elbow produces, so the path could never fire at all — and had it fired, it
  /// would have demanded 95° where the elbow path accepts 107°, holding a user
  /// to a *stricter* standard exactly when we cannot see their forearm. That is
  /// backwards. Seeing less should never cost them more.
  static const double depthTravelRatio = 0.079;

  /// Within this fraction of the top reference, the user is locked out again.
  static const double topTravelRatio = 0.035;

  /// Frames in a new band before a phase flip is accepted.
  static const int phaseFrames = 3;

  /// A full cycle faster than this is a bounce, not a rep.
  static const Duration minimumRepDuration = Duration(milliseconds: 800);

  /// Below this the elbow reading is discarded and descent decides alone.
  static const double elbowConfidenceFloor = 0.6;

  PushupPhase _phase = PushupPhase.unknown;
  int _reps = 0;
  PushupPhase _candidate = PushupPhase.unknown;
  int _candidateFrames = 0;

  Duration? _repStartedAt;
  double? _topRise;

  /// Whether this rep ever reached depth, by *either* measurement. Keyed to the
  /// phase machine rather than to travel, because when the elbow is visible it
  /// is the elbow that decides — and a travel-only check would then discard
  /// perfectly good reps.
  bool _reachedBottom = false;

  PushupPhase get phase => _phase;
  int get repCount => _reps;

  @override
  ExerciseId get id => ExerciseId.pushup;

  @override
  String get displayName => 'Pushups';

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

  @override
  void reset() {
    super.reset();
    _phase = PushupPhase.unknown;
    _reps = 0;
    _candidate = PushupPhase.unknown;
    _candidateFrames = 0;
    _repStartedAt = null;
    _topRise = null;
    _reachedBottom = false;
  }

  @override
  EvalOutput evaluate(PoseFrame frame) {
    final line = super.evaluate(frame);

    // A frame we could not read says nothing about the phase. Freeze the
    // machine rather than let a dropout invent or destroy a rep.
    if (line.verdict == FormVerdict.indeterminate ||
        line.presence == Presence.absent) {
      return _withReps(line, null);
    }

    final depth = _measureDepth(frame);
    if (depth != null) _advance(depth, frame.monotonic);

    // Breaking the body line voids the rep in progress. It never fails the
    // session, and it never takes back a rep already earned.
    if (line.verdict == FormVerdict.broken && _phase != PushupPhase.top) {
      _reachedBottom = false;
      _repStartedAt = frame.monotonic;
    }

    return _withReps(line, depth?.elbowDegrees);
  }

  EvalOutput _withReps(EvalOutput line, double? metric) => EvalOutput(
        presence: line.presence,
        verdict: line.verdict,
        faults: line.faults,
        primaryMetric: metric ?? line.primaryMetric,
        confidence: line.confidence,
        reps: _reps,
      );

  _Depth? _measureDepth(PoseFrame frame) {
    final gravity = GravityFrame.from(frame.gravity);
    if (gravity == null) return null;

    final resolver = JointResolver(frame);

    final shoulder = resolver.resolve(Joint.leftShoulder);
    final ankle = resolver.resolve(Joint.leftAnkle);
    if (shoulder == null || ankle == null) return null;

    final span = (shoulder - ankle).length;
    if (!span.isFinite || span < kMinSegmentLength) return null;

    final rise = gravity.rise(shoulder, ankle);
    if (!rise.isFinite) return null;

    final obliquity = measureObliquity(
          frame: frame,
          referenceLength: span,
          breadthRatio: kShoulderBreadthOverShoulderAnkle,
          reference: ObliquityReference.compressed,
        ) ??
        Obliquity.sideOn;

    double? elbowDegrees;
    final elbow = resolver.resolve(Joint.leftElbow);
    final wrist = resolver.resolve(Joint.leftWrist);

    // A higher bar than the resolver's floor, applied only to the forearm.
    // These two are the least trustworthy landmarks in this view, so a marginal
    // reading is discarded in favour of the descent measurement rather than
    // averaged into it.
    final elbowSeen = _bestConfidence(frame, Joint.leftElbow) >=
        elbowConfidenceFloor;
    final wristSeen = _bestConfidence(frame, Joint.leftWrist) >=
        elbowConfidenceFloor;

    if (elbow != null && wrist != null && elbowSeen && wristSeen) {
      elbowDegrees = angleBetweenDegrees(
        deskew(shoulder - elbow, gravity, obliquity.cosine),
        deskew(wrist - elbow, gravity, obliquity.cosine),
      );
    }

    return _Depth(
      elbowDegrees: elbowDegrees,
      rise: rise,
      span: span,
    );
  }

  double _travel(_Depth depth) {
    final top = _topRise;
    if (top == null) return 0;
    final travel = (top - depth.rise) / depth.span;
    return travel.isFinite && travel > 0 ? travel : 0;
  }

  bool _isTop(_Depth depth) {
    final elbow = depth.elbowDegrees;
    if (elbow != null) return elbow >= lockoutDegrees - phaseMargin;
    if (_topRise == null) return true;
    return _travel(depth) < topTravelRatio;
  }

  /// Depth by elbow flexion **or** by shoulder descent. When the forearm is
  /// hidden, descent is all there is — and it is enough.
  bool _isBottom(_Depth depth) {
    final elbow = depth.elbowDegrees;
    if (elbow != null && elbow <= depthDegrees + phaseMargin) return true;
    return _travel(depth) >= depthTravelRatio;
  }

  void _advance(_Depth depth, Duration at) {
    final atTop = _isTop(depth);
    final atBottom = _isBottom(depth);

    final proposed = switch (_phase) {
      PushupPhase.unknown => atTop ? PushupPhase.top : PushupPhase.unknown,
      PushupPhase.top => atBottom
          ? PushupPhase.bottom
          : (atTop ? PushupPhase.top : PushupPhase.descending),
      PushupPhase.descending => atBottom
          ? PushupPhase.bottom
          : (atTop ? PushupPhase.top : PushupPhase.descending),
      PushupPhase.bottom => atTop
          ? PushupPhase.top
          : (atBottom ? PushupPhase.bottom : PushupPhase.ascending),
      PushupPhase.ascending => atTop
          ? PushupPhase.top
          : (atBottom ? PushupPhase.bottom : PushupPhase.ascending),
    };

    // Lockout is the highest the shoulder gets, so the reference is a running
    // maximum taken while at the top — not the rise at the instant the phase
    // flips. Anchoring on the flip re-anchors slightly below true lockout every
    // rep, ratcheting the reference downward until achievable travel falls
    // under the threshold and counting silently stops mid-set.
    if (_phase == PushupPhase.top) {
      final anchor = _topRise;
      if (anchor == null || depth.rise > anchor) _topRise = depth.rise;
    }

    if (proposed == _phase) {
      _candidate = _phase;
      _candidateFrames = 0;
      return;
    }

    if (proposed != _candidate) {
      _candidate = proposed;
      _candidateFrames = 1;
    } else {
      _candidateFrames++;
    }

    if (_candidateFrames < phaseFrames) return;

    _enter(proposed, depth, at);
    _candidateFrames = 0;
  }

  void _enter(PushupPhase phase, _Depth depth, Duration at) {
    final previous = _phase;
    _phase = phase;

    if (phase == PushupPhase.bottom) _reachedBottom = true;
    if (phase != PushupPhase.top) return;

    final started = _repStartedAt;
    if (previous == PushupPhase.ascending &&
        started != null &&
        _reachedBottom &&
        at - started >= minimumRepDuration) {
      _reps++;
    }

    _repStartedAt = at;
    _reachedBottom = false;
  }
}

double _bestConfidence(PoseFrame frame, Joint leftVariant) {
  final near = frame[leftVariant].confidence;
  final far = frame[leftVariant.mirrored()].confidence;
  final best = near > far ? near : far;
  return best.isFinite ? best : 0;
}

class _Depth {
  const _Depth({
    required this.elbowDegrees,
    required this.rise,
    required this.span,
  });

  /// Null when the forearm landmarks were not confident enough to trust.
  final double? elbowDegrees;

  /// Shoulder height above the ankle, along gravity.
  final double rise;

  /// Shoulder-to-ankle distance, the normaliser.
  final double span;
}
