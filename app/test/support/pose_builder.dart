/// Synthetic pose generation.
///
/// Builds a [PoseFrame] for a body at a *specified* geometry, so evaluator
/// thresholds can be swept exhaustively without a human on the floor. This is
/// the third fixture tier the design asks for: landmark recordings prove we
/// handle real noise, synthetic streams prove we handle the whole parameter
/// space including corners a recording session would never happen to produce.
///
/// ## What you say, and what you get
///
/// ```dart
/// // "8 degrees of hip sag, 20 degrees oblique, phone rolled 15 degrees"
/// final frame = const PoseBuilder(
///   hipDeviationDegrees: -8,
///   obliquityDegrees: 20,
///   phoneRollDegrees: 15,
/// ).build();
/// ```
///
/// [PoseBuilder.annotate] returns the same frame plus the ground truth that
/// produced it, so a test can assert that an evaluator recovered the number it
/// was handed.
///
/// ## Conventions, stated once because everything downstream depends on them
///
/// * **Hip deviation is signed and measured in degrees of bend at the hip**:
///   `180° - angle(shoulder, hip, ankle)`. A straight body is 0°.
///   **Negative is sag** (hips toward the floor, i.e. along gravity),
///   **positive is pike** (hips away from the floor). This is the design's
///   "signed normalized hip deviation" expressed as an angle; the equivalent
///   normalized perpendicular offset is exposed as
///   [SyntheticPose.normalizedHipOffset] so an evaluator using the ratio form
///   can be checked against the same frame.
///
/// * **Obliquity is rotation off side-on, about the gravity axis.** Under the
///   orthographic model used here, an obliquity of φ foreshortens the body axis
///   to `L·cos φ`, separates the near and far limbs by `W·sin φ` *along that
///   same axis*, and leaves the hip's perpendicular offset **unchanged**. That
///   reproduces the design's `δ_measured = δ_true / cos φ` exactly: obliquity
///   inflates the measurement by a pure scalar and does not shear it. It also
///   reproduces the recovery route — `shoulderSeparation / apparentBodyLength`
///   is `(W/L)·tan φ`, which is where `cos φ` comes back from.
///
/// * **Gravity is measured, never assumed.** The body is laid out in a
///   gravity-aligned frame and the whole scene — landmarks *and* the gravity
///   vector — is then rotated by [PoseBuilder.phoneRollDegrees]. A rolled frame
///   and an unrolled one describe the same body, which is the property that
///   makes orientation-independence testable: evaluate both, demand the same
///   answer.
///
/// * **Image space** is normalised, origin top-left, y increasing *downward*,
///   matching [Landmark]. Positive roll therefore rotates the scene clockwise
///   on screen.
///
/// ## What is exact and what is merely plausible
///
/// Shoulder, hip, ankle, gravity, obliquity and confidence are **exact** — they
/// are solved for, not eyeballed, and [SyntheticPose] reports the closed-loop
/// ground truth. Elbow, wrist, ear and nose placement is **plausible anatomy,
/// not measured anatomy**; it exists so face-visibility and shoulder-collapse
/// gates have something to look at. Do not pin a threshold to it. Override
/// [BodyProportions] if a test needs those joints to be load-bearing.
library;

import 'dart:math' as math;

import 'package:plank_up/domain/pose/pose_frame.dart';

/// Where each joint sits along the body, as a fraction of shoulder→ankle
/// length. `axial` runs from the shoulder (0) toward the ankle (1) and may be
/// negative for joints beyond the head. `normal` runs along gravity, so
/// positive is toward the floor.
class BodyProportions {
  const BodyProportions({
    this.hipAxial = 0.45,
    this.kneeAxial = 0.72,
    this.shoulderWidthRatio = 0.26,
    this.elbowAxial = 0.02,
    this.elbowNormal = 0.11,
    this.wristAxial = -0.10,
    this.wristNormal = 0.13,
    this.noseAxial = -0.20,
    this.noseNormal = 0.04,
    this.earAxial = -0.15,
    this.earNormal = -0.01,
  });

  /// Hip position along shoulder→ankle. The bend-angle solve depends on this,
  /// so changing it changes the offset a given deviation implies.
  final double hipAxial;
  final double kneeAxial;

  /// Biacromial width as a fraction of body length. Drives how fast the near
  /// and far limbs separate with obliquity.
  final double shoulderWidthRatio;

  final double elbowAxial;
  final double elbowNormal;
  final double wristAxial;
  final double wristNormal;
  final double noseAxial;
  final double noseNormal;
  final double earAxial;
  final double earNormal;
}

/// A generated frame together with the geometry that generated it.
class SyntheticPose {
  const SyntheticPose({
    required this.frame,
    required this.hipDeviationDegrees,
    required this.apparentHipDeviationDegrees,
    required this.hipOffset,
    required this.bodyLength,
    required this.apparentBodyLength,
    required this.shoulderSeparation,
    required this.obliquityDegrees,
    required this.phoneRollDegrees,
  });

  final PoseFrame frame;

  /// The signed bend requested, in degrees. Negative is sag.
  final double hipDeviationDegrees;

  /// The bend an evaluator would measure straight off the image, *before*
  /// correcting for obliquity. Equals [hipDeviationDegrees] at φ = 0 and grows
  /// with obliquity.
  final double apparentHipDeviationDegrees;

  /// Perpendicular distance from the hip to the shoulder→ankle line, in
  /// normalised image units. Unaffected by obliquity, by construction.
  final double hipOffset;

  /// True shoulder→ankle length, before foreshortening.
  final double bodyLength;

  /// Shoulder→ankle length as it appears in the image: `bodyLength · cos φ`.
  final double apparentBodyLength;

  /// Distance between the two shoulders in the image: `W · sin φ`.
  final double shoulderSeparation;

  final double obliquityDegrees;
  final double phoneRollDegrees;

  /// Signed offset normalised by true body length — the design's "signed
  /// normalized hip deviation" in ratio form. Negative is sag.
  double get normalizedHipOffset =>
      hipDeviationDegrees.isNegative ? -hipOffset / bodyLength : hipOffset / bodyLength;

  /// The same ratio taken naively off the image, inflated by `1 / cos φ`.
  double get apparentNormalizedHipOffset => apparentBodyLength == 0
      ? double.nan
      : normalizedHipOffset * bodyLength / apparentBodyLength;

  /// `shoulderSeparation / apparentBodyLength`. The design's route back to
  /// `cos φ`: this equals `(W/L)·tan φ`.
  double get obliquityRatio =>
      apparentBodyLength == 0 ? double.nan : shoulderSeparation / apparentBodyLength;
}

/// Constructs a body at a specified geometry.
///
/// Every field is a knob a QA question is phrased in. Defaults describe a clean
/// side-on forearm plank, centred, well lit, phone level.
class PoseBuilder {
  const PoseBuilder({
    this.monotonic = Duration.zero,
    this.bodyLength = 0.62,
    this.hipDeviationDegrees = 0,
    this.obliquityDegrees = 0,
    this.phoneRollDegrees = 0,
    this.facing = BodySide.right,
    this.center = const Vec2(0.5, 0.5),
    this.confidence = 0.95,
    this.farSideConfidence,
    this.jointConfidence = const {},
    this.missing = const {},
    this.detectionConfidence = 0.95,
    this.personCount = 1,
    this.proportions = const BodyProportions(),
    this.gravityMagnitude = 1.0,
    this.kneeDropFraction = 0,
  });

  /// Capture timestamp. All session timing derives from this, never a wall
  /// clock, so a sequence is defined entirely by the timestamps you choose.
  final Duration monotonic;

  /// True shoulder→ankle length in normalised image units, before obliquity
  /// foreshortening.
  final double bodyLength;

  /// Signed bend at the hip in degrees. **Negative is sag, positive is pike.**
  /// Must be in (-180, 180).
  final double hipDeviationDegrees;

  /// Rotation off side-on, in degrees. 0 is a true side view; 90 would be
  /// frontal. The framing gate rejects beyond ~35.
  final double obliquityDegrees;

  /// Rotation of the entire scene — landmarks and gravity together — modelling
  /// a phone propped at an angle on the floor.
  final double phoneRollDegrees;

  /// Which side of the body faces the camera. The far side is occluded and gets
  /// [farSideConfidence].
  final BodySide facing;

  /// Where the body's centre sits in the normalised frame.
  final Vec2 center;

  /// Confidence for near-side and midline joints.
  final double confidence;

  /// Confidence for the occluded far side. Defaults to 55% of [confidence],
  /// which is roughly what a side-on plank actually produces.
  final double? farSideConfidence;

  /// Per-joint overrides. Wins over [confidence] and [farSideConfidence].
  final Map<Joint, double> jointConfidence;

  /// Joints omitted from the frame entirely, so `frame[j]` yields
  /// [Landmark.absent]. Use this for the tucked-chin case
  /// (`{Joint.nose, Joint.leftEar, Joint.rightEar}`) and for partial framing
  /// (ankles or shoulders out of shot).
  final Set<Joint> missing;

  final double detectionConfidence;

  /// Vision reports multiple bodies. Anything above 1 is the "someone walked
  /// through the room" case.
  final int personCount;

  final BodyProportions proportions;

  /// Length of the emitted gravity vector. Unit by default; set it away from 1
  /// to check that an evaluator normalises what it is given.
  final double gravityMagnitude;

  /// Drops the knees toward the floor by this fraction of body length, without
  /// touching the shoulder→hip→ankle line. Models a knee plank and the
  /// `kneesDropped` fault.
  final double kneeDropFraction;

  PoseBuilder copyWith({
    Duration? monotonic,
    double? bodyLength,
    double? hipDeviationDegrees,
    double? obliquityDegrees,
    double? phoneRollDegrees,
    BodySide? facing,
    Vec2? center,
    double? confidence,
    double? farSideConfidence,
    Map<Joint, double>? jointConfidence,
    Set<Joint>? missing,
    double? detectionConfidence,
    int? personCount,
    BodyProportions? proportions,
    double? gravityMagnitude,
    double? kneeDropFraction,
  }) =>
      PoseBuilder(
        monotonic: monotonic ?? this.monotonic,
        bodyLength: bodyLength ?? this.bodyLength,
        hipDeviationDegrees: hipDeviationDegrees ?? this.hipDeviationDegrees,
        obliquityDegrees: obliquityDegrees ?? this.obliquityDegrees,
        phoneRollDegrees: phoneRollDegrees ?? this.phoneRollDegrees,
        facing: facing ?? this.facing,
        center: center ?? this.center,
        confidence: confidence ?? this.confidence,
        farSideConfidence: farSideConfidence ?? this.farSideConfidence,
        jointConfidence: jointConfidence ?? this.jointConfidence,
        missing: missing ?? this.missing,
        detectionConfidence: detectionConfidence ?? this.detectionConfidence,
        personCount: personCount ?? this.personCount,
        proportions: proportions ?? this.proportions,
        gravityMagnitude: gravityMagnitude ?? this.gravityMagnitude,
        kneeDropFraction: kneeDropFraction ?? this.kneeDropFraction,
      );

  PoseFrame build() => annotate().frame;

  SyntheticPose annotate() {
    assert(hipDeviationDegrees.abs() < 180,
        'hip deviation must be inside (-180, 180)');
    assert(bodyLength > 0, 'body length must be positive');

    final phi = _radians(obliquityDegrees);
    final roll = _radians(phoneRollDegrees);
    final cosPhi = math.cos(phi);
    final apparentLength = bodyLength * cosPhi.abs();

    final bend = _radians(hipDeviationDegrees.abs());
    final offset = _offsetForBend(bend, bodyLength, proportions.hipAxial);

    // y grows downward, so rotating by +roll turns the scene clockwise on
    // screen. `axis` runs head→feet; `down` is gravity.
    final axis = Vec2(math.cos(roll), math.sin(roll));
    final down = Vec2(-math.sin(roll), math.cos(roll));

    Vec2 place(double axial, double normal) =>
        center + axis * axial + down * normal;

    // Sag puts the hip toward the floor, i.e. along gravity.
    final hipNormal = hipDeviationDegrees.isNegative ? offset : -offset;

    final separation =
        bodyLength * proportions.shoulderWidthRatio * math.sin(phi).abs();
    final nearShift = -separation / 2;
    final farShift = separation / 2;

    double axialAt(double fraction) => -apparentLength / 2 + fraction * apparentLength;

    final near = facing;

    final landmarks = <Joint, Landmark>{};

    void put(Joint joint, double axial, double normal, {BodySide? side}) {
      if (missing.contains(joint)) return;
      final shift = side == null
          ? 0.0
          : (side == near ? nearShift : farShift);
      final p = place(axial + shift, normal);
      landmarks[joint] = Landmark(p.x, p.y, _confidenceFor(joint, side, near));
    }

    final shoulderA = axialAt(0);
    final hipA = axialAt(proportions.hipAxial);
    final kneeA = axialAt(proportions.kneeAxial);
    final ankleA = axialAt(1);
    final kneeN = kneeDropFraction * bodyLength;

    put(Joint.leftShoulder, shoulderA, 0, side: BodySide.left);
    put(Joint.rightShoulder, shoulderA, 0, side: BodySide.right);
    put(Joint.leftHip, hipA, hipNormal, side: BodySide.left);
    put(Joint.rightHip, hipA, hipNormal, side: BodySide.right);
    put(Joint.leftKnee, kneeA, kneeN, side: BodySide.left);
    put(Joint.rightKnee, kneeA, kneeN, side: BodySide.right);
    put(Joint.leftAnkle, ankleA, 0, side: BodySide.left);
    put(Joint.rightAnkle, ankleA, 0, side: BodySide.right);

    final elbowA = axialAt(proportions.elbowAxial);
    final wristA = axialAt(proportions.wristAxial);
    put(Joint.leftElbow, elbowA, proportions.elbowNormal * bodyLength,
        side: BodySide.left);
    put(Joint.rightElbow, elbowA, proportions.elbowNormal * bodyLength,
        side: BodySide.right);
    put(Joint.leftWrist, wristA, proportions.wristNormal * bodyLength,
        side: BodySide.left);
    put(Joint.rightWrist, wristA, proportions.wristNormal * bodyLength,
        side: BodySide.right);

    put(Joint.nose, axialAt(proportions.noseAxial),
        proportions.noseNormal * bodyLength);
    put(Joint.leftEar, axialAt(proportions.earAxial),
        proportions.earNormal * bodyLength, side: BodySide.left);
    put(Joint.rightEar, axialAt(proportions.earAxial),
        proportions.earNormal * bodyLength, side: BodySide.right);

    final apparentBend = apparentLength == 0
        ? 0.0
        : _bendFor(offset, apparentLength, proportions.hipAxial);

    return SyntheticPose(
      frame: PoseFrame(
        monotonic: monotonic,
        landmarks: Map.unmodifiable(landmarks),
        gravity: down * gravityMagnitude,
        detectionConfidence: detectionConfidence,
        personCount: personCount,
      ),
      hipDeviationDegrees: hipDeviationDegrees,
      apparentHipDeviationDegrees:
          hipDeviationDegrees.isNegative ? -_degrees(apparentBend) : _degrees(apparentBend),
      hipOffset: offset,
      bodyLength: bodyLength,
      apparentBodyLength: apparentLength,
      shoulderSeparation: separation,
      obliquityDegrees: obliquityDegrees,
      phoneRollDegrees: phoneRollDegrees,
    );
  }

  double _confidenceFor(Joint joint, BodySide? side, BodySide near) {
    final override = jointConfidence[joint];
    if (override != null) return override;
    if (side == null || side == near) return confidence;
    return farSideConfidence ?? confidence * 0.55;
  }
}

/// Angle of bend at the hip, in radians, for a hip sitting `fraction` of the
/// way along a body of length `length` and displaced `offset` perpendicular to
/// it. Strictly increasing in `offset`, approaching π.
double _bendFor(double offset, double length, double fraction) =>
    math.atan(offset / (fraction * length)) +
    math.atan(offset / ((1 - fraction) * length));

/// Inverse of [_bendFor]. Bisection rather than the closed form because the
/// closed form is a quadratic with a removable singularity at 90°, and this is
/// test scaffolding where obviously-correct beats clever.
double _offsetForBend(double bend, double length, double fraction) {
  if (bend <= 0) return 0;
  var hi = length;
  while (_bendFor(hi, length, fraction) < bend && hi < length * 1e9) {
    hi *= 2;
  }
  var lo = 0.0;
  for (var i = 0; i < 100; i++) {
    final mid = (lo + hi) / 2;
    if (_bendFor(mid, length, fraction) < bend) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lo + hi) / 2;
}

double _radians(double degrees) => degrees * math.pi / 180;
double _degrees(double radians) => radians * 180 / math.pi;

/// Emits frames at a fixed cadence, with the geometry at each instant chosen by
/// [at]. The timestamps are what a session is scored on, so this is the only
/// thing that defines "how long" anything took.
List<PoseFrame> poseStream({
  required Duration duration,
  required PoseBuilder Function(Duration elapsed) at,
  double hz = 15,
  Duration start = Duration.zero,
}) {
  assert(hz > 0, 'frame rate must be positive');
  // Timestamps are computed from the frame index rather than accumulated, so a
  // cadence that does not divide evenly into a microsecond (15 Hz does not)
  // cannot drift the end of a long stream by tens of milliseconds.
  final count = (duration.inMicroseconds * hz / 1000000).floor() + 1;
  final frames = <PoseFrame>[];
  for (var i = 0; i < count; i++) {
    final elapsed = Duration(microseconds: (i * 1000000 / hz).round());
    frames.add(at(elapsed).copyWith(monotonic: start + elapsed).build());
  }
  return frames;
}

/// A constant geometry held for [duration].
List<PoseFrame> holdPose(
  PoseBuilder pose, {
  required Duration duration,
  double hz = 15,
  Duration start = Duration.zero,
}) =>
    poseStream(duration: duration, hz: hz, start: start, at: (_) => pose);

/// Hip deviation sweeping linearly from [from] to [to] — the gradual-sag case,
/// which is both the most common real failure and the one a threshold sweep
/// most needs.
List<PoseFrame> rampDeviation({
  required double from,
  required double to,
  required Duration duration,
  PoseBuilder base = const PoseBuilder(),
  double hz = 15,
  Duration start = Duration.zero,
}) =>
    poseStream(
      duration: duration,
      hz: hz,
      start: start,
      at: (elapsed) {
        final t = duration.inMicroseconds == 0
            ? 1.0
            : elapsed.inMicroseconds / duration.inMicroseconds;
        return base.copyWith(hipDeviationDegrees: from + (to - from) * t);
      },
    );

/// Concatenates segments, re-timing each to follow the previous one at [hz].
/// The join is one frame period, so no segment overlaps another.
List<PoseFrame> concatFrames(List<List<PoseFrame>> segments, {double hz = 15}) {
  final stepUs = (1000000 / hz).round();
  final out = <PoseFrame>[];
  var offsetUs = 0;
  for (final segment in segments) {
    if (segment.isEmpty) continue;
    final base = segment.first.monotonic.inMicroseconds;
    for (final frame in segment) {
      out.add(PoseFrame(
        monotonic:
            Duration(microseconds: frame.monotonic.inMicroseconds - base + offsetUs),
        landmarks: frame.landmarks,
        gravity: frame.gravity,
        detectionConfidence: frame.detectionConfidence,
        personCount: frame.personCount,
      ));
    }
    offsetUs = out.last.monotonic.inMicroseconds + stepUs;
  }
  return out;
}

/// Shifts every frame later by [by]. Used to punch a gap into a stream, which
/// the session machine must credit to nobody.
List<PoseFrame> shiftFrames(List<PoseFrame> frames, Duration by) => [
      for (final frame in frames)
        PoseFrame(
          monotonic: frame.monotonic + by,
          landmarks: frame.landmarks,
          gravity: frame.gravity,
          detectionConfidence: frame.detectionConfidence,
          personCount: frame.personCount,
        ),
    ];
