import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/pose/pose_geometry.dart';
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
  test('declares itself', () {
    final evaluator = KneePlankEvaluator();
    expect(evaluator.id, ExerciseId.kneePlank);
    expect(evaluator.displayName, 'Knee plank');
    expect(evaluator.thresholdVersion, 1);
    expect(evaluator.setup.landscape, isTrue);
    expect(evaluator.setup.requiredJoints, contains(Joint.leftKnee));
    expect(evaluator.setup.requiredJoints, isNot(contains(Joint.leftAnkle)));
  });

  test('knees down is the exercise, not a fault', () {
    // No ankle landmarks at all. Nothing about this may be penalised.
    final frame = kneePlankFrame();
    expect(frame.landmarks.containsKey(Joint.leftAnkle), isFalse);

    final output = hold(KneePlankEvaluator(), frame);
    expect(output.verdict, FormVerdict.good);
    expect(output.faults, isEmpty);
    expect(output.presence, Presence.present);
  });

  test('reads the deviation off the shoulder-to-knee line', () {
    for (final degrees in [-20.0, -9.0, 0.0, 9.0, 20.0]) {
      final output = KneePlankEvaluator()
          .evaluate(kneePlankFrame(deviationDegrees: degrees));
      expect(output.primaryMetric, closeTo(degrees, 0.3),
          reason: 'at $degrees°');
    }
  });

  test('sag and pike are still told apart by sign', () {
    final sag = hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: -20));
    final pike = hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: 20));
    expect(sag.faults, contains(FaultCode.hipSag));
    expect(pike.faults, contains(FaultCode.hipPike));
  });

  test('the band is wider than the plank, and deliberately so', () {
    // 13° of hip angle. The shorter lever means this is a smaller absolute
    // droop than the same number on a full plank, so judging it on the plank's
    // 12° would make the accessible variant the strictest exercise we ship.
    expect(
      hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: -13)).faults,
      isEmpty,
    );
    expect(
      hold(PlankEvaluator(), plankFrame(deviationDegrees: -13)).faults,
      {FaultCode.hipSag},
    );
  });

  test('bands land where the thresholds say', () {
    expect(hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: -19))
        .verdict, FormVerdict.good);
    expect(hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: -19))
        .faults, {FaultCode.hipSag});
    expect(hold(KneePlankEvaluator(), kneePlankFrame(deviationDegrees: -30))
        .verdict, FormVerdict.broken);
  });

  test('the steeper body line a knee plank really has is accepted', () {
    for (final inclination in [12.0, 24.0, 35.0]) {
      final output = hold(
        KneePlankEvaluator(),
        kneePlankFrame(inclinationDegrees: inclination),
      );
      expect(output.verdict, FormVerdict.good, reason: 'at $inclination°');
    }
  });

  test('kneeling upright is out of position', () {
    final output =
        hold(KneePlankEvaluator(), kneePlankFrame(inclinationDegrees: 70));
    expect(output.verdict, FormVerdict.outOfPosition);
  });

  test('the obliquity correction uses the shorter body length', () {
    for (final phi in [0.0, 12.0, 24.0, 34.0]) {
      final output = KneePlankEvaluator().evaluate(
        kneePlankFrame(deviationDegrees: -16, obliquityDegrees: phi),
      );
      expect(output.primaryMetric, closeTo(-16, 0.6), reason: 'φ=$phi');
    }
  });

  test('a realistic hip position along the line is handled', () {
    // The hip sits much further along a shoulder→knee line than a
    // shoulder→ankle one, so the lever arm has to come from the geometry
    // rather than from a constant.
    final output = KneePlankEvaluator().evaluate(
      bodyLineFrame(
        distal: Joint.leftKnee,
        deviationDegrees: -17,
        inclinationDegrees: 24,
        bodyLength: 0.42,
        hipFraction: 0.62,
        breadthRatio: kShoulderBreadthOverShoulderKnee,
      ),
    );
    expect(output.primaryMetric, closeTo(-17, 0.5));
  });

  test('rolling the phone changes nothing', () {
    final reference =
        KneePlankEvaluator().evaluate(kneePlankFrame(deviationDegrees: -19));
    for (final roll in [33.0, 90.0, 205.0, -77.0]) {
      final output = KneePlankEvaluator()
          .evaluate(kneePlankFrame(deviationDegrees: -19, rollDegrees: roll));
      expect(output.primaryMetric, closeTo(reference.primaryMetric!, 1e-6),
          reason: 'roll $roll°');
    }
  });

  test('calibration is clamped here too', () {
    final evaluator = KneePlankEvaluator()
      ..calibrate([
        for (var i = 0; i < 12; i++) kneePlankFrame(deviationDegrees: -22),
      ]);
    expect(evaluator.baselineDegrees.abs(), lessThanOrEqualTo(6));
  });

  test('garbage never throws', () {
    final random = math.Random(4242);
    final evaluator = KneePlankEvaluator();
    for (var i = 0; i < 2000; i++) {
      final output = evaluator.evaluate(garbageFrame(random));
      expect(output.confidence, inInclusiveRange(0.0, 1.0));
    }
  });
}
