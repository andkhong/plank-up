// The evaluators wired to the machine that consumes them.
//
// The unit tests elsewhere check what each evaluator *says*; these check what
// the session actually *does* with it, which is where a mistaken verdict
// mapping would cost a real user real time.
import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/evaluators.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'evaluator_fixtures.dart';

class Rig {
  Rig({
    this.target = const Duration(seconds: 60),
    this.step = const Duration(milliseconds: 66),
  })  : evaluator = PlankEvaluator(),
        machine = SessionMachine(target: target);

  final Duration target;
  final Duration step;
  final PlankEvaluator evaluator;
  final SessionMachine machine;

  Duration now = Duration.zero;
  EvalOutput last = EvalOutput.unusable;

  void run(Duration span, PoseFrame Function(Duration) build) {
    final end = now + span;
    while (now < end) {
      now += step;
      last = evaluator.evaluate(build(now));
      machine.onFrame(SessionFrame(monotonic: now, verdict: last.verdict));
    }
  }

  void good(Duration span) =>
      run(span, (t) => plankFrame(monotonic: t));

  void deviated(Duration span, double degrees) =>
      run(span, (t) => plankFrame(deviationDegrees: degrees, monotonic: t));

  void blind(Duration span) =>
      run(span, (t) => plankFrame(monotonic: t, detectionConfidence: 0.05));

  void startHolding() {
    machine.beginCountdown();
    run(machine.config.countdown + step, (t) => plankFrame(monotonic: t));
  }
}

void main() {
  test('a clean plank earns the time it is held for', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 20));
    expect(rig.machine.state, SessionState.holding);
    expect(rig.machine.creditedHold.inMilliseconds, closeTo(20000, 200));
  });

  test('the degraded band coaches while the clock keeps running', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 10))
      ..deviated(const Duration(seconds: 10), -17);

    expect(rig.last.faults, {FaultCode.hipSag});
    expect(rig.machine.state, SessionState.holding);
    expect(rig.machine.creditedHold.inMilliseconds, closeTo(20000, 400));
  });

  test('the broken band pauses the clock and costs nothing', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 10));
    final atBreak = rig.machine.creditedHold;

    rig.deviated(const Duration(seconds: 2), -30);
    expect(rig.machine.state, SessionState.paused);
    // Four frames of debouncing before the pause takes effect — about 260 ms,
    // credited to the user rather than to us.
    expect(rig.machine.creditedHold.inMilliseconds,
        closeTo(atBreak.inMilliseconds + 264, 150));
    expect(rig.machine.isTerminal, isFalse);
  });

  test('a brief dip under three seconds does not end the attempt', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 20))
      ..deviated(const Duration(milliseconds: 2000), -30)
      ..good(const Duration(seconds: 10));

    expect(rig.machine.isTerminal, isFalse);
    expect(rig.machine.state, SessionState.holding);
    expect(rig.machine.creditedHold.inMilliseconds, greaterThan(29000));
  });

  test('losing the skeleton is our fault and gets the longer grace', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 20))
      ..blind(const Duration(seconds: 8));

    // Eight seconds of bad form would have settled the attempt twice over.
    expect(rig.machine.state, SessionState.lost);
    expect(rig.machine.isTerminal, isFalse);

    rig.good(const Duration(seconds: 5));
    expect(rig.machine.state, SessionState.holding);
    expect(rig.machine.creditedHold.inMilliseconds, closeTo(25000, 400));
  });

  test('a badly angled camera never burns form grace', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 20))
      ..run(
        const Duration(seconds: 8),
        (t) => plankFrame(
            deviationDegrees: -40, obliquityDegrees: 55, monotonic: t),
      );

    // Sagging *and* unmeasurable. The unmeasurable part wins, because we
    // cannot honestly say the first thing.
    expect(rig.last.verdict, FormVerdict.indeterminate);
    expect(rig.machine.state, SessionState.lost);
    expect(rig.machine.isTerminal, isFalse);
  });

  test('standing up ends the attempt with the credit already earned', () {
    final rig = Rig()
      ..startHolding()
      ..good(const Duration(seconds: 30))
      ..run(
        const Duration(seconds: 5),
        (t) => plankFrame(inclinationDegrees: 80, monotonic: t),
      );

    expect(rig.machine.state, SessionState.ended);
    expect(rig.machine.outcome, SessionOutcome.ended);
    expect(rig.machine.creditedHold.inMilliseconds, greaterThan(29000));
  });

  test('a calibrated hold credits the same body more fairly', () {
    final baseline = [
      for (var i = 0; i < 15; i++) plankFrame(deviationDegrees: -5),
    ];

    final uncalibrated = Rig()..startHolding();
    uncalibrated.deviated(const Duration(seconds: 20), -16);
    expect(uncalibrated.last.faults, isNotEmpty);

    final calibrated = Rig();
    calibrated.evaluator.calibrate(baseline);
    calibrated
      ..startHolding()
      ..deviated(const Duration(seconds: 20), -16);
    expect(calibrated.last.faults, isEmpty);
    expect(calibrated.machine.creditedHold.inMilliseconds,
        closeTo(20000, 400));
  });
}
