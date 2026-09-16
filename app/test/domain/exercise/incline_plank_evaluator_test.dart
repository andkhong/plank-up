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
  test('declares itself', () {
    final evaluator = InclinePlankEvaluator();
    expect(evaluator.id, ExerciseId.inclinePlank);
    expect(evaluator.displayName, 'Incline plank');
    expect(evaluator.thresholdVersion, 1);
    expect(evaluator.setup.landscape, isTrue);
  });

  test('accepts the angled body line the exercise is defined by', () {
    for (final inclination in [2.0, 15.0, 25.0, 35.0, 50.0, 58.0]) {
      final output = hold(
        InclinePlankEvaluator(),
        inclinePlankFrame(inclinationDegrees: inclination),
      );
      expect(output.verdict, FormVerdict.good, reason: 'at $inclination°');
      expect(output.faults, isEmpty, reason: 'at $inclination°');
    }
  });

  test('the plank gate would have rejected a correct incline plank', () {
    // This is the whole reason the variant needs its own gate: a 45° body is
    // simply not a floor plank, and the floor plank's horizontality check says
    // so on the first frame.
    final frame = inclinePlankFrame(inclinationDegrees: 45);
    expect(hold(PlankEvaluator(), frame).verdict, FormVerdict.outOfPosition);
    expect(hold(InclinePlankEvaluator(), frame).verdict, FormVerdict.good);
  });

  test('standing upright is still out of position', () {
    final output = hold(
      InclinePlankEvaluator(),
      inclinePlankFrame(inclinationDegrees: 75),
    );
    expect(output.verdict, FormVerdict.outOfPosition);
    expect(output.faults, contains(FaultCode.torsoLean));
  });

  test('feet above shoulders is not an incline plank', () {
    final output = hold(
      InclinePlankEvaluator(),
      inclinePlankFrame(inclinationDegrees: -25),
    );
    expect(output.verdict, FormVerdict.outOfPosition);
  });

  test('sag and pike survive the angled body line', () {
    for (final inclination in [20.0, 35.0, 50.0]) {
      final sag = hold(
        InclinePlankEvaluator(),
        inclinePlankFrame(
            deviationDegrees: -30, inclinationDegrees: inclination),
      );
      final pike = hold(
        InclinePlankEvaluator(),
        inclinePlankFrame(
            deviationDegrees: 30, inclinationDegrees: inclination),
      );
      expect(sag.primaryMetric, lessThan(0), reason: 'at $inclination°');
      expect(pike.primaryMetric, greaterThan(0), reason: 'at $inclination°');
      expect(sag.faults, {FaultCode.hipSag}, reason: 'at $inclination°');
      expect(pike.faults, {FaultCode.hipPike}, reason: 'at $inclination°');
      expect(sag.verdict, FormVerdict.broken, reason: 'at $inclination°');
    }
  });

  test('the reading does not shrink as the body tilts', () {
    // A naive `offset · gravityUp` would read a true 18° sag as roughly 12° at
    // a 35° incline and 7° at 50°, quietly turning the incline variant into the
    // most permissive exercise in the app.
    final readings = <double>[];
    for (final inclination in [5.0, 20.0, 35.0, 50.0]) {
      readings.add(
        InclinePlankEvaluator()
            .evaluate(inclinePlankFrame(
              deviationDegrees: -18,
              inclinationDegrees: inclination,
            ))
            .primaryMetric!,
      );
    }
    for (final reading in readings) {
      expect(reading, closeTo(-18, 0.6), reason: 'readings $readings');
    }
  });

  test('bands land where the thresholds say', () {
    expect(
      hold(InclinePlankEvaluator(), inclinePlankFrame(deviationDegrees: -12))
          .faults,
      isEmpty,
    );
    expect(
      hold(InclinePlankEvaluator(), inclinePlankFrame(deviationDegrees: -18))
          .verdict,
      FormVerdict.good,
    );
    expect(
      hold(InclinePlankEvaluator(), inclinePlankFrame(deviationDegrees: -18))
          .faults,
      {FaultCode.hipSag},
    );
    expect(
      hold(InclinePlankEvaluator(), inclinePlankFrame(deviationDegrees: -28))
          .verdict,
      FormVerdict.broken,
    );
  });

  test('obliquity correction holds at an incline', () {
    for (final phi in [0.0, 15.0, 30.0, 34.0]) {
      final output = InclinePlankEvaluator().evaluate(
        inclinePlankFrame(deviationDegrees: -16, obliquityDegrees: phi),
      );
      expect(output.primaryMetric, closeTo(-16, 0.6), reason: 'φ=$phi');
    }
  });

  test('rolling the phone changes nothing', () {
    final reference = InclinePlankEvaluator()
        .evaluate(inclinePlankFrame(deviationDegrees: -18));
    for (final roll in [21.0, 90.0, 167.0, -90.0]) {
      final output = InclinePlankEvaluator().evaluate(
        inclinePlankFrame(deviationDegrees: -18, rollDegrees: roll),
      );
      expect(output.primaryMetric, closeTo(reference.primaryMetric!, 1e-6),
          reason: 'roll $roll°');
      expect(output.verdict, reference.verdict, reason: 'roll $roll°');
    }
  });

  test('hysteresis suppresses a single bad frame', () {
    final evaluator = InclinePlankEvaluator();
    final good = inclinePlankFrame();
    for (var i = 0; i < 5; i++) {
      evaluator.evaluate(good);
    }
    expect(
      evaluator
          .evaluate(inclinePlankFrame(deviationDegrees: -45))
          .verdict,
      FormVerdict.good,
    );
    expect(evaluator.level, FormLevel.good);
  });

  test('garbage never throws', () {
    final random = math.Random(31337);
    final evaluator = InclinePlankEvaluator();
    for (var i = 0; i < 2000; i++) {
      final output = evaluator.evaluate(garbageFrame(random));
      expect(output.confidence, inInclusiveRange(0.0, 1.0));
    }
  });
}
