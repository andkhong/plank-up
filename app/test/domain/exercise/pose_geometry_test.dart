// Geometry tests live beside the evaluators that are their only consumer.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/pose/pose_geometry.dart';

import 'evaluator_fixtures.dart';

void main() {
  group('GravityFrame', () {
    test('builds an orthonormal basis from a reading', () {
      final frame = GravityFrame.from(const Vec2(0, 1))!;
      expect(frame.up.x, closeTo(0, 1e-12));
      expect(frame.up.y, closeTo(-1, 1e-12));
      expect(frame.up.dot(frame.across), closeTo(0, 1e-12));
      expect(frame.across.length, closeTo(1, 1e-12));
    });

    test('an unnormalised reading is fine', () {
      final frame = GravityFrame.from(const Vec2(3, 4))!;
      expect(frame.up.length, closeTo(1, 1e-12));
    });

    test('a dead or nonsense accelerometer yields null, never a throw', () {
      expect(GravityFrame.from(const Vec2(0, 0)), isNull);
      expect(GravityFrame.from(const Vec2(double.nan, 1)), isNull);
      expect(GravityFrame.from(const Vec2(1, double.infinity)), isNull);
      expect(GravityFrame.from(const Vec2(1e-12, 0)), isNull);
    });

    test('rise is signed against gravity, not against the image', () {
      final upright = GravityFrame.from(const Vec2(0, 1))!;
      expect(upright.rise(const Vec2(0, 0), const Vec2(0, 1)), closeTo(1, 1e-12));

      // The same two points with the phone on its side.
      final sideways = GravityFrame.from(const Vec2(1, 0))!;
      expect(sideways.rise(const Vec2(0, 0), const Vec2(1, 0)),
          closeTo(1, 1e-12));
    });

    test('inclination is degrees away from level', () {
      final frame = GravityFrame.from(const Vec2(0, 1))!;
      expect(frame.inclinationDegrees(const Vec2(1, 0)), closeTo(0, 1e-9));
      expect(frame.inclinationDegrees(const Vec2(0, -1)), closeTo(90, 1e-9));
      expect(frame.inclinationDegrees(const Vec2(0, 1)), closeTo(-90, 1e-9));
      expect(frame.inclinationDegrees(const Vec2(1, -1)), closeTo(45, 1e-9));
      expect(frame.inclinationDegrees(const Vec2(0, 0)), isNull);
      expect(frame.inclinationDegrees(const Vec2(double.nan, 0)), isNull);
    });
  });

  group('angles', () {
    test('measures what it should', () {
      expect(angleBetweenDegrees(const Vec2(1, 0), const Vec2(0, 1)),
          closeTo(90, 1e-9));
      expect(angleBetweenDegrees(const Vec2(1, 0), const Vec2(-1, 0)),
          closeTo(180, 1e-9));
      expect(angleBetweenDegrees(const Vec2(2, 0), const Vec2(5, 0)),
          closeTo(0, 1e-9));
    });

    test('degenerate input yields null', () {
      expect(angleBetweenDegrees(const Vec2(0, 0), const Vec2(1, 0)), isNull);
      expect(
          angleBetweenDegrees(const Vec2(double.nan, 0), const Vec2(1, 0)),
          isNull);
      expect(
        angleBetweenDegrees(const Vec2(double.infinity, 0), const Vec2(1, 0)),
        isNull,
      );
    });

    test('the joint angle is taken at the vertex', () {
      expect(
        jointAngleDegrees(
            const Vec2(0, 1), const Vec2(0, 0), const Vec2(1, 0)),
        closeTo(90, 1e-9),
      );
      expect(
        jointAngleDegrees(
            const Vec2(0, 0), const Vec2(0, 0), const Vec2(1, 0)),
        isNull,
      );
    });
  });

  group('deskew', () {
    test('inverts the foreshortening obliquity applies', () {
      final gravity = GravityFrame.from(const Vec2(0, 1))!;
      for (final phi in [0.0, 15.0, 30.0, 45.0]) {
        final cosine = math.cos(degreesToRadians(phi));
        const original = Vec2(0.3, -0.2);
        final compressed = Vec2(original.x * cosine, original.y);
        final restored = deskew(compressed, gravity, cosine);
        expect(restored.x, closeTo(original.x, 1e-12), reason: 'φ=$phi');
        expect(restored.y, closeTo(original.y, 1e-12), reason: 'φ=$phi');
      }
    });

    test('leaves the gravity-vertical component alone', () {
      final gravity = GravityFrame.from(const Vec2(0, 1))!;
      final result = deskew(const Vec2(0, -0.4), gravity, 0.5);
      expect(result.x, closeTo(0, 1e-12));
      expect(result.y, closeTo(-0.4, 1e-12));
    });

    test('nonsense scaling is clamped rather than dividing by zero', () {
      final gravity = GravityFrame.from(const Vec2(0, 1))!;
      for (final cosine in [0.0, -1.0, double.nan, 1e-12]) {
        final result = deskew(const Vec2(0.2, 0.2), gravity, cosine);
        expect(result.x.isFinite, isTrue, reason: 'cos=$cosine');
        expect(result.y.isFinite, isTrue, reason: 'cos=$cosine');
      }
    });
  });

  group('obliquity', () {
    PoseFrame shouldersApart(double separation, {double confidence = 0.8}) =>
        frameOf({
          Joint.leftShoulder: Landmark(0, 0, confidence),
          Joint.rightShoulder: Landmark(separation, 0, confidence),
        });

    test('side-on reads as side-on', () {
      final result = measureObliquity(
        frame: shouldersApart(0),
        referenceLength: 1,
        breadthRatio: 0.3,
        reference: ObliquityReference.compressed,
      );
      expect(result!.degrees, closeTo(0, 1e-9));
      expect(result.cosine, closeTo(1, 1e-9));
    });

    test('the compressed form recovers tan phi', () {
      for (final phi in [10.0, 20.0, 35.0, 50.0]) {
        const ratio = 0.3;
        final separation = ratio * math.sin(degreesToRadians(phi));
        final reference = math.cos(degreesToRadians(phi));
        final result = measureObliquity(
          frame: shouldersApart(separation),
          referenceLength: reference,
          breadthRatio: ratio,
          reference: ObliquityReference.compressed,
        );
        expect(result!.degrees, closeTo(phi, 1e-6), reason: 'φ=$phi');
      }
    });

    test('the upright form recovers sin phi', () {
      for (final phi in [10.0, 20.0, 35.0]) {
        const ratio = 0.8;
        final separation = ratio * math.sin(degreesToRadians(phi));
        final result = measureObliquity(
          frame: shouldersApart(separation),
          referenceLength: 1,
          breadthRatio: ratio,
          reference: ObliquityReference.upright,
        );
        expect(result!.degrees, closeTo(phi, 1e-6), reason: 'φ=$phi');
      }
    });

    test('an unreliable shoulder pair yields null, so callers can fall back',
        () {
      expect(
        measureObliquity(
          frame: shouldersApart(0.1, confidence: 0.1),
          referenceLength: 1,
          breadthRatio: 0.3,
          reference: ObliquityReference.compressed,
        ),
        isNull,
      );
      expect(
        measureObliquity(
          frame: frameOf({Joint.leftShoulder: const Landmark(0, 0, 0.9)}),
          referenceLength: 1,
          breadthRatio: 0.3,
          reference: ObliquityReference.compressed,
        ),
        isNull,
      );
    });

    test('degenerate parameters yield null', () {
      final frame = shouldersApart(0.1);
      expect(
        measureObliquity(
          frame: frame,
          referenceLength: 0,
          breadthRatio: 0.3,
          reference: ObliquityReference.compressed,
        ),
        isNull,
      );
      expect(
        measureObliquity(
          frame: frame,
          referenceLength: double.nan,
          breadthRatio: 0.3,
          reference: ObliquityReference.compressed,
        ),
        isNull,
      );
      expect(
        measureObliquity(
          frame: frame,
          referenceLength: 1,
          breadthRatio: 0,
          reference: ObliquityReference.compressed,
        ),
        isNull,
      );
    });

    test('a wild reading is capped rather than exploding', () {
      final result = measureObliquity(
        frame: shouldersApart(1000),
        referenceLength: 1e-3,
        breadthRatio: 0.3,
        reference: ObliquityReference.compressed,
        maxDegrees: 60,
      );
      expect(result!.degrees, 60);
      expect(result.cosine, closeTo(0.5, 1e-9));
    });
  });

  group('bodyLineDeviation', () {
    final gravity = GravityFrame.from(const Vec2(0, 1))!;

    test('a straight line reads zero', () {
      final result = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0.45, 0),
        distal: const Vec2(1, 0),
        gravity: gravity,
      );
      expect(result!.degrees, closeTo(0, 1e-9));
      expect(result.offsetRatio, closeTo(0, 1e-9));
      expect(result.bodyLength, closeTo(1, 1e-9));
      expect(result.hipFraction, closeTo(0.45, 1e-9));
    });

    test('sag is negative and pike is positive', () {
      final sag = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0.5, 0.05),
        distal: const Vec2(1, 0),
        gravity: gravity,
      )!;
      final pike = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0.5, -0.05),
        distal: const Vec2(1, 0),
        gravity: gravity,
      )!;
      expect(sag.degrees, lessThan(0));
      expect(pike.degrees, greaterThan(0));
      expect(sag.degrees, closeTo(-pike.degrees, 1e-12));
    });

    test('the obliquity correction is a pure scalar on the ratio', () {
      final uncorrected = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0.5, 0.06),
        distal: const Vec2(1, 0),
        gravity: gravity,
      )!;
      final corrected = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0.5, 0.06),
        distal: const Vec2(1, 0),
        gravity: gravity,
        cosObliquity: 0.8,
      )!;
      expect(corrected.offsetRatio,
          closeTo(uncorrected.offsetRatio * 0.8, 1e-12));
    });

    test('the reading is invariant under rolling the whole frame', () {
      double? read(double roll) {
        final radians = degreesToRadians(roll);
        final cosine = math.cos(radians);
        final sine = math.sin(radians);
        Vec2 rotate(Vec2 v) =>
            Vec2(v.x * cosine - v.y * sine, v.x * sine + v.y * cosine);
        final rolled = GravityFrame.from(rotate(const Vec2(0, 1)))!;
        return bodyLineDeviation(
          proximal: rotate(const Vec2(0, 0)),
          middle: rotate(const Vec2(0.5, 0.06)),
          distal: rotate(const Vec2(1, 0)),
          gravity: rolled,
        )?.degrees;
      }

      final reference = read(0)!;
      for (final roll in [13.0, 90.0, 180.0, -47.0, 270.0]) {
        expect(read(roll), closeTo(reference, 1e-9), reason: 'roll $roll°');
      }
    });

    test('degenerate geometry yields null rather than throwing', () {
      expect(
        bodyLineDeviation(
          proximal: const Vec2(0, 0),
          middle: const Vec2(0.5, 0),
          distal: const Vec2(0, 0),
          gravity: gravity,
        ),
        isNull,
      );
      expect(
        bodyLineDeviation(
          proximal: const Vec2(double.nan, 0),
          middle: const Vec2(0.5, 0),
          distal: const Vec2(1, 0),
          gravity: gravity,
        ),
        isNull,
      );
      expect(
        bodyLineDeviation(
          proximal: const Vec2(0, 0),
          middle: const Vec2(double.infinity, 0),
          distal: const Vec2(1, 0),
          gravity: gravity,
        ),
        isNull,
      );
    });

    test('a hip at the very end of the line cannot divide by zero', () {
      final result = bodyLineDeviation(
        proximal: const Vec2(0, 0),
        middle: const Vec2(0, 0.05),
        distal: const Vec2(1, 0),
        gravity: gravity,
      )!;
      expect(result.degrees.isFinite, isTrue);
      expect(result.hipFraction, greaterThan(0));
    });

    test('never throws on random input', () {
      final random = math.Random(555);
      double wild() => random.nextInt(6) == 0
          ? [double.nan, double.infinity, 0.0][random.nextInt(3)]
          : random.nextDouble() * 4 - 2;

      for (var i = 0; i < 20000; i++) {
        final result = bodyLineDeviation(
          proximal: Vec2(wild(), wild()),
          middle: Vec2(wild(), wild()),
          distal: Vec2(wild(), wild()),
          gravity: gravity,
          cosObliquity: wild(),
        );
        if (result != null) {
          expect(result.degrees.isFinite, isTrue);
          expect(result.offsetRatio.isFinite, isTrue);
        }
      }
    });
  });

  group('joint resolution', () {
    test('prefers the chosen side and falls back to its mirror', () {
      final frame = frameOf({
        Joint.leftHip: const Landmark(0.1, 0.2, 0.9),
        Joint.rightHip: const Landmark(0.7, 0.8, 0.9),
      });
      expect(JointResolver(frame).resolve(Joint.leftHip)!.x, closeTo(0.1, 1e-9));
      expect(
          JointResolver(frame).resolve(Joint.rightHip)!.x, closeTo(0.7, 1e-9));

      final occluded = frameOf({
        Joint.leftHip: const Landmark(0.1, 0.2, 0.05),
        Joint.rightHip: const Landmark(0.7, 0.8, 0.9),
      });
      expect(JointResolver(occluded).resolve(Joint.leftHip)!.x,
          closeTo(0.7, 1e-9));
    });

    test('reports what it could not find', () {
      final resolver = JointResolver(frameOf({}));
      expect(resolver.resolve(Joint.leftAnkle), isNull);
      expect(resolver.complete, isFalse);
      expect(resolver.missing, contains(Joint.leftAnkle));
      expect(resolver.confidence, 0);
    });

    test('a NaN landmark counts as missing', () {
      final frame = frameOf({
        Joint.leftHip: const Landmark(double.nan, 0.2, 0.9),
      });
      expect(JointResolver(frame).resolve(Joint.leftHip), isNull);
    });

    test('confidence averages only what was used', () {
      final frame = frameOf({
        Joint.leftHip: const Landmark(0.1, 0.2, 0.6),
        Joint.leftKnee: const Landmark(0.1, 0.4, 0.8),
      });
      final resolver = JointResolver(frame)
        ..resolve(Joint.leftHip)
        ..resolve(Joint.leftKnee);
      expect(resolver.confidence, closeTo(0.7, 1e-9));
      expect(resolver.complete, isTrue);
    });

    test('the dominant side follows the joints the exercise uses', () {
      // A wheelchair user's legs are not visible, so a side chosen from hips
      // and ankles would be chosen from nothing.
      final frame = frameOf({
        Joint.leftShoulder: const Landmark(0, 0, 0.3),
        Joint.leftElbow: const Landmark(0, 0, 0.3),
        Joint.leftWrist: const Landmark(0, 0, 0.3),
        Joint.rightShoulder: const Landmark(0, 0, 0.9),
        Joint.rightElbow: const Landmark(0, 0, 0.9),
        Joint.rightWrist: const Landmark(0, 0, 0.9),
      });
      expect(
        dominantSideFor(frame,
            const [Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist]),
        BodySide.right,
      );
      expect(onSide(Joint.leftWrist, BodySide.right), Joint.rightWrist);
      expect(onSide(Joint.leftWrist, BodySide.left), Joint.leftWrist);
    });

    test('a tie keeps the left side rather than flapping', () {
      final frame = frameOf({
        Joint.leftShoulder: const Landmark(0, 0, 0.7),
        Joint.rightShoulder: const Landmark(0, 0, 0.7),
      });
      expect(dominantSideFor(frame, const [Joint.leftShoulder]),
          BodySide.left);
    });
  });

  group('medianOf', () {
    test('ignores non-finite entries', () {
      expect(medianOf([1, 2, double.nan, 3, double.infinity]), 2);
      expect(medianOf([double.nan]), isNull);
      expect(medianOf(<double>[]), isNull);
    });

    test('averages the middle pair on an even count', () {
      expect(medianOf([1, 2, 3, 4]), 2.5);
    });

    test('is not moved by a single outlier', () {
      expect(medianOf([5, 5, 5, 5, 5000]), 5);
    });
  });
}
