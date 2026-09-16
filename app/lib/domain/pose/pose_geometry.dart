/// Pure 2D geometry shared by the exercise evaluators.
///
/// Two rules hold throughout this file.
///
/// **Everything is measured against gravity, never against the image axes.**
/// The phone is propped on the floor at whatever angle it happened to land, so
/// image-space "up" is meaningless. Every function here is built from vector
/// differences, dot products and lengths taken relative to the measured gravity
/// vector, which makes every result invariant under rolling the phone.
///
/// **Nothing here throws.** Degenerate input — a zero-length body, a NaN
/// landmark, a gravity reading of zero, a joint the model never emitted —
/// returns `null`, and callers turn `null` into `EvalOutput.unusable` or an
/// indeterminate verdict. Not being able to measure is never the user's fault.
library;

import 'dart:math' as math;

import 'pose_frame.dart';

/// Shortest vector that still carries a trustworthy direction, in normalised
/// image units. Below this, two landmarks are the same point and any angle
/// taken through them is noise.
const double kMinSegmentLength = 1e-4;

/// Per-joint confidence floor for the evaluators.
///
/// Deliberately below [PoseFrame.has]'s 0.5 default: in a true side-on view the
/// far limb is occluded and the near limb can still dip into the 0.4s under a
/// hoodie or in bad light. Refusing to measure is charged to us, not the user,
/// so the floor is set where the measurement is still usable rather than where
/// the model is proud of it.
const double kMinJointConfidence = 0.4;

/// Confidence floor for the shoulder *pair*, used only for the obliquity
/// estimate. Lower still, because in a side-on pose the far shoulder is
/// occluded by construction and a failed estimate merely falls back to the
/// calibrated value.
const double kMinShoulderPairConfidence = 0.3;

/// Below this whole-frame detection confidence there is no usable skeleton.
const double kMinDetectionConfidence = 0.35;

/// Anthropometric shoulder breadth as a fraction of the shoulder→ankle body
/// length (biacromial ≈ 0.40 m, shoulder→ankle ≈ 1.35 m for a 1.75 m adult).
const double kShoulderBreadthOverShoulderAnkle = 0.30;

/// The same breadth against the shoulder→knee line, which the knee plank uses
/// as its body length (shoulder→knee ≈ 0.92 m).
const double kShoulderBreadthOverShoulderKnee = 0.44;

/// The same breadth against the shoulder→hip trunk, used by the upright
/// exercises (trunk ≈ 0.49 m).
const double kShoulderBreadthOverTrunk = 0.80;

bool isFiniteVec(Vec2 v) => v.x.isFinite && v.y.isFinite;

double radiansToDegrees(double radians) => radians * 180 / math.pi;

double degreesToRadians(double degrees) => degrees * math.pi / 180;

/// Median of the finite entries, or null if there are none. Used for baselines,
/// where one wild frame must not move the answer.
double? medianOf(Iterable<double> values) {
  final clean = values.where((v) => v.isFinite).toList()..sort();
  if (clean.isEmpty) return null;
  final mid = clean.length ~/ 2;
  return clean.length.isOdd ? clean[mid] : (clean[mid - 1] + clean[mid]) / 2;
}

/// An orthonormal basis built from the accelerometer, in image coordinates.
class GravityFrame {
  const GravityFrame._(this.up, this.across);

  /// Unit vector opposing measured gravity.
  final Vec2 up;

  /// Unit vector perpendicular to [up] — the "level" direction.
  final Vec2 across;

  static const GravityFrame imageUpright =
      GravityFrame._(Vec2(0, -1), Vec2(-1, 0));

  static GravityFrame? from(Vec2 gravity) {
    if (!isFiniteVec(gravity)) return null;
    final length = gravity.length;
    if (!length.isFinite || length < kMinSegmentLength) return null;
    final up = Vec2(-gravity.x / length, -gravity.y / length);
    return GravityFrame._(up, up.perpendicular);
  }

  /// How far [a] sits above [b], along gravity.
  double rise(Vec2 a, Vec2 b) => (a - b).dot(up);

  /// Angle of [v] away from level, in degrees: 0 is horizontal, +90 points
  /// straight up, -90 straight down.
  double? inclinationDegrees(Vec2 v) {
    if (!isFiniteVec(v)) return null;
    final length = v.length;
    if (!length.isFinite || length < kMinSegmentLength) return null;
    final sine = (v.dot(up) / length).clamp(-1.0, 1.0);
    final degrees = radiansToDegrees(math.asin(sine));
    return degrees.isFinite ? degrees : null;
  }
}

/// Unsigned angle between two vectors, 0–180°, or null if either is degenerate.
double? angleBetweenDegrees(Vec2 a, Vec2 b) {
  if (!isFiniteVec(a) || !isFiniteVec(b)) return null;
  final la = a.length;
  final lb = b.length;
  if (!la.isFinite || !lb.isFinite) return null;
  if (la < kMinSegmentLength || lb < kMinSegmentLength) return null;
  final cosine = (a.dot(b) / (la * lb)).clamp(-1.0, 1.0);
  final degrees = radiansToDegrees(math.acos(cosine));
  return degrees.isFinite ? degrees : null;
}

/// Interior angle at [vertex], 0–180°.
double? jointAngleDegrees(Vec2 a, Vec2 vertex, Vec2 b) {
  if (!isFiniteVec(a) || !isFiniteVec(vertex) || !isFiniteVec(b)) return null;
  return angleBetweenDegrees(a - vertex, b - vertex);
}

/// Undoes the anisotropic foreshortening obliquity introduces, so joint angles
/// can be read in the subject's own sagittal plane.
///
/// Rotating the subject about the vertical axis by φ compresses the
/// gravity-horizontal direction by `cos φ` and leaves the gravity-vertical
/// direction untouched. Ratios survive that (both numerator and denominator
/// scale together) but *angles* do not, which is why they need this and the
/// signed hip deviation does not.
Vec2 deskew(Vec2 v, GravityFrame gravity, double cosObliquity) {
  if (!isFiniteVec(v)) return v;
  final cosine =
      cosObliquity.isFinite ? cosObliquity.clamp(0.3, 1.0) : 1.0;
  final vertical = v.dot(gravity.up);
  final horizontal = v.dot(gravity.across) / cosine;
  return gravity.up * vertical + gravity.across * horizontal;
}

/// How far the subject has rotated away from side-on.
class Obliquity {
  const Obliquity(this.degrees, this.cosine);

  final double degrees;
  final double cosine;

  static const Obliquity sideOn = Obliquity(0, 1);
}

/// Whether the reference length handed to [measureObliquity] is itself
/// compressed by obliquity.
enum ObliquityReference {
  /// The reference runs along the direction obliquity compresses — a plank's
  /// shoulder→ankle line — so it is measured as `L·cos φ`.
  compressed,

  /// The reference is gravity-vertical — a seated subject's trunk — and
  /// obliquity leaves its apparent length alone.
  upright,
}

/// Recovers φ from 2D alone, via the ratio of apparent shoulder separation to
/// apparent body length.
///
/// Rotating the subject about the vertical axis by φ projects the
/// shoulder-to-shoulder line, which points straight at the camera when side-on,
/// to `W·sin φ` in the image. Against a [ObliquityReference.compressed]
/// reference of apparent length `L·cos φ` the ratio is therefore
/// `(W/L)·tan φ`; against an [ObliquityReference.upright] one of unchanged
/// length `T` it is `(W/T)·sin φ`. `W/L` and `W/T` are anthropometric and
/// stable, so φ falls straight out.
///
/// Returns null when the shoulder pair is not confidently visible; callers fall
/// back to the value recorded at calibration rather than assuming side-on,
/// because assuming side-on over-reads deviation and over-reading is the
/// false-reject direction.
Obliquity? measureObliquity({
  required PoseFrame frame,
  required double referenceLength,
  required double breadthRatio,
  required ObliquityReference reference,
  double minShoulderConfidence = kMinShoulderPairConfidence,
  double maxDegrees = 60,
}) {
  final left = frame[Joint.leftShoulder];
  final right = frame[Joint.rightShoulder];
  if (!left.confidence.isFinite || !right.confidence.isFinite) return null;
  if (left.confidence < minShoulderConfidence) return null;
  if (right.confidence < minShoulderConfidence) return null;
  if (!isFiniteVec(left.position) || !isFiniteVec(right.position)) return null;
  if (!referenceLength.isFinite || referenceLength < kMinSegmentLength) {
    return null;
  }
  if (!breadthRatio.isFinite || breadthRatio < kMinSegmentLength) return null;

  final separation = (left.position - right.position).length;
  if (!separation.isFinite) return null;

  final ratio = (separation / referenceLength) / breadthRatio;
  if (!ratio.isFinite || ratio < 0) return null;

  final degrees = switch (reference) {
    ObliquityReference.compressed => radiansToDegrees(math.atan(ratio)),
    ObliquityReference.upright =>
      radiansToDegrees(math.asin(ratio.clamp(0.0, 1.0))),
  };
  if (!degrees.isFinite) return null;

  final clamped = degrees.clamp(0.0, maxDegrees);
  return Obliquity(clamped, math.cos(degreesToRadians(clamped)));
}

/// The signed departure of a middle joint from the line joining the two ends.
class BodyLineDeviation {
  const BodyLineDeviation({
    required this.degrees,
    required this.offsetRatio,
    required this.bodyLength,
    required this.hipFraction,
  });

  /// Signed angular departure from a straight body line. Negative is sag
  /// (toward the floor), positive is pike (away from it).
  ///
  /// This is exactly the quantity `180° − angle(shoulder, hip, ankle)` would
  /// give, except that it carries a sign. The unsigned joint angle cannot tell
  /// a sag from a pike at all, which is the whole reason the signed form is
  /// specified.
  final double degrees;

  /// Signed perpendicular offset divided by body length, obliquity-corrected.
  final double offsetRatio;

  /// Apparent length of the reference line, in normalised image units.
  final double bodyLength;

  /// Where the middle joint sits along the line, 0 at [proximal-end], 1 at the
  /// far end. The lever arm that converts an offset into an angle.
  final double hipFraction;
}

/// Signed normalised hip deviation.
///
/// The magnitude is the perpendicular offset of [middle] from the
/// [proximal]→[distal] line, normalised by that line's length; the sign comes
/// from projecting that offset onto measured gravity, so negative is sag and
/// positive is pike.
///
/// One deliberate deviation from a literal reading of the design, which says
/// "projected onto the measured gravity vector": we take the *magnitude* from
/// the perpendicular offset and only the *sign* from the gravity projection.
/// For a floor plank the body axis is within a few degrees of level, the
/// perpendicular offset is therefore within a few degrees of vertical, and the
/// two definitions agree to a fraction of a percent. They part company only for
/// the incline variant, where a raw `offset · up` shrinks the reading by
/// `cos²(incline)` — roughly a third at a 35° incline — which would silently
/// make the incline gate the most permissive of the three. That is the opposite
/// of what the exercise needs.
///
/// Obliquity is a pure scalar here: the offset is perpendicular to the rotation
/// axis and projects unchanged, while body length projects to `L·cos φ`, so the
/// measured ratio is `δ_true / cos φ` and multiplying by `cos φ` inverts it.
BodyLineDeviation? bodyLineDeviation({
  required Vec2 proximal,
  required Vec2 middle,
  required Vec2 distal,
  required GravityFrame gravity,
  double cosObliquity = 1.0,
}) {
  if (!isFiniteVec(proximal) || !isFiniteVec(middle) || !isFiniteVec(distal)) {
    return null;
  }

  final axis = distal - proximal;
  final length = axis.length;
  if (!length.isFinite || length < kMinSegmentLength) return null;

  final unit = Vec2(axis.x / length, axis.y / length);
  final toMiddle = middle - proximal;
  final along = toMiddle.dot(unit);
  final perpendicular = toMiddle - unit * along;
  final offset = perpendicular.length;
  if (!offset.isFinite || !along.isFinite) return null;

  final signedOffset = perpendicular.dot(gravity.up) < 0 ? -offset : offset;

  final cosine = cosObliquity.isFinite ? cosObliquity.clamp(0.2, 1.0) : 1.0;
  final ratio = (signedOffset / length) * cosine;
  if (!ratio.isFinite) return null;

  // Where the middle joint sits along the line sets the lever arm. Clamped well
  // inside the ends so a mislocated landmark cannot divide by nearly zero.
  final fraction = (along / length).clamp(0.12, 0.88);
  final magnitude = ratio.abs();
  final degrees = radiansToDegrees(
    math.atan(magnitude / fraction) + math.atan(magnitude / (1 - fraction)),
  );
  if (!degrees.isFinite) return null;

  return BodyLineDeviation(
    degrees: ratio < 0 ? -degrees : degrees,
    offsetRatio: ratio,
    bodyLength: length,
    hipFraction: fraction,
  );
}

/// Picks the camera-facing side by summed confidence over the joints the
/// exercise actually uses.
///
/// Pass the *left* variants; the right ones are derived. Exercises pass their
/// own joints rather than reusing [PoseFrame.sideConfidence], because that
/// helper averages over hips, knees and ankles — none of which a wheelchair
/// user's seated arm hold requires.
BodySide dominantSideFor(PoseFrame frame, Iterable<Joint> leftVariants) {
  var left = 0.0;
  var right = 0.0;
  for (final joint in leftVariants) {
    final l = frame[joint].confidence;
    final r = frame[joint.mirrored()].confidence;
    if (l.isFinite) left += l;
    if (r.isFinite) right += r;
  }
  return right > left ? BodySide.right : BodySide.left;
}

/// The [leftVariant] joint, mirrored onto [side].
Joint onSide(Joint leftVariant, BodySide side) =>
    side == BodySide.left ? leftVariant : leftVariant.mirrored();

/// Resolves joints for one frame, preferring the chosen side and falling back
/// to its mirror, while accumulating the confidence of what it actually used.
class JointResolver {
  JointResolver(this._frame, {this.minConfidence = kMinJointConfidence});

  final PoseFrame _frame;
  final double minConfidence;
  final Set<Joint> _missing = <Joint>{};
  double _sum = 0;
  int _count = 0;

  /// Null when neither the preferred landmark nor its mirror is usable.
  Vec2? resolve(Joint preferred) {
    final near = _frame[preferred];
    if (_usable(near)) return _accept(near);
    final far = _frame[preferred.mirrored()];
    if (_usable(far)) return _accept(far);
    _missing.add(preferred);
    return null;
  }

  bool _usable(Landmark landmark) =>
      landmark.confidence.isFinite &&
      landmark.confidence >= minConfidence &&
      isFiniteVec(landmark.position);

  Vec2 _accept(Landmark landmark) {
    _sum += landmark.confidence;
    _count++;
    return landmark.position;
  }

  bool get complete => _missing.isEmpty;

  Set<Joint> get missing => _missing;

  /// Mean confidence of the landmarks used, 0 when nothing resolved.
  double get confidence =>
      _count == 0 ? 0 : (_sum / _count).clamp(0.0, 1.0).toDouble();
}
