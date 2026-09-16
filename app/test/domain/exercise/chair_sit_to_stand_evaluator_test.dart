import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'evaluator_fixtures.dart';

/// Drives the evaluator at a realistic 15 Hz, in knee-angle space.
class Driver {
  Driver(this.evaluator, {this.step = const Duration(milliseconds: 66)});

  final ChairSitToStandEvaluator evaluator;
  final Duration step;

  Duration now = Duration.zero;
  EvalOutput last = EvalOutput.unusable;

  void at(
    double kneeAngle,
    int frames, {
    Set<Joint> omit = const {},
    double roll = 0,
  }) {
    for (var i = 0; i < frames; i++) {
      now += step;
      last = evaluator.evaluate(sitToStandFrame(
        kneeAngleDegrees: kneeAngle,
        monotonic: now,
        omit: omit,
        rollDegrees: roll,
      ));
    }
  }

  void sweep(double from, double to, int frames, {double roll = 0}) {
    for (var i = 1; i <= frames; i++) {
      at(from + (to - from) * i / frames, 1, roll: roll);
    }
  }

  /// Sit, stand, sit — about 2.7 seconds, which is what a real one takes.
  void rep({double bottom = 85, double top = 175, double roll = 0}) {
    at(bottom, 5, roll: roll);
    sweep(bottom, top, 20, roll: roll);
    at(top, 5, roll: roll);
    sweep(top, bottom, 20, roll: roll);
    at(bottom, 5, roll: roll);
  }

  void standUp({double bottom = 85, double top = 175}) {
    at(bottom, 5);
    sweep(bottom, top, 20);
    at(top, 5);
  }
}

void main() {
  test('declares itself, and frames portrait', () {
    final evaluator = ChairSitToStandEvaluator();
    expect(evaluator.id, ExerciseId.chairSitToStand);
    expect(evaluator.displayName, 'Chair sit-to-stand');
    expect(evaluator.thresholdVersion, 1);
    expect(evaluator.setup.landscape, isFalse);
  });

  group('counting', () {
    test('a full sit-to-stand counts one', () {
      final evaluator = ChairSitToStandEvaluator();
      Driver(evaluator).rep();
      expect(evaluator.repCount, 1);
    });

    test('five reps count five, and the output carries the total', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator);
      for (var i = 0; i < 5; i++) {
        driver.rep();
      }
      expect(evaluator.repCount, 5);
      expect(driver.last.reps, 5);
    });

    test('the clock runs while they work', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..rep();
      expect(driver.last.verdict, FormVerdict.good);
      expect(driver.last.presence, Presence.present);
    });

    test('reset clears the count', () {
      final evaluator = ChairSitToStandEvaluator();
      Driver(evaluator).rep();
      evaluator.reset();
      expect(evaluator.repCount, 0);
      expect(evaluator.phase, SitToStandPhase.unknown);
    });
  });

  group('false positives are the failure mode that matters', () {
    test('shuffling in the chair counts zero', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator);
      for (var i = 0; i < 10; i++) {
        driver.at(95, 4);
        driver.at(118, 4);
      }
      expect(evaluator.repCount, 0);
    });

    test('rocking to build momentum counts zero', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator);
      for (var i = 0; i < 15; i++) {
        driver.sweep(88, 130, 3);
        driver.sweep(130, 88, 3);
      }
      expect(evaluator.repCount, 0);
    });

    test('a single spurious frame counts zero', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)
        ..at(85, 20)
        ..at(175, 1)
        ..at(85, 20);
      expect(evaluator.repCount, 0);
      expect(driver.last.verdict, FormVerdict.good);
    });

    test('two spurious frames still count zero', () {
      final evaluator = ChairSitToStandEvaluator();
      Driver(evaluator)
        ..at(85, 20)
        ..at(175, 2)
        ..at(85, 20);
      expect(evaluator.repCount, 0);
    });

    test('a transition too fast to be a human is thrown away', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)
        ..at(85, 5)
        ..at(175, 6);
      expect(evaluator.repCount, 0);
      expect(driver.last.faults, contains(FaultCode.shallowDepth));
    });
  });

  group('bad reps void and cue, they never fail', () {
    test('standing only halfway counts zero and says so', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)
        ..at(85, 5)
        ..sweep(85, 140, 15)
        ..at(140, 4)
        ..sweep(140, 85, 15)
        ..at(85, 5);
      expect(evaluator.repCount, 0);
      expect(driver.last.faults, contains(FaultCode.noLockout));
      // Cued, but the clock never stopped.
      expect(driver.last.verdict, FormVerdict.good);
    });

    test('bobbing at the top adds nothing and says so', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..standUp();
      expect(evaluator.repCount, 1);

      driver
        ..sweep(175, 140, 8)
        ..at(140, 4)
        ..sweep(140, 175, 8)
        ..at(175, 4);
      expect(evaluator.repCount, 1);
      expect(driver.last.faults, contains(FaultCode.shallowDepth));
      expect(driver.last.verdict, FormVerdict.good);
    });

    test('the next real rep still has to reach the seat', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..standUp();
      driver
        ..sweep(175, 140, 8)
        ..at(140, 4)
        ..sweep(140, 175, 8)
        ..at(175, 4)
        ..sweep(175, 85, 20)
        ..at(85, 5)
        ..sweep(85, 175, 20)
        ..at(175, 5);
      expect(evaluator.repCount, 2);
    });

    test('the cue clears once it has been shown', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)
        ..at(85, 5)
        ..at(175, 6);
      expect(driver.last.faults, isNotEmpty);
      driver.at(175, 40);
      expect(driver.last.faults, isEmpty);
    });
  });

  group('the stall watchdog', () {
    test('sitting still eventually reads as no longer attempting', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..at(85, 8);
      expect(driver.last.verdict, FormVerdict.good);

      driver.at(85, 400);
      expect(driver.last.verdict, FormVerdict.outOfPosition);
      expect(driver.last.presence, Presence.partial);
    });

    test('moving again clears it', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..at(85, 400);
      expect(driver.last.verdict, FormVerdict.outOfPosition);

      driver
        ..sweep(85, 175, 20)
        ..at(175, 6);
      expect(driver.last.verdict, FormVerdict.good);
      expect(evaluator.repCount, 1);
    });

    test('a dropout is not a stall', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..at(85, 8);
      // Five minutes of frames we cannot read. Our fault, so the stall clock
      // does not run and nothing is held against them.
      driver.at(85, 4000, omit: {Joint.leftKnee});
      expect(driver.last.verdict, FormVerdict.indeterminate);
      driver.at(85, 4);
      expect(driver.last.verdict, FormVerdict.good);
    });
  });

  group('degenerate input', () {
    test('a missing knee is indeterminate and keeps the reps earned', () {
      final evaluator = ChairSitToStandEvaluator();
      final driver = Driver(evaluator)..rep();
      expect(evaluator.repCount, 1);

      driver.at(85, 5, omit: {Joint.leftKnee});
      expect(driver.last.verdict, FormVerdict.indeterminate);
      expect(driver.last.faults, {FaultCode.outOfFrame});
      expect(driver.last.reps, 1);
    });

    test('nobody in frame is unusable', () {
      final output = ChairSitToStandEvaluator().evaluate(
        sitToStandFrame(
          kneeAngleDegrees: 90,
          monotonic: Duration.zero,
          detectionConfidence: 0.05,
        ),
      );
      expect(output.presence, Presence.absent);
      expect(output.verdict, FormVerdict.indeterminate);
    });

    test('garbage never throws and never counts a rep', () {
      final random = math.Random(1234);
      final evaluator = ChairSitToStandEvaluator();
      for (var i = 0; i < 4000; i++) {
        final output = evaluator.evaluate(garbageFrame(random));
        expect(output.confidence, inInclusiveRange(0.0, 1.0));
      }
      // Random noise has no ordered descent-then-ascent in it, so nothing may
      // be credited.
      expect(evaluator.repCount, 0);
    });
  });

  group('per-user calibration', () {
    test('a high chair is accommodated', () {
      final baseline = [
        for (var i = 0; i < 12; i++)
          sitToStandFrame(
            kneeAngleDegrees: 108,
            monotonic: Duration(milliseconds: 66 * i),
          ),
      ];

      final uncalibrated = ChairSitToStandEvaluator();
      Driver(uncalibrated).rep(bottom: 108);
      expect(uncalibrated.repCount, 0,
          reason: 'a 108° seat never reaches the default threshold');

      final calibrated = ChairSitToStandEvaluator()..calibrate(baseline);
      expect(calibrated.seatedThreshold, greaterThan(105));
      Driver(calibrated).rep(bottom: 108);
      expect(calibrated.repCount, 1);
    });

    test('the seated threshold is clamped', () {
      final evaluator = ChairSitToStandEvaluator()
        ..calibrate([
          for (var i = 0; i < 12; i++)
            sitToStandFrame(
              kneeAngleDegrees: 140,
              monotonic: Duration(milliseconds: 66 * i),
            ),
        ]);
      expect(evaluator.seatedThreshold, lessThanOrEqualTo(112));
      // A near-standing "seat" cannot turn a shallow bob into a rep.
      Driver(evaluator)
        ..at(135, 6)
        ..sweep(135, 175, 12)
        ..at(175, 6);
      expect(evaluator.repCount, 0);
    });

    test('reset restores the default threshold', () {
      final evaluator = ChairSitToStandEvaluator()
        ..calibrate([
          for (var i = 0; i < 12; i++)
            sitToStandFrame(
              kneeAngleDegrees: 108,
              monotonic: Duration(milliseconds: 66 * i),
            ),
        ])
        ..reset();
      expect(evaluator.seatedThreshold,
          ChairSitToStandEvaluator.defaultSeatedAt);
    });
  });

  test('rolling the phone changes nothing', () {
    for (final roll in [0.0, 37.0, 90.0, -120.0]) {
      final evaluator = ChairSitToStandEvaluator();
      Driver(evaluator).rep(roll: roll);
      expect(evaluator.repCount, 1, reason: 'roll $roll°');
    }
  });

  test('backwards timestamps cannot manufacture or lose a rep', () {
    final evaluator = ChairSitToStandEvaluator();
    var now = const Duration(seconds: 10);
    void feed(double knee) {
      evaluator.evaluate(
          sitToStandFrame(kneeAngleDegrees: knee, monotonic: now));
      now -= const Duration(milliseconds: 66);
    }

    for (var i = 0; i < 5; i++) {
      feed(85);
    }
    for (var i = 0; i < 25; i++) {
      feed(175);
    }
    // Time ran backwards throughout, so no interval was long enough to be a
    // real stand. Refusing to credit is the conservative answer.
    expect(evaluator.repCount, 0);
  });
}
