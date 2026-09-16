import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'evaluator_fixtures.dart';

/// Feeds the same frame [count] times and returns the last output. Most
/// assertions care about the debounced steady state, not the first frame.
EvalOutput hold(ExerciseEvaluator evaluator, PoseFrame frame,
    {int count = 6}) {
  late EvalOutput output;
  for (var i = 0; i < count; i++) {
    output = evaluator.evaluate(frame);
  }
  return output;
}

void main() {
  group('identity', () {
    test('declares itself', () {
      final evaluator = PlankEvaluator();
      expect(evaluator.id, ExerciseId.plank);
      expect(evaluator.displayName, 'Plank');
      expect(evaluator.thresholdVersion, 1);
      expect(evaluator.setup.landscape, isTrue);
      expect(evaluator.setup.maxObliquityDegrees, 35);
      expect(evaluator.setup.requiredJoints, contains(Joint.leftAnkle));
      expect(evaluator.setup.requiresFaceVisible, isTrue);
    });

    test('the factory hands back the right implementation', () {
      for (final id in ExerciseId.values) {
        expect(evaluatorFor(id).id, id);
      }
    });
  });

  group('the measurement', () {
    test('a straight body passes immediately', () {
      final output = PlankEvaluator().evaluate(plankFrame());
      expect(output.verdict, FormVerdict.good);
      expect(output.presence, Presence.present);
      expect(output.faults, isEmpty);
      expect(output.primaryMetric, closeTo(0, 0.2));
      expect(output.confidence, greaterThan(0.5));
    });

    test('reads back the deviation it was given', () {
      for (final degrees in [-24.0, -18.0, -10.0, 0.0, 10.0, 18.0, 24.0]) {
        final evaluator = PlankEvaluator();
        final output =
            evaluator.evaluate(plankFrame(deviationDegrees: degrees));
        expect(output.primaryMetric, closeTo(degrees, 0.3),
            reason: 'at $degrees°');
      }
    });

    test('sag and pike are told apart by sign, not magnitude', () {
      final sag = hold(PlankEvaluator(), plankFrame(deviationDegrees: -18));
      final pike = hold(PlankEvaluator(), plankFrame(deviationDegrees: 18));

      expect(sag.primaryMetric, lessThan(0));
      expect(pike.primaryMetric, greaterThan(0));
      expect(sag.faults, contains(FaultCode.hipSag));
      expect(pike.faults, contains(FaultCode.hipPike));

      // The unsigned hip angle is identical for the two, which is exactly why
      // the naive angle(shoulder, hip, ankle) cannot be used here.
      expect(sag.primaryMetric!.abs(),
          closeTo(pike.primaryMetric!.abs(), 0.01));
    });
  });

  group('bands', () {
    test('good below 12 degrees', () {
      for (final degrees in [-11.5, -6.0, 0.0, 6.0, 11.5]) {
        final output =
            hold(PlankEvaluator(), plankFrame(deviationDegrees: degrees));
        expect(output.verdict, FormVerdict.good, reason: 'at $degrees°');
        expect(output.faults, isEmpty, reason: 'at $degrees°');
      }
    });

    test('degraded between 12 and 22 cues without stopping the clock', () {
      final evaluator = PlankEvaluator();
      final output = hold(evaluator, plankFrame(deviationDegrees: -17));
      expect(evaluator.level, FormLevel.degraded);
      expect(output.faults, {FaultCode.hipSag});
      // A cue, not a pause: the session machine keeps crediting.
      expect(output.verdict, FormVerdict.good);
    });

    test('broken past 22 stops the clock', () {
      final evaluator = PlankEvaluator();
      final output = hold(evaluator, plankFrame(deviationDegrees: -30));
      expect(evaluator.level, FormLevel.broken);
      expect(output.verdict, FormVerdict.broken);
      expect(output.faults, {FaultCode.hipSag});
      expect(output.presence, Presence.present);
    });

    test('a pike past 22 is broken too, and says so', () {
      final output = hold(PlankEvaluator(), plankFrame(deviationDegrees: 30));
      expect(output.verdict, FormVerdict.broken);
      expect(output.faults, {FaultCode.hipPike});
    });

    test('standing up is out of position, not broken form', () {
      final evaluator = PlankEvaluator();
      final output = hold(
        evaluator,
        plankFrame(inclinationDegrees: 80),
      );
      expect(output.verdict, FormVerdict.outOfPosition);
      expect(output.faults, contains(FaultCode.torsoLean));
    });
  });

  group('hysteresis', () {
    test('a single bad frame never produces a cue', () {
      final evaluator = PlankEvaluator();
      final good = plankFrame();
      final terrible = plankFrame(deviationDegrees: -40);

      for (var i = 0; i < 5; i++) {
        expect(evaluator.evaluate(good).faults, isEmpty);
      }
      expect(evaluator.evaluate(terrible).faults, isEmpty);
      expect(evaluator.evaluate(terrible).verdict, isNot(FormVerdict.broken));
      for (var i = 0; i < 5; i++) {
        final output = evaluator.evaluate(good);
        expect(output.faults, isEmpty);
        expect(output.verdict, FormVerdict.good);
      }
      expect(evaluator.level, FormLevel.good);
    });

    test('three of the last six is not enough', () {
      final evaluator = PlankEvaluator();
      final good = plankFrame();
      final bad = plankFrame(deviationDegrees: -30);

      for (var i = 0; i < 12; i++) {
        evaluator.evaluate(i.isEven ? good : bad);
      }
      expect(evaluator.level, FormLevel.good);
    });

    test('four of the last six escalates', () {
      final evaluator = PlankEvaluator();
      final good = plankFrame();
      final bad = plankFrame(deviationDegrees: -30);

      evaluator.evaluate(good);
      evaluator.evaluate(good);
      for (var i = 0; i < 3; i++) {
        evaluator.evaluate(bad);
        expect(evaluator.level, FormLevel.good, reason: 'after ${i + 1} bad');
      }
      expect(evaluator.evaluate(bad).verdict, FormVerdict.broken);
    });

    test('a sudden collapse skips straight to broken', () {
      final evaluator = PlankEvaluator();
      final bad = plankFrame(deviationDegrees: -35);
      for (var i = 0; i < 4; i++) {
        evaluator.evaluate(bad);
      }
      expect(evaluator.level, FormLevel.broken);
    });

    test('recovery needs three consecutive frames under the tighter band', () {
      final evaluator = PlankEvaluator();
      hold(evaluator, plankFrame(deviationDegrees: -17));
      expect(evaluator.level, FormLevel.degraded);

      // 10° clears the 12° entry threshold but not the 9° release threshold,
      // so it must not forgive anything. This is the oscillation the release
      // margin exists to stop.
      for (var i = 0; i < 20; i++) {
        evaluator.evaluate(plankFrame(deviationDegrees: -10));
      }
      expect(evaluator.level, FormLevel.degraded);

      final clean = plankFrame(deviationDegrees: -8);
      evaluator.evaluate(clean);
      expect(evaluator.level, FormLevel.degraded);
      evaluator.evaluate(clean);
      expect(evaluator.level, FormLevel.degraded);
      expect(evaluator.evaluate(clean).faults, isEmpty);
      expect(evaluator.level, FormLevel.good);
    });

    test('a broken hold released by clean frames comes all the way back', () {
      final evaluator = PlankEvaluator();
      hold(evaluator, plankFrame(deviationDegrees: -30));
      expect(evaluator.level, FormLevel.broken);

      final clean = plankFrame();
      evaluator.evaluate(clean);
      evaluator.evaluate(clean);
      final output = evaluator.evaluate(clean);
      expect(evaluator.level, FormLevel.good);
      expect(output.verdict, FormVerdict.good);
    });

    test('reset clears the ladder', () {
      final evaluator = PlankEvaluator();
      hold(evaluator, plankFrame(deviationDegrees: -30));
      expect(evaluator.level, FormLevel.broken);
      evaluator.reset();
      expect(evaluator.level, FormLevel.good);
      expect(evaluator.baselineDegrees, 0);
    });
  });

  group('obliquity', () {
    test('the correction holds across the tolerated range', () {
      for (final truth in [0.0, -8.0, -18.0, 16.0]) {
        final readings = <double>[];
        for (final phi in [0.0, 10.0, 20.0, 30.0, 34.0]) {
          final evaluator = PlankEvaluator();
          final output = evaluator.evaluate(
            plankFrame(deviationDegrees: truth, obliquityDegrees: phi),
          );
          expect(output.verdict, isNot(FormVerdict.indeterminate),
              reason: 'φ=$phi');
          readings.add(output.primaryMetric!);
        }
        for (final reading in readings) {
          expect(reading, closeTo(truth, 0.5),
              reason: 'true $truth°, readings $readings');
        }
      }
    });

    test('without the correction an oblique view would over-read', () {
      // Sanity check that the fixture really does inflate the raw measurement,
      // so the test above is testing something. At 34° obliquity a true 18°
      // sag would read near 21.5° uncorrected, which is most of the way to the
      // broken threshold — a false reject manufactured by camera placement.
      final evaluator = PlankEvaluator();
      final corrected = evaluator
          .evaluate(plankFrame(deviationDegrees: -18, obliquityDegrees: 34))
          .primaryMetric!;
      expect(corrected, closeTo(-18, 0.5));
      expect(18 / math.cos(math.pi * 34 / 180), greaterThan(21));
    });

    test('past the limit we stop judging rather than judge wrongly', () {
      for (final deviation in [0.0, -30.0]) {
        final evaluator = PlankEvaluator();
        final output = hold(
          evaluator,
          plankFrame(deviationDegrees: deviation, obliquityDegrees: 50),
        );
        expect(output.verdict, FormVerdict.indeterminate);
        expect(output.faults, {FaultCode.tooOblique});
        expect(output.presence, Presence.present);
      }
    });

    test('too oblique holds the ladder rather than feeding it', () {
      final evaluator = PlankEvaluator();
      for (var i = 0; i < 20; i++) {
        evaluator.evaluate(
          plankFrame(deviationDegrees: -40, obliquityDegrees: 50),
        );
      }
      // Twenty frames of unreadable geometry must leave us where we started,
      // not accumulate into an accusation.
      expect(evaluator.level, FormLevel.good);
    });
  });

  group('gravity independence', () {
    test('rolling the phone changes nothing', () {
      for (final deviation in [0.0, -17.0, -30.0, 20.0]) {
        final reference = PlankEvaluator()
            .evaluate(plankFrame(deviationDegrees: deviation));
        for (final roll in [0.0, 17.0, 45.0, 90.0, 143.0, 180.0, -62.0]) {
          final output = PlankEvaluator().evaluate(
            plankFrame(deviationDegrees: deviation, rollDegrees: roll),
          );
          expect(output.verdict, reference.verdict, reason: 'roll $roll°');
          expect(output.faults, reference.faults, reason: 'roll $roll°');
          expect(output.primaryMetric,
              closeTo(reference.primaryMetric!, 1e-6),
              reason: 'roll $roll°');
        }
      }
    });

    test('a rolled phone still tells sag from pike', () {
      final sag = PlankEvaluator()
          .evaluate(plankFrame(deviationDegrees: -20, rollDegrees: 118));
      final pike = PlankEvaluator()
          .evaluate(plankFrame(deviationDegrees: 20, rollDegrees: 118));
      expect(sag.primaryMetric, lessThan(0));
      expect(pike.primaryMetric, greaterThan(0));
    });
  });

  group('degenerate input is never the user\'s fault', () {
    test('a missing ankle is indeterminate, not broken', () {
      final evaluator = PlankEvaluator();
      final output = hold(
        evaluator,
        plankFrame(
          deviationDegrees: -40,
          extra: {Joint.leftAnkle: const Landmark(0, 0, 0.1)},
        ),
      );
      expect(output.verdict, FormVerdict.indeterminate);
      expect(output.faults, {FaultCode.outOfFrame});
      expect(output.presence, Presence.partial);
    });

    test('nobody in frame is unusable', () {
      final evaluator = PlankEvaluator();
      expect(evaluator.evaluate(plankFrame(detectionConfidence: 0.1)).verdict,
          FormVerdict.indeterminate);
      expect(evaluator.evaluate(plankFrame(detectionConfidence: 0.1)).presence,
          Presence.absent);
      expect(evaluator.evaluate(plankFrame(personCount: 0)).presence,
          Presence.absent);
      expect(
        evaluator
            .evaluate(plankFrame(detectionConfidence: double.nan))
            .confidence,
        0,
      );
    });

    test('a dead accelerometer is unusable, not broken', () {
      final frame = plankFrame(deviationDegrees: -40);
      final dead = PoseFrame(
        monotonic: frame.monotonic,
        landmarks: frame.landmarks,
        gravity: const Vec2(0, 0),
        detectionConfidence: frame.detectionConfidence,
      );
      final nan = PoseFrame(
        monotonic: frame.monotonic,
        landmarks: frame.landmarks,
        gravity: const Vec2(double.nan, 1),
        detectionConfidence: frame.detectionConfidence,
      );
      expect(hold(PlankEvaluator(), dead).verdict, FormVerdict.indeterminate);
      expect(hold(PlankEvaluator(), nan).verdict, FormVerdict.indeterminate);
    });

    test('a zero-length body is unusable', () {
      final output = hold(
        PlankEvaluator(),
        plankFrame(
          extra: {Joint.leftAnkle: const Landmark(0.30, 0.45, 0.9)},
        ),
      );
      expect(output.verdict, FormVerdict.indeterminate);
      expect(output.presence, Presence.absent);
    });

    test('NaN landmarks are unusable', () {
      final output = hold(
        PlankEvaluator(),
        plankFrame(
          extra: {
            Joint.leftHip: const Landmark(double.nan, double.nan, 0.9),
          },
        ),
      );
      expect(output.verdict, FormVerdict.indeterminate);
      expect(output.verdict, isNot(FormVerdict.broken));
    });

    test('fuzzing garbage frames never throws and never accuses', () {
      final random = math.Random(20260916);
      final evaluator = PlankEvaluator();
      for (var i = 0; i < 4000; i++) {
        final output = evaluator.evaluate(garbageFrame(random));
        expect(output.confidence, inInclusiveRange(0.0, 1.0));
        final metric = output.primaryMetric;
        if (metric != null) expect(metric.isFinite, isTrue);
        if (output.presence == Presence.absent) {
          expect(output.verdict, FormVerdict.indeterminate);
        }
      }
    });

    test('calibrating on garbage leaves the zero alone', () {
      final random = math.Random(7);
      final evaluator = PlankEvaluator();
      evaluator.calibrate([
        for (var i = 0; i < 200; i++) garbageFrame(random),
      ]);
      expect(evaluator.baselineDegrees, 0);
    });
  });

  group('per-user calibration', () {
    List<PoseFrame> baseline(double degrees, {int frames = 12}) => [
          for (var i = 0; i < frames; i++)
            plankFrame(deviationDegrees: degrees),
        ];

    test('measures deviation against the user\'s own body', () {
      final evaluator = PlankEvaluator()..calibrate(baseline(-5));
      expect(evaluator.baselineDegrees, closeTo(-5, 0.3));

      final output = evaluator.evaluate(plankFrame(deviationDegrees: -5));
      expect(output.primaryMetric, closeTo(0, 0.3));
      expect(output.verdict, FormVerdict.good);
    });

    test('a sagging baseline is clamped, not honoured', () {
      final evaluator = PlankEvaluator()..calibrate(baseline(-20));
      expect(evaluator.baselineDegrees, closeTo(-6, 1e-9));

      // Holding exactly the baseline they framed up in still reads as a fault,
      // which is the entire point of the clamp.
      final output = hold(evaluator, plankFrame(deviationDegrees: -20));
      expect(output.primaryMetric, closeTo(-14, 0.3));
      expect(output.faults, {FaultCode.hipSag});
    });

    test('the clamp bounds how far good can ever move', () {
      final evaluator = PlankEvaluator()..calibrate(baseline(-30));
      // Even a wildly sagging baseline cannot push the good boundary past 18°,
      // which is inside the degraded band and never into broken.
      expect(evaluator.baselineDegrees.abs(), lessThanOrEqualTo(6));
      expect(hold(evaluator, plankFrame(deviationDegrees: -25)).verdict,
          isNot(FormVerdict.good));
    });

    test('one wild frame cannot move the baseline', () {
      final frames = baseline(-4)
        ..insert(3, plankFrame(deviationDegrees: -21))
        ..insert(8, plankFrame(deviationDegrees: 21));
      final evaluator = PlankEvaluator()..calibrate(frames);
      expect(evaluator.baselineDegrees, closeTo(-4, 0.5));
    });

    test('frames where they were not in position are ignored', () {
      final evaluator = PlankEvaluator()
        ..calibrate([
          for (var i = 0; i < 30; i++)
            plankFrame(deviationDegrees: -15, inclinationDegrees: 80),
        ]);
      expect(evaluator.baselineDegrees, 0);
    });

    test('too few usable frames leaves the zero alone', () {
      final evaluator = PlankEvaluator()..calibrate(baseline(-5, frames: 4));
      expect(evaluator.baselineDegrees, 0);
    });

    test('reset forgets the baseline', () {
      final evaluator = PlankEvaluator()..calibrate(baseline(-5));
      expect(evaluator.baselineDegrees, isNot(0));
      evaluator.reset();
      expect(evaluator.baselineDegrees, 0);
    });
  });

  group('side selection', () {
    test('a right-facing subject reads identically to a left-facing one', () {
      final left = PlankEvaluator().evaluate(plankFrame(deviationDegrees: -17));
      final right = PlankEvaluator()
          .evaluate(plankFrame(deviationDegrees: -17, mirrored: true));
      expect(right.primaryMetric, closeTo(left.primaryMetric!, 1e-9));
      expect(right.verdict, left.verdict);
    });
  });
}
