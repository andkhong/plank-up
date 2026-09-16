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
    final evaluator = SeatedArmHoldEvaluator();
    expect(evaluator.id, ExerciseId.seatedArmHold);
    expect(evaluator.displayName, 'Seated arm hold');
    expect(evaluator.thresholdVersion, 1);
    expect(evaluator.setup.landscape, isFalse);
  });

  group('the wheelchair case', () {
    test('the setup asks for nothing below the shoulders', () {
      final required = SeatedArmHoldEvaluator().setup.requiredJoints;
      for (final joint in [
        Joint.leftHip,
        Joint.rightHip,
        Joint.leftKnee,
        Joint.rightKnee,
        Joint.leftAnkle,
        Joint.rightAnkle,
      ]) {
        expect(required, isNot(contains(joint)),
            reason: '$joint would exclude wheelchair users');
      }
      expect(required, contains(Joint.leftWrist));
    });

    test('a frame with no lower body at all is judged normally', () {
      final frame = seatedArmFrame();
      for (final joint in [
        Joint.leftHip,
        Joint.rightHip,
        Joint.leftKnee,
        Joint.rightKnee,
        Joint.leftAnkle,
        Joint.rightAnkle,
      ]) {
        expect(frame.landmarks.containsKey(joint), isFalse);
      }

      final output = hold(SeatedArmHoldEvaluator(), frame);
      expect(output.verdict, FormVerdict.good);
      expect(output.presence, Presence.present);
      expect(output.faults, isEmpty);
    });

    test('a dropped arm is still caught with no lower body visible', () {
      final output = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elevationDegrees: -32),
      );
      expect(output.verdict, FormVerdict.broken);
      expect(output.faults, {FaultCode.armsDropped});
    });

    test('a visible lower body changes nothing about the verdict', () {
      final without = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elevationDegrees: -20),
      );
      final with_ = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elevationDegrees: -20, includeLowerBody: true),
      );
      expect(with_.verdict, without.verdict);
      expect(with_.faults, without.faults);
      expect(with_.primaryMetric, closeTo(without.primaryMetric!, 0.01));
    });
  });

  group('arm elevation', () {
    test('level arms pass', () {
      final output = SeatedArmHoldEvaluator().evaluate(seatedArmFrame());
      expect(output.verdict, FormVerdict.good);
      expect(output.primaryMetric, closeTo(0, 0.2));
    });

    test('the metric is signed, negative when the arms drop', () {
      for (final elevation in [-30.0, -18.0, 0.0, 18.0, 30.0]) {
        final output = SeatedArmHoldEvaluator()
            .evaluate(seatedArmFrame(elevationDegrees: elevation));
        expect(output.primaryMetric, closeTo(elevation, 0.2),
            reason: 'at $elevation°');
      }
    });

    test('a drop past 15 degrees cues, past 25 stops the clock', () {
      final evaluator = SeatedArmHoldEvaluator();
      final cueing = hold(evaluator, seatedArmFrame(elevationDegrees: -20));
      expect(evaluator.level, FormLevel.degraded);
      expect(cueing.verdict, FormVerdict.good);
      expect(cueing.faults, {FaultCode.armsDropped});

      final broken = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elevationDegrees: -32),
      );
      expect(broken.verdict, FormVerdict.broken);
    });

    test('holding the arms higher is harder, so the band is generous', () {
      for (final elevation in [8.0, 16.0, 24.0]) {
        final output = hold(
          SeatedArmHoldEvaluator(),
          seatedArmFrame(elevationDegrees: elevation),
        );
        expect(output.verdict, FormVerdict.good, reason: 'at +$elevation°');
        expect(output.faults, isEmpty, reason: 'at +$elevation°');
      }
      // The same number downward is already a cue.
      expect(
        hold(SeatedArmHoldEvaluator(), seatedArmFrame(elevationDegrees: -24))
            .faults,
        isNotEmpty,
      );
    });

    test('arms by the side is out of position, not broken form', () {
      final output = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elevationDegrees: -75),
      );
      expect(output.verdict, FormVerdict.outOfPosition);
    });
  });

  group('elbow lockout', () {
    test('a straight arm is clean', () {
      expect(
        hold(SeatedArmHoldEvaluator(), seatedArmFrame(elbowBendDegrees: 8))
            .faults,
        isEmpty,
      );
    });

    test('bending the elbow to rest is caught and named', () {
      final cue = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elbowBendDegrees: 28),
      );
      expect(cue.faults, {FaultCode.noLockout});
      expect(cue.verdict, FormVerdict.good);

      final broken = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elbowBendDegrees: 45),
      );
      expect(broken.verdict, FormVerdict.broken);
      expect(broken.faults, {FaultCode.noLockout});
    });

    test('an arm pointing at the camera is indeterminate, not broken', () {
      // Nothing can be measured from a limb foreshortened to nothing. That is
      // a framing problem, and framing problems are ours.
      final output = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(elbowBendDegrees: 170),
      );
      expect(output.verdict, FormVerdict.indeterminate);
      expect(output.faults, {FaultCode.notSideOn});
      expect(output.presence, Presence.present);
    });
  });

  group('two arms', () {
    test('a confidently visible far arm that dropped is judged', () {
      final output = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(
          farArmElevationDegrees: -35,
          farArmConfidence: 0.85,
        ),
      );
      expect(output.verdict, FormVerdict.broken);
      expect(output.faults, {FaultCode.armsDropped});
    });

    test('a barely visible far arm is never allowed to fail anyone', () {
      // In a side-on view the far arm is occluded and the model infers it from
      // a learned prior. A hallucinated limb must not cost someone their hold.
      final output = hold(
        SeatedArmHoldEvaluator(),
        seatedArmFrame(
          farArmElevationDegrees: -70,
          farArmConfidence: 0.35,
        ),
      );
      expect(output.verdict, FormVerdict.good);
      expect(output.faults, isEmpty);
    });
  });

  test('hysteresis suppresses a single bad frame', () {
    final evaluator = SeatedArmHoldEvaluator();
    for (var i = 0; i < 5; i++) {
      evaluator.evaluate(seatedArmFrame());
    }
    final blip =
        evaluator.evaluate(seatedArmFrame(elevationDegrees: -40));
    expect(blip.verdict, FormVerdict.good);
    expect(blip.faults, isEmpty);
  });

  test('recovery needs three consecutive frames under the tighter band', () {
    final evaluator = SeatedArmHoldEvaluator();
    hold(evaluator, seatedArmFrame(elevationDegrees: -20));
    expect(evaluator.level, FormLevel.degraded);

    for (var i = 0; i < 10; i++) {
      evaluator.evaluate(seatedArmFrame(elevationDegrees: -13));
    }
    expect(evaluator.level, FormLevel.degraded);

    for (var i = 0; i < 3; i++) {
      evaluator.evaluate(seatedArmFrame(elevationDegrees: -6));
    }
    expect(evaluator.level, FormLevel.good);
  });

  test('rolling the phone changes nothing', () {
    final reference = SeatedArmHoldEvaluator()
        .evaluate(seatedArmFrame(elevationDegrees: -20));
    for (final roll in [23.0, 90.0, 176.0, -48.0]) {
      final output = SeatedArmHoldEvaluator()
          .evaluate(seatedArmFrame(elevationDegrees: -20, rollDegrees: roll));
      expect(output.primaryMetric, closeTo(reference.primaryMetric!, 1e-6),
          reason: 'roll $roll°');
      expect(output.verdict, reference.verdict, reason: 'roll $roll°');
    }
  });

  test('obliquity is corrected when the trunk is available', () {
    for (final phi in [0.0, 15.0, 30.0]) {
      final output = SeatedArmHoldEvaluator().evaluate(
        seatedArmFrame(
          elevationDegrees: -20,
          includeLowerBody: true,
          obliquityDegrees: phi,
        ),
      );
      expect(output.primaryMetric, closeTo(-20, 1.5), reason: 'φ=$phi');
    }
  });

  test('a missing wrist is indeterminate, not broken', () {
    final output = hold(
      SeatedArmHoldEvaluator(),
      seatedArmFrame(elevationDegrees: -50, omit: {Joint.leftWrist}),
    );
    expect(output.verdict, FormVerdict.indeterminate);
    expect(output.faults, {FaultCode.outOfFrame});
  });

  test('nobody in frame is unusable', () {
    expect(
      SeatedArmHoldEvaluator()
          .evaluate(seatedArmFrame(detectionConfidence: 0.05))
          .presence,
      Presence.absent,
    );
  });

  test('calibration is clamped', () {
    final evaluator = SeatedArmHoldEvaluator()
      ..calibrate([
        for (var i = 0; i < 12; i++) seatedArmFrame(elevationDegrees: -20),
      ]);
    expect(evaluator.baselineDegrees, closeTo(-6, 1e-6));
    // Framing up with sagging arms does not buy a sagging hold.
    expect(
      hold(evaluator, seatedArmFrame(elevationDegrees: -32)).verdict,
      FormVerdict.broken,
    );
  });

  test('garbage never throws', () {
    final random = math.Random(2718);
    final evaluator = SeatedArmHoldEvaluator();
    for (var i = 0; i < 3000; i++) {
      final output = evaluator.evaluate(garbageFrame(random));
      expect(output.confidence, inInclusiveRange(0.0, 1.0));
      if (output.presence == Presence.absent) {
        expect(output.verdict, FormVerdict.indeterminate);
      }
    }
  });
}
