import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'evaluator_fixtures.dart';

EvalOutput hold(ExerciseEvaluator evaluator, PoseFrame frame,
    {int count = 6}) {
  late EvalOutput output;
  for (var i = 0; i < count; i++) {
    output = evaluator.evaluate(frame);
  }
  return output;
}

void main() {
  test('declares itself, and frames portrait', () {
    final evaluator = WallSitEvaluator();
    expect(evaluator.id, ExerciseId.wallSit);
    expect(evaluator.displayName, 'Wall sit');
    expect(evaluator.thresholdVersion, 1);
    // An upright subject wastes most of a landscape frame.
    expect(evaluator.setup.landscape, isFalse);
    expect(evaluator.setup.requiredJoints, contains(Joint.leftKnee));
  });

  test('a right-angled knee passes', () {
    final output = hold(WallSitEvaluator(), wallSitFrame());
    expect(output.verdict, FormVerdict.good);
    expect(output.faults, isEmpty);
    expect(output.primaryMetric, closeTo(0, 0.2));
  });

  test('the metric is the signed departure from ninety degrees', () {
    for (final knee in [70.0, 80.0, 90.0, 100.0, 115.0]) {
      final output =
          WallSitEvaluator().evaluate(wallSitFrame(kneeAngleDegrees: knee));
      expect(output.primaryMetric, closeTo(knee - 90, 0.2),
          reason: 'at $knee°');
    }
  });

  test('hip rise is the failure this exercise actually has', () {
    final risen = hold(WallSitEvaluator(), wallSitFrame(kneeAngleDegrees: 120));
    expect(risen.verdict, FormVerdict.broken);
    expect(risen.faults, {FaultCode.hipsRisen});
    expect(risen.primaryMetric, greaterThan(0));
  });

  test('a small rise cues without stopping the clock', () {
    final evaluator = WallSitEvaluator();
    final output = hold(evaluator, wallSitFrame(kneeAngleDegrees: 108));
    expect(evaluator.level, FormLevel.degraded);
    expect(output.verdict, FormVerdict.good);
    expect(output.faults, {FaultCode.hipsRisen});
  });

  test('sinking below a right angle is named differently', () {
    final output = hold(WallSitEvaluator(), wallSitFrame(kneeAngleDegrees: 60));
    expect(output.verdict, FormVerdict.broken);
    expect(output.faults, {FaultCode.kneesBent});
    expect(output.primaryMetric, lessThan(0));
  });

  test('peeling off the wall is out of position, not broken form', () {
    final output =
        hold(WallSitEvaluator(), wallSitFrame(trunkLeanDegrees: 50));
    expect(output.verdict, FormVerdict.outOfPosition);
    expect(output.faults, contains(FaultCode.torsoLean));
  });

  test('a normal amount of trunk lean is fine', () {
    for (final lean in [0.0, 10.0, 25.0]) {
      expect(
        hold(WallSitEvaluator(), wallSitFrame(trunkLeanDegrees: lean)).verdict,
        FormVerdict.good,
        reason: 'lean $lean°',
      );
    }
  });

  group('hysteresis', () {
    test('a single bad frame never produces a cue', () {
      final evaluator = WallSitEvaluator();
      for (var i = 0; i < 5; i++) {
        evaluator.evaluate(wallSitFrame());
      }
      final blip =
          evaluator.evaluate(wallSitFrame(kneeAngleDegrees: 140));
      expect(blip.verdict, FormVerdict.good);
      expect(blip.faults, isEmpty);
      expect(evaluator.level, FormLevel.good);
    });

    test('recovery needs three consecutive frames under the tighter band', () {
      final evaluator = WallSitEvaluator();
      hold(evaluator, wallSitFrame(kneeAngleDegrees: 108));
      expect(evaluator.level, FormLevel.degraded);

      // 103° clears the 15° entry threshold but not the 11° release one.
      for (var i = 0; i < 10; i++) {
        evaluator.evaluate(wallSitFrame(kneeAngleDegrees: 103));
      }
      expect(evaluator.level, FormLevel.degraded);

      for (var i = 0; i < 3; i++) {
        evaluator.evaluate(wallSitFrame(kneeAngleDegrees: 99));
      }
      expect(evaluator.level, FormLevel.good);
    });
  });

  test('obliquity is corrected across the tolerated range', () {
    for (final phi in [0.0, 12.0, 24.0, 34.0]) {
      final output = WallSitEvaluator().evaluate(
        wallSitFrame(kneeAngleDegrees: 108, obliquityDegrees: phi),
      );
      expect(output.primaryMetric, closeTo(18, 1.0), reason: 'φ=$phi');
    }
  });

  test('rolling the phone changes nothing', () {
    final reference =
        WallSitEvaluator().evaluate(wallSitFrame(kneeAngleDegrees: 108));
    for (final roll in [29.0, 90.0, 180.0, -134.0]) {
      final output = WallSitEvaluator()
          .evaluate(wallSitFrame(kneeAngleDegrees: 108, rollDegrees: roll));
      expect(output.primaryMetric, closeTo(reference.primaryMetric!, 1e-6),
          reason: 'roll $roll°');
      expect(output.verdict, reference.verdict, reason: 'roll $roll°');
    }
  });

  test('a missing knee is indeterminate, not broken', () {
    final output = hold(
      WallSitEvaluator(),
      wallSitFrame(kneeAngleDegrees: 140, omit: {Joint.leftKnee}),
    );
    expect(output.verdict, FormVerdict.indeterminate);
    expect(output.faults, {FaultCode.outOfFrame});
    expect(output.presence, Presence.partial);
  });

  test('nobody in frame is unusable', () {
    expect(
      WallSitEvaluator()
          .evaluate(wallSitFrame(detectionConfidence: 0.05))
          .presence,
      Presence.absent,
    );
  });

  group('per-user calibration', () {
    test('adapts to the user, within the clamp', () {
      final evaluator = WallSitEvaluator()
        ..calibrate([
          for (var i = 0; i < 12; i++) wallSitFrame(kneeAngleDegrees: 100),
        ]);
      expect(evaluator.baselineDegrees, closeTo(6, 1e-6));
      expect(hold(evaluator, wallSitFrame(kneeAngleDegrees: 100)).verdict,
          FormVerdict.good);
    });

    test('a shallow baseline cannot be legitimised', () {
      final evaluator = WallSitEvaluator()
        ..calibrate([
          for (var i = 0; i < 12; i++) wallSitFrame(kneeAngleDegrees: 110),
        ]);
      expect(evaluator.baselineDegrees, closeTo(6, 1e-6));
      // Standing halfway up is still caught, however they framed.
      expect(hold(evaluator, wallSitFrame(kneeAngleDegrees: 125)).verdict,
          FormVerdict.broken);
    });

    test('reset forgets it', () {
      final evaluator = WallSitEvaluator()
        ..calibrate([
          for (var i = 0; i < 12; i++) wallSitFrame(kneeAngleDegrees: 100),
        ])
        ..reset();
      expect(evaluator.baselineDegrees, 0);
      expect(evaluator.level, FormLevel.good);
    });
  });

  test('garbage never throws', () {
    final random = math.Random(99);
    final evaluator = WallSitEvaluator();
    for (var i = 0; i < 3000; i++) {
      final output = evaluator.evaluate(garbageFrame(random));
      expect(output.confidence, inInclusiveRange(0.0, 1.0));
      if (output.presence == Presence.absent) {
        expect(output.verdict, FormVerdict.indeterminate);
      }
    }
  });
}
