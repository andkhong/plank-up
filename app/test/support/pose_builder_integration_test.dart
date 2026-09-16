/// The synthetic pose generator, run against the real evaluator.
///
/// `pose_builder_test.dart` checks the builder against an oracle written from
/// the same definition, which proves it is self-consistent. That is necessary
/// and it is not sufficient: a builder can be perfectly self-consistent and
/// still describe a body the production geometry code reads differently,
/// because the two agreed on a formula and disagreed on a sign, an axis or a
/// normalisation.
///
/// So this file closes the loop. It hands [PlankEvaluator] a body built to a
/// stated geometry and asks whether the number comes back out. If the builder
/// and the evaluator ever drift apart on what "8 degrees of sag" means, every
/// threshold in the product is quietly wrong, and this is the test that says so.
///
/// The assertions are deliberately contract-level — recovers the angle, ignores
/// phone roll, corrects for obliquity, never false-breaks on a body it cannot
/// see — rather than pinned to the evaluator's internal numbers, so this stays
/// a cross-check and does not become a second copy of the evaluator's own tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'pose_builder.dart';

/// One frame through a freshly reset evaluator, so smoothing state from a
/// previous case cannot leak into this one.
EvalOutput evaluateOnce(ExerciseEvaluator evaluator, PoseFrame frame) {
  evaluator.reset();
  return evaluator.evaluate(frame);
}

/// Holds a geometry for long enough that hysteresis has settled, then reports
/// the final verdict — which is what the user would actually experience.
EvalOutput evaluateSettled(
  ExerciseEvaluator evaluator,
  PoseBuilder pose, {
  int frames = 12,
}) {
  evaluator.reset();
  var output = EvalOutput.unusable;
  for (final frame in holdPose(pose,
      duration: Duration(milliseconds: (frames * 1000 / 15).round()))) {
    output = evaluator.evaluate(frame);
  }
  return output;
}

void main() {
  late PlankEvaluator evaluator;

  setUp(() => evaluator = PlankEvaluator());

  group('the evaluator recovers the geometry it was handed', () {
    test('across the whole deviation range', () {
      for (var requested = -40.0; requested <= 40.0; requested += 2.5) {
        final output = evaluateOnce(
            evaluator, PoseBuilder(hipDeviationDegrees: requested).build());
        expect(output.primaryMetric, isNotNull, reason: 'at $requested');
        expect(output.primaryMetric!, closeTo(requested, 0.5),
            reason: 'asked for $requested degrees');
      }
    });

    test('a straight body reads as straight', () {
      final output = evaluateOnce(evaluator, const PoseBuilder().build());
      expect(output.primaryMetric!, closeTo(0, 0.01));
    });

    test('the sign survives the round trip, which is the whole point', () {
      // An unsigned `angle(shoulder, hip, ankle)` cannot tell a sag from a
      // pike. Both ends of the sign have to come back intact or the product
      // coaches the wrong correction.
      final sag =
          evaluateOnce(evaluator, const PoseBuilder(hipDeviationDegrees: -18).build());
      final pike =
          evaluateOnce(evaluator, const PoseBuilder(hipDeviationDegrees: 18).build());
      expect(sag.primaryMetric!, lessThan(0));
      expect(pike.primaryMetric!, greaterThan(0));
      expect(sag.primaryMetric!.abs(), closeTo(pike.primaryMetric!.abs(), 0.1));
      // 18 degrees is degraded rather than broken, so neither names a fault yet
      // — the sign is carrying all of the information at this point, which is
      // exactly the situation the signed metric exists for.
      expect(sag.verdict, pike.verdict);
    });

    test('body size does not change the angle', () {
      for (final length in [0.3, 0.45, 0.62, 0.85]) {
        final output = evaluateOnce(
            evaluator,
            PoseBuilder(bodyLength: length, hipDeviationDegrees: -14).build());
        expect(output.primaryMetric!, closeTo(-14, 0.5), reason: 'L=$length');
      }
    });

    test('it does not matter which side faces the camera', () {
      for (final facing in BodySide.values) {
        final output = evaluateOnce(evaluator,
            PoseBuilder(facing: facing, hipDeviationDegrees: -16).build());
        expect(output.primaryMetric!, closeTo(-16, 0.5), reason: '$facing');
      }
    });
  });

  group('gravity is measured, not assumed', () {
    test('phone roll does not change the reading', () {
      // The phone is propped on the floor at whatever angle it ended up at, so
      // image-space "up" is meaningless. Every reading here has to come out the
      // same or the product's accuracy depends on how carefully someone
      // balanced their phone.
      final level = evaluateOnce(
          evaluator, const PoseBuilder(hipDeviationDegrees: -15).build());

      for (final roll in [-90.0, -47.0, -15.0, 0.0, 15.0, 47.0, 90.0, 180.0]) {
        final rolled = evaluateOnce(
            evaluator,
            PoseBuilder(hipDeviationDegrees: -15, phoneRollDegrees: roll)
                .build());
        expect(rolled.primaryMetric!, closeTo(level.primaryMetric!, 0.01),
            reason: 'rolled $roll degrees');
      }
    });

    test('roll does not change the verdict either', () {
      for (final roll in [0.0, 30.0, 60.0, 120.0]) {
        final output = evaluateSettled(
            evaluator,
            PoseBuilder(hipDeviationDegrees: -4, phoneRollDegrees: roll));
        expect(output.verdict, FormVerdict.good, reason: 'rolled $roll');
      }
    });

    test('a non-unit gravity vector is normalised rather than trusted', () {
      final unit = evaluateOnce(
          evaluator, const PoseBuilder(hipDeviationDegrees: -10).build());
      final raw = evaluateOnce(
          evaluator,
          const PoseBuilder(hipDeviationDegrees: -10, gravityMagnitude: 9.81)
              .build());
      expect(raw.primaryMetric!, closeTo(unit.primaryMetric!, 0.01));
    });
  });

  group('obliquity is corrected, not merely tolerated', () {
    test('the reading stays on the true angle as the body turns', () {
      const trueDeviation = -10.0;
      for (final phi in [0.0, 5.0, 10.0, 20.0, 30.0]) {
        final pose = PoseBuilder(
          hipDeviationDegrees: trueDeviation,
          obliquityDegrees: phi,
        ).annotate();

        final output = evaluateOnce(evaluator, pose.frame);

        // The uncorrected reading is meaningfully wrong by 30 degrees off
        // side-on; the corrected one must not be.
        expect(output.primaryMetric!, closeTo(trueDeviation, 0.6),
            reason: 'at $phi degrees oblique');
        if (phi >= 20) {
          expect((output.primaryMetric! - trueDeviation).abs(),
              lessThan((pose.apparentHipDeviationDegrees - trueDeviation).abs()),
              reason: 'the correction has to actually be doing something '
                  'at $phi degrees');
        }
      }
    });

    test('an obliquity that would flip a band does not flip it', () {
      // 11 degrees of true sag is good form. Read off the image at 30 degrees
      // oblique it looks like roughly 12.7, which is past the degraded
      // threshold. Getting this wrong means telling someone with good form that
      // their hips are dropping, because of how they set their phone down.
      final pose = const PoseBuilder(
        hipDeviationDegrees: -11,
        obliquityDegrees: 30,
      ).annotate();
      expect(pose.apparentHipDeviationDegrees.abs(), greaterThan(12),
          reason: 'the fixture has to actually straddle the band');

      final output = evaluateSettled(
          evaluator,
          const PoseBuilder(hipDeviationDegrees: -11, obliquityDegrees: 30));
      expect(output.verdict, FormVerdict.good);
    });

    test('roll and obliquity together still read true', () {
      final output = evaluateOnce(
          evaluator,
          const PoseBuilder(
            hipDeviationDegrees: -8,
            obliquityDegrees: 20,
            phoneRollDegrees: 15,
          ).build());
      expect(output.primaryMetric!, closeTo(-8, 0.6));
    });
  });

  group('bands and verdicts', () {
    test('clean form is good, plainly broken form is broken', () {
      expect(
          evaluateSettled(evaluator, const PoseBuilder(hipDeviationDegrees: -3))
              .verdict,
          FormVerdict.good);
      expect(
          evaluateSettled(evaluator, const PoseBuilder(hipDeviationDegrees: -30))
              .verdict,
          FormVerdict.broken);
      expect(
          evaluateSettled(evaluator, const PoseBuilder(hipDeviationDegrees: 30))
              .verdict,
          FormVerdict.broken);
    });

    test('a broken body names a fault, and it is the right one', () {
      final sag =
          evaluateSettled(evaluator, const PoseBuilder(hipDeviationDegrees: -30));
      final pike =
          evaluateSettled(evaluator, const PoseBuilder(hipDeviationDegrees: 30));
      expect(sag.faults, contains(FaultCode.hipSag));
      expect(pike.faults, contains(FaultCode.hipPike));
    });

    test('one bad frame in a clean hold does not break the verdict', () {
      // The design's answer to "one bad frame shouldn't trigger a warning".
      // Worth pinning from this side too, because it is the difference between
      // a coach and a nag.
      evaluator.reset();
      final clean = holdPose(const PoseBuilder(hipDeviationDegrees: -4),
          duration: const Duration(seconds: 2));
      for (final frame in clean) {
        evaluator.evaluate(frame);
      }

      final glitch =
          const PoseBuilder(hipDeviationDegrees: -40, monotonic: Duration(seconds: 3))
              .build();
      expect(evaluator.evaluate(glitch).verdict, FormVerdict.good);
    });
  });

  group('low confidence is never bad form', () {
    test('losing the ankles is indeterminate, not broken', () {
      // "If we cannot see you, that is our problem." A missing joint must route
      // to indeterminate so the session machine sends it to `lost` with the
      // long budget, not to `paused` with the short one.
      final output = evaluateSettled(
          evaluator,
          const PoseBuilder(
            hipDeviationDegrees: -30,
            missing: {Joint.leftAnkle, Joint.rightAnkle},
          ));
      expect(output.verdict, FormVerdict.indeterminate);
      expect(output.verdict, isNot(FormVerdict.broken));
    });

    test('a uniformly unconfident skeleton is indeterminate', () {
      final output = evaluateSettled(
          evaluator, const PoseBuilder(hipDeviationDegrees: -30, confidence: 0.1));
      expect(output.verdict, FormVerdict.indeterminate);
    });

    test('losing the face does not by itself break the verdict', () {
      // BlazePose wants a visible head, but a tucked chin is a framing problem
      // for the setup gate, not a form fault mid-hold.
      final output = evaluateSettled(
          evaluator,
          const PoseBuilder(
            hipDeviationDegrees: -3,
            missing: {Joint.nose, Joint.leftEar, Joint.rightEar},
          ));
      expect(output.verdict, isNot(FormVerdict.broken));
    });

    test('an empty frame never throws and never accuses the user', () {
      final output = evaluateOnce(
          evaluator, PoseBuilder(missing: Joint.values.toSet()).build());
      expect(output.verdict, FormVerdict.indeterminate);
    });
  });

  group('every shipped evaluator survives the builder', () {
    test('none of them throws on a body, however degenerate', () {
      // The contract is that an evaluator must never throw on degenerate input.
      // The builder can produce degenerate input on demand, so it may as well.
      final poses = [
        const PoseBuilder(),
        const PoseBuilder(hipDeviationDegrees: -170),
        const PoseBuilder(bodyLength: 0.001),
        const PoseBuilder(obliquityDegrees: 89.9),
        const PoseBuilder(obliquityDegrees: 90),
        const PoseBuilder(phoneRollDegrees: 180),
        const PoseBuilder(confidence: 0),
        const PoseBuilder(gravityMagnitude: 0),
        const PoseBuilder(personCount: 0, detectionConfidence: 0),
        PoseBuilder(missing: Joint.values.toSet()),
      ];

      for (final id in ExerciseId.values) {
        final subject = evaluatorFor(id);
        for (final pose in poses) {
          subject.reset();
          expect(() => subject.evaluate(pose.build()), returnsNormally,
              reason: '${id.name} on $pose');
        }
      }
    });

    test('none of them calls good form broken on a clean plank body', () {
      // Not every evaluator should call a plank *good* — a wall sit should not.
      // But none of them may call a clean, well-lit, correctly-framed body a
      // form break, because a false reject is the expensive error.
      final frame = const PoseBuilder(hipDeviationDegrees: -2).build();
      for (final id in [
        ExerciseId.plank,
        ExerciseId.kneePlank,
        ExerciseId.inclinePlank,
      ]) {
        final subject = evaluatorFor(id)..reset();
        var verdict = FormVerdict.indeterminate;
        for (final f in holdPose(const PoseBuilder(hipDeviationDegrees: -2),
            duration: const Duration(seconds: 1))) {
          verdict = subject.evaluate(f).verdict;
        }
        expect(verdict, isNot(FormVerdict.broken), reason: id.name);
        expect(frame.landmarks, isNotEmpty);
      }
    });
  });
}
