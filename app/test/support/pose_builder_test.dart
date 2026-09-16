/// Tests for the synthetic pose generator.
///
/// The builder is scaffolding, but it is scaffolding every evaluator threshold
/// will be calibrated against. If it quietly produces 9° when asked for 8°,
/// every band in the product is wrong by a degree and nothing else in the suite
/// would notice. So the geometry is measured back out of the finished frame by
/// an oracle that shares no code with the builder.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';

import 'pose_builder.dart';

/// Measures signed hip deviation straight off a frame, the way an evaluator
/// would: `180° - angle(shoulder, hip, ankle)`, signed by whether the hip lies
/// along gravity (sag, negative) or against it (pike, positive).
///
/// Deliberately written from the definition rather than by reusing anything the
/// builder did.
double measuredDeviationDegrees(PoseFrame frame) {
  Vec2 mid(Joint a, Joint b) => (frame[a].position + frame[b].position) * 0.5;

  final s = mid(Joint.leftShoulder, Joint.rightShoulder);
  final h = mid(Joint.leftHip, Joint.rightHip);
  final a = mid(Joint.leftAnkle, Joint.rightAnkle);

  final toShoulder = s - h;
  final toAnkle = a - h;
  final cosine = toShoulder.dot(toAnkle) /
      (toShoulder.length * toAnkle.length);
  final interior = math.acos(cosine.clamp(-1.0, 1.0));
  final bend = (math.pi - interior) * 180 / math.pi;

  final axis = a - s;
  final t = (h - s).dot(axis) / axis.dot(axis);
  final offset = h - (s + axis * t);
  final alongGravity = offset.dot(frame.gravity);

  return alongGravity > 0 ? -bend : bend;
}

double measuredBodyLength(PoseFrame frame) {
  Vec2 mid(Joint a, Joint b) => (frame[a].position + frame[b].position) * 0.5;
  return (mid(Joint.leftAnkle, Joint.rightAnkle) -
          mid(Joint.leftShoulder, Joint.rightShoulder))
      .length;
}

double measuredShoulderSeparation(PoseFrame frame) =>
    (frame[Joint.leftShoulder].position - frame[Joint.rightShoulder].position)
        .length;

void main() {
  group('hip deviation', () {
    test('zero deviation is a straight body', () {
      final frame = const PoseBuilder().build();
      expect(measuredDeviationDegrees(frame), closeTo(0, 1e-6));
    });

    test('the requested angle is the angle you get', () {
      for (final requested in [-30.0, -22.0, -12.0, -8.0, -1.0, 5.0, 12.0, 25.0]) {
        final frame =
            PoseBuilder(hipDeviationDegrees: requested).build();
        expect(measuredDeviationDegrees(frame), closeTo(requested, 1e-6),
            reason: 'asked for $requested');
      }
    });

    test('negative is sag: the hip moves toward the floor', () {
      final sag = const PoseBuilder(hipDeviationDegrees: -15).build();
      final pike = const PoseBuilder(hipDeviationDegrees: 15).build();

      // Gravity is +y with the phone level, so a sagging hip has the larger y.
      expect(sag.gravity.y, greaterThan(0));
      expect(sag[Joint.leftHip].y, greaterThan(pike[Joint.leftHip].y));
    });

    test('an unsigned angle cannot tell sag from pike, which is the point', () {
      final sag = const PoseBuilder(hipDeviationDegrees: -15).build();
      final pike = const PoseBuilder(hipDeviationDegrees: 15).build();
      expect(measuredDeviationDegrees(sag).abs(),
          closeTo(measuredDeviationDegrees(pike).abs(), 1e-9));
      expect(measuredDeviationDegrees(sag),
          isNot(closeTo(measuredDeviationDegrees(pike), 1)));
    });

    test('deviation is reported both as an angle and as a normalized offset',
        () {
      final pose = const PoseBuilder(hipDeviationDegrees: -12).annotate();
      expect(pose.normalizedHipOffset, lessThan(0));
      expect(pose.hipOffset, greaterThan(0));
      expect(pose.normalizedHipOffset.abs(),
          closeTo(pose.hipOffset / pose.bodyLength, 1e-12));
    });

    test('deviation is monotonic in the offset it implies', () {
      var previous = 0.0;
      for (var deg = 1.0; deg <= 60; deg += 1) {
        final offset = PoseBuilder(hipDeviationDegrees: -deg).annotate().hipOffset;
        expect(offset, greaterThan(previous));
        previous = offset;
      }
    });

    test('body length scales the offset but not the angle', () {
      final small = const PoseBuilder(bodyLength: 0.3, hipDeviationDegrees: -10)
          .annotate();
      final large = const PoseBuilder(bodyLength: 0.9, hipDeviationDegrees: -10)
          .annotate();
      expect(measuredDeviationDegrees(small.frame),
          closeTo(measuredDeviationDegrees(large.frame), 1e-9));
      expect(small.normalizedHipOffset, closeTo(large.normalizedHipOffset, 1e-9));
      expect(large.hipOffset, greaterThan(small.hipOffset));
    });
  });

  group('obliquity', () {
    test('foreshortens the body axis by cos phi', () {
      for (final phi in [0.0, 10.0, 20.0, 35.0]) {
        final pose = PoseBuilder(obliquityDegrees: phi).annotate();
        final expected = pose.bodyLength * math.cos(phi * math.pi / 180);
        expect(measuredBodyLength(pose.frame), closeTo(expected, 1e-9),
            reason: 'phi=$phi');
      }
    });

    test('separates the shoulders by W sin phi', () {
      for (final phi in [0.0, 10.0, 35.0]) {
        final pose = PoseBuilder(obliquityDegrees: phi).annotate();
        expect(measuredShoulderSeparation(pose.frame),
            closeTo(pose.shoulderSeparation, 1e-9));
      }
      expect(const PoseBuilder().annotate().shoulderSeparation, 0);
    });

    test('leaves the perpendicular hip offset untouched', () {
      // The design's decisive claim: obliquity inflates the measurement by a
      // pure scalar and does not shear it, because the sag offset is
      // perpendicular to the rotation axis.
      final headon = const PoseBuilder(hipDeviationDegrees: -10).annotate();
      final oblique =
          const PoseBuilder(hipDeviationDegrees: -10, obliquityDegrees: 30)
              .annotate();
      expect(oblique.hipOffset, closeTo(headon.hipOffset, 1e-12));
    });

    test('inflates the measured deviation by exactly 1 / cos phi', () {
      const phi = 30.0;
      final pose =
          const PoseBuilder(hipDeviationDegrees: -10, obliquityDegrees: phi)
              .annotate();

      final measured = measuredDeviationDegrees(pose.frame);
      expect(measured, closeTo(pose.apparentHipDeviationDegrees, 1e-9));
      expect(measured.abs(), greaterThan(10));

      // In ratio form the inflation is exactly 1/cos phi.
      expect(pose.apparentNormalizedHipOffset.abs(),
          closeTo(pose.normalizedHipOffset.abs() /
              math.cos(phi * math.pi / 180), 1e-12));
    });

    test('cos phi is recoverable from the image alone', () {
      // shoulderSeparation / apparentBodyLength == (W/L) tan phi, so an
      // evaluator that knows W/L from calibration can undo the inflation.
      const widthRatio = 0.26;
      for (final phi in [5.0, 15.0, 30.0]) {
        final pose = PoseBuilder(obliquityDegrees: phi).annotate();
        final tanPhi = pose.obliquityRatio / widthRatio;
        final recovered = math.atan(tanPhi) * 180 / math.pi;
        expect(recovered, closeTo(phi, 1e-9), reason: 'phi=$phi');
      }
    });

    test('correcting the apparent deviation recovers the true one', () {
      const phi = 25.0;
      const trueDeviation = -14.0;
      final pose = const PoseBuilder(
        hipDeviationDegrees: trueDeviation,
        obliquityDegrees: phi,
      ).annotate();

      final corrected = pose.apparentNormalizedHipOffset *
          math.cos(phi * math.pi / 180);
      expect(corrected, closeTo(pose.normalizedHipOffset, 1e-12));
    });
  });

  group('gravity and phone roll', () {
    test('gravity is unit and points along image-down when level', () {
      final frame = const PoseBuilder().build();
      expect(frame.gravity.length, closeTo(1, 1e-12));
      expect(frame.gravity.x, closeTo(0, 1e-12));
      expect(frame.gravity.y, closeTo(1, 1e-12));
    });

    test('roll rotates the whole scene, gravity included', () {
      final level = const PoseBuilder(hipDeviationDegrees: -9).build();
      final rolled =
          const PoseBuilder(hipDeviationDegrees: -9, phoneRollDegrees: 15)
              .build();

      // Image-space "up" is now meaningless, which is exactly why gravity has
      // to be measured rather than assumed.
      expect(rolled.gravity.x, isNot(closeTo(level.gravity.x, 0.05)));

      // But the body, measured against measured gravity, is unchanged.
      expect(measuredDeviationDegrees(rolled),
          closeTo(measuredDeviationDegrees(level), 1e-9));
    });

    test('roll is rigid: every pairwise distance survives it', () {
      final level = const PoseBuilder(hipDeviationDegrees: -9).build();
      final rolled =
          const PoseBuilder(hipDeviationDegrees: -9, phoneRollDegrees: 47)
              .build();

      for (final a in Joint.values) {
        for (final b in Joint.values) {
          final before = (level[a].position - level[b].position).length;
          final after = (rolled[a].position - rolled[b].position).length;
          expect(after, closeTo(before, 1e-9), reason: '$a to $b');
        }
      }
    });

    test('a full turn is the identity', () {
      final zero = const PoseBuilder(hipDeviationDegrees: -7).build();
      final full =
          const PoseBuilder(hipDeviationDegrees: -7, phoneRollDegrees: 360)
              .build();
      for (final joint in Joint.values) {
        expect(full[joint].x, closeTo(zero[joint].x, 1e-9));
        expect(full[joint].y, closeTo(zero[joint].y, 1e-9));
      }
    });

    test('gravity magnitude is settable, for evaluators that must normalise',
        () {
      final frame = const PoseBuilder(gravityMagnitude: 9.81).build();
      expect(frame.gravity.length, closeTo(9.81, 1e-9));
      expect(frame.gravity.normalized.y, closeTo(1, 1e-12));
    });
  });

  group('confidence and dropout', () {
    test('the occluded far side is less confident than the near side', () {
      final frame = const PoseBuilder(facing: BodySide.right).build();
      expect(frame.sideConfidence(BodySide.right),
          greaterThan(frame.sideConfidence(BodySide.left)));
      expect(frame[Joint.rightHip].confidence, 0.95);
    });

    test('facing flips which side is occluded', () {
      final frame = const PoseBuilder(facing: BodySide.left).build();
      expect(frame.sideConfidence(BodySide.left),
          greaterThan(frame.sideConfidence(BodySide.right)));
    });

    test('per-joint overrides beat both defaults', () {
      final frame = const PoseBuilder(
        jointConfidence: {Joint.rightAnkle: 0.05},
      ).build();
      expect(frame[Joint.rightAnkle].confidence, 0.05);
      expect(frame.has(Joint.rightAnkle), isFalse);
      expect(frame.has(Joint.rightHip), isTrue);
    });

    test('missing joints are absent, not zero-confidence placeholders', () {
      final frame =
          const PoseBuilder(missing: {Joint.leftAnkle, Joint.rightAnkle})
              .build();
      expect(frame.landmarks.containsKey(Joint.leftAnkle), isFalse);
      expect(frame[Joint.leftAnkle], same(Landmark.absent));
      expect(frame.hasAll([Joint.leftAnkle]), isFalse);
    });

    test('the tucked-chin case drops the face entirely', () {
      // BlazePose uses a face detector as its person-detector proxy, so this is
      // the shape of the failure the framing gate has to refuse to start on.
      final frame = const PoseBuilder(
        missing: {Joint.nose, Joint.leftEar, Joint.rightEar},
      ).build();
      expect(frame.hasAll([Joint.nose]), isFalse);
      expect(frame.hasAll([Joint.leftShoulder, Joint.leftHip]), isTrue);
    });

    test('partial framing drops one end of the body', () {
      // Propping the phone so the hips are out of shot is the one cheat the
      // design handles as a form-evaluation requirement rather than anti-cheat.
      final frame =
          const PoseBuilder(missing: {Joint.leftHip, Joint.rightHip}).build();
      expect(
          frame.hasAll([
            Joint.leftShoulder,
            Joint.leftHip,
            Joint.leftAnkle,
          ]),
          isFalse);
    });

    test('person count and detection confidence pass through', () {
      final frame =
          const PoseBuilder(personCount: 2, detectionConfidence: 0.4).build();
      expect(frame.personCount, 2);
      expect(frame.detectionConfidence, 0.4);
    });
  });

  group('anatomy', () {
    test('joints appear in head-to-toe order along the body', () {
      final frame = const PoseBuilder().build();
      final axis = (frame[Joint.rightAnkle].position -
              frame[Joint.rightShoulder].position)
          .normalized;
      double along(Joint j) => frame[j].position.dot(axis);

      expect(along(Joint.nose), lessThan(along(Joint.rightShoulder)));
      expect(along(Joint.rightShoulder), lessThan(along(Joint.rightHip)));
      expect(along(Joint.rightHip), lessThan(along(Joint.rightKnee)));
      expect(along(Joint.rightKnee), lessThan(along(Joint.rightAnkle)));
    });

    test('forearms sit between the shoulders and the floor', () {
      final frame = const PoseBuilder().build();
      expect(frame[Joint.rightElbow].y,
          greaterThan(frame[Joint.rightShoulder].y));
      expect(frame[Joint.rightWrist].y, greaterThan(frame[Joint.rightHip].y));
    });

    test('a knee drop moves the knees without bending the body line', () {
      final straight = const PoseBuilder().build();
      final kneeling = const PoseBuilder(kneeDropFraction: 0.12).build();
      expect(kneeling[Joint.rightKnee].y,
          greaterThan(straight[Joint.rightKnee].y));
      expect(measuredDeviationDegrees(kneeling), closeTo(0, 1e-6));
    });

    test('proportions are overridable for tests that need them load-bearing',
        () {
      final frame = const PoseBuilder(
        proportions: BodyProportions(hipAxial: 0.5, shoulderWidthRatio: 0.4),
      ).build();
      expect(measuredDeviationDegrees(frame), closeTo(0, 1e-6));
    });

    test('the body stays inside the normalised frame at default size', () {
      final frame = const PoseBuilder(hipDeviationDegrees: -25).build();
      for (final entry in frame.landmarks.entries) {
        expect(entry.value.x, inInclusiveRange(0, 1), reason: '${entry.key}.x');
        expect(entry.value.y, inInclusiveRange(0, 1), reason: '${entry.key}.y');
      }
    });
  });

  group('streams', () {
    test('a hold emits frames at the requested cadence', () {
      final frames = holdPose(const PoseBuilder(),
          duration: const Duration(seconds: 2), hz: 15);
      expect(frames.length, 31);
      expect(frames.first.monotonic, Duration.zero);
      expect(frames.last.monotonic.inMilliseconds, closeTo(2000, 34));
      for (var i = 1; i < frames.length; i++) {
        expect(frames[i].monotonic, greaterThan(frames[i - 1].monotonic));
      }
    });

    test('a ramp sweeps deviation linearly', () {
      final frames = rampDeviation(
        from: 0,
        to: -30,
        duration: const Duration(seconds: 6),
        hz: 10,
      );
      expect(measuredDeviationDegrees(frames.first), closeTo(0, 1e-6));
      expect(measuredDeviationDegrees(frames.last), closeTo(-30, 1e-6));
      expect(measuredDeviationDegrees(frames[frames.length ~/ 2]),
          closeTo(-15, 0.5));

      for (var i = 1; i < frames.length; i++) {
        expect(measuredDeviationDegrees(frames[i]),
            lessThanOrEqualTo(measuredDeviationDegrees(frames[i - 1]) + 1e-9));
      }
    });

    test('concat re-times segments so none overlaps', () {
      final frames = concatFrames([
        holdPose(const PoseBuilder(), duration: const Duration(seconds: 1)),
        holdPose(const PoseBuilder(hipDeviationDegrees: -28),
            duration: const Duration(seconds: 1)),
      ]);
      for (var i = 1; i < frames.length; i++) {
        expect(frames[i].monotonic, greaterThan(frames[i - 1].monotonic));
      }
      expect(measuredDeviationDegrees(frames.first), closeTo(0, 1e-6));
      expect(measuredDeviationDegrees(frames.last), closeTo(-28, 1e-6));
    });

    test('shifting frames punches a gap without changing anything else', () {
      final head = holdPose(const PoseBuilder(),
          duration: const Duration(milliseconds: 500));
      final tail = shiftFrames(head, const Duration(seconds: 30));
      expect(tail.first.monotonic, const Duration(seconds: 30));
      expect(tail.first.landmarks, same(head.first.landmarks));
    });
  });
}
