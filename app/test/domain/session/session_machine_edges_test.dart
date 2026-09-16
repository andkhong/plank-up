/// Boundaries, unreached branches and the states the existing suite starts
/// from rather than tests.
///
/// `session_machine_test.dart` covers the happy paths and the headline rules
/// well. What it does not do is stand on the edges: the exact instant a grace
/// budget runs out, the exact frame gap that stops being credited, the exact
/// credited hold that separates "never mind" from "a real attempt". Those are
/// where a state machine is wrong, and every one of them is a product decision
/// somebody will want to move later.
///
/// It also never leaves the default [SessionConfig], so nothing pins that the
/// constants are actually read rather than baked in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/session/session_machine.dart';

/// Exact frame-by-frame control. Unlike the existing `Feeder`, this never
/// interpolates: you say when a frame arrives and what it says, so a boundary
/// lands on the instant you meant.
class Driver {
  Driver(this.machine);

  final SessionMachine machine;
  Duration now = Duration.zero;

  void frameAt(Duration t, FormVerdict verdict) {
    now = t;
    machine.onFrame(SessionFrame(monotonic: t, verdict: verdict));
  }

  /// Advances by [step] and delivers one frame.
  void step(Duration step, FormVerdict verdict) =>
      frameAt(now + step, verdict);

  void steps(int count, Duration each, FormVerdict verdict) {
    for (var i = 0; i < count; i++) {
      step(each, verdict);
    }
  }
}

/// Countdown removed so tests start accumulating on the second frame and
/// timestamps stay readable.
SessionMachine holding(
  Duration target, {
  SessionConfig config = const SessionConfig(countdown: Duration.zero),
}) {
  final machine = SessionMachine(target: target, config: config);
  machine.beginCountdown();
  machine.onFrame(
      const SessionFrame(monotonic: Duration.zero, verdict: FormVerdict.good));
  return machine;
}

void main() {
  const minute = Duration(minutes: 1);
  const step = Duration(milliseconds: 100);

  group('before the timer starts', () {
    test('abandoning from framing is a cancel, not an attempt', () {
      final machine = SessionMachine(target: minute);
      expect(machine.state, SessionState.framing);
      machine.abandon();
      expect(machine.state, SessionState.cancelled);
      expect(machine.outcome, SessionOutcome.cancelled);
      expect(machine.creditedHold, Duration.zero);
    });

    test('abandoning mid-countdown is a cancel', () {
      final machine = SessionMachine(target: minute)..beginCountdown();
      Driver(machine)
        ..frameAt(Duration.zero, FormVerdict.good)
        ..step(const Duration(seconds: 1), FormVerdict.good);
      expect(machine.state, SessionState.countdown);
      machine.abandon();
      expect(machine.state, SessionState.cancelled);
    });

    test('framing absorbs every verdict without changing anything', () {
      final machine = SessionMachine(target: minute);
      final driver = Driver(machine);
      for (final verdict in FormVerdict.values) {
        driver.step(const Duration(seconds: 1), verdict);
      }
      expect(machine.state, SessionState.framing);
      expect(machine.creditedHold, Duration.zero);
      expect(machine.graceElapsed, Duration.zero);
    });

    test('time spent framing is not handed to the countdown', () {
      // `onFrame` tracks the last timestamp even while framing, so the first
      // post-countdown delta is one frame period rather than the whole time the
      // user spent getting into position.
      final machine = SessionMachine(target: minute);
      final driver = Driver(machine)
        ..frameAt(Duration.zero, FormVerdict.good)
        ..steps(100, step, FormVerdict.good);
      expect(machine.state, SessionState.framing);

      machine.beginCountdown();
      driver.step(step, FormVerdict.good);
      expect(machine.state, SessionState.countdown,
          reason: 'ten seconds of framing must not satisfy a 3s countdown');
    });

    test('the very first frame of all credits nothing', () {
      final machine = SessionMachine(
          target: minute, config: const SessionConfig(countdown: Duration.zero))
        ..beginCountdown();
      Driver(machine).frameAt(const Duration(seconds: 42), FormVerdict.good);
      expect(machine.creditedHold, Duration.zero);
    });

    test('a gap during the countdown does not advance it', () {
      // The gap rule is "credited to nobody", and the countdown is somebody.
      final machine = SessionMachine(target: minute)..beginCountdown();
      Driver(machine)
        ..frameAt(Duration.zero, FormVerdict.good)
        ..frameAt(const Duration(seconds: 30), FormVerdict.good);
      expect(machine.state, SessionState.countdown);
    });

    test('beginCountdown is ignored from a terminal state', () {
      final machine = SessionMachine(target: minute)..abandon();
      expect(machine.state, SessionState.cancelled);
      machine.beginCountdown();
      expect(machine.state, SessionState.cancelled);
    });
  });

  group('the frame-gap boundary', () {
    test('a delta exactly at the limit is still credited', () {
      final machine = holding(minute);
      Driver(machine).frameAt(const Duration(milliseconds: 400), FormVerdict.good);
      expect(machine.creditedHold, const Duration(milliseconds: 400));
    });

    test('one microsecond past the limit is credited to nobody', () {
      final machine = holding(minute);
      Driver(machine)
          .frameAt(const Duration(milliseconds: 400, microseconds: 1),
              FormVerdict.good);
      expect(machine.creditedHold, Duration.zero);
      expect(machine.state, SessionState.holding);
    });

    test('the limit is read from the config, not baked in', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            maxSingleFrameGap: Duration(seconds: 2),
          ));
      Driver(machine).frameAt(const Duration(milliseconds: 1500), FormVerdict.good);
      expect(machine.creditedHold, const Duration(milliseconds: 1500));
    });

    test('two frames at the same instant credit nothing twice', () {
      final machine = holding(minute);
      final driver = Driver(machine)
        ..frameAt(const Duration(milliseconds: 200), FormVerdict.good);
      final before = machine.creditedHold;
      driver.frameAt(const Duration(milliseconds: 200), FormVerdict.good);
      expect(machine.creditedHold, before);
    });

    test('a gap neither accumulates hold nor burns grace, in one sequence', () {
      final machine = holding(minute);
      final driver = Driver(machine)
        ..steps(20, step, FormVerdict.good)
        ..step(step, FormVerdict.broken);
      final credited = machine.creditedHold;
      final grace = machine.graceElapsed;

      // Frames stop for a minute while the phone thinks about something else.
      driver.frameAt(driver.now + const Duration(seconds: 60), FormVerdict.broken);
      expect(machine.creditedHold, credited);
      expect(machine.graceElapsed, grace);
      expect(machine.isTerminal, isFalse,
          reason: 'a dropped pipeline is our fault and must not settle anything');
    });
  });

  group('the grace boundary', () {
    test('settling happens exactly at the budget, not before', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            graceAfterFormBreak: Duration(seconds: 1),
            cancelWindow: Duration.zero,
          ));
      final driver = Driver(machine)..steps(100, step, FormVerdict.good);

      driver.step(step, FormVerdict.broken); // enters paused, grace = 0
      driver.steps(9, step, FormVerdict.broken); // grace = 900ms
      expect(machine.graceElapsed, const Duration(milliseconds: 900));
      expect(machine.isTerminal, isFalse);

      driver.step(step, FormVerdict.broken); // grace = 1000ms
      expect(machine.state, SessionState.ended);
    });

    test('recovering one frame before the budget saves the attempt', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            graceAfterFormBreak: Duration(seconds: 1),
          ));
      final driver = Driver(machine)
        ..steps(100, step, FormVerdict.good)
        ..step(step, FormVerdict.broken)
        ..steps(9, step, FormVerdict.broken)
        ..step(step, FormVerdict.good);
      expect(machine.state, SessionState.holding);
      expect(machine.graceElapsed, Duration.zero);
      driver.steps(5, step, FormVerdict.good);
      expect(machine.creditedHold.inMilliseconds, 10500);
    });

    test('both grace budgets are read from the config', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            graceAfterFormBreak: Duration(milliseconds: 300),
            graceAfterTrackingLoss: Duration(seconds: 30),
          ));
      final driver = Driver(machine)..steps(100, step, FormVerdict.good);

      driver.steps(50, step, FormVerdict.indeterminate);
      expect(machine.state, SessionState.lost,
          reason: 'five seconds of tracking loss against a 30s budget');
      expect(machine.isTerminal, isFalse);
    });

    test('the loss budget is longer than the break budget by default', () {
      // Losing the skeleton is our fault; bad form is theirs. The gap between
      // these two numbers is that sentence made executable.
      const config = SessionConfig();
      expect(config.graceAfterTrackingLoss,
          greaterThan(config.graceAfterFormBreak));
    });

    test('tracking loss outlasts a form break at every duration', () {
      // Swept rather than sampled, because "our fault gets more room than their
      // fault" has to hold at every instant, not at the two someone picked.
      SessionMachine runFor(int badFrames, FormVerdict bad) {
        final machine = holding(minute);
        Driver(machine)
          ..steps(200, step, FormVerdict.good)
          ..steps(badFrames, step, bad);
        return machine;
      }

      var sawABreakSettle = false;
      for (var frames = 1; frames <= 90; frames++) {
        final broke = runFor(frames, FormVerdict.broken);
        final lost = runFor(frames, FormVerdict.indeterminate);

        if (broke.isTerminal) {
          sawABreakSettle = true;
          expect(lost.isTerminal, isFalse,
              reason: 'after ${frames * 100}ms a form break settled, but '
                  'losing the skeleton is our fault and must not have');
        }
        expect(lost.creditedHold, broke.creditedHold,
            reason: 'neither costs the user any credit');
      }
      expect(sawABreakSettle, isTrue,
          reason: 'the sweep has to actually reach the break budget');
    });
  });

  group('the cancel boundary', () {
    test('credit exactly at the cancel window counts as a real attempt', () {
      final machine = holding(minute);
      Driver(machine).steps(30, step, FormVerdict.good);
      expect(machine.creditedHold, const Duration(seconds: 3));
      machine.abandon();
      expect(machine.state, SessionState.ended,
          reason: 'the window is exclusive at the top');
    });

    test('one frame less is a cancel', () {
      final machine = holding(minute);
      Driver(machine).steps(29, step, FormVerdict.good);
      expect(machine.creditedHold, const Duration(milliseconds: 2900));
      machine.abandon();
      expect(machine.state, SessionState.cancelled);
    });

    test('the window is read from the config', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            cancelWindow: Duration(seconds: 30),
          ));
      Driver(machine).steps(100, step, FormVerdict.good);
      machine.abandon();
      expect(machine.state, SessionState.cancelled,
          reason: 'ten seconds against a thirty-second window');
    });

    test('a zero window means every attempt is a real attempt', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            cancelWindow: Duration.zero,
          ));
      machine.abandon();
      expect(machine.state, SessionState.ended);
      expect(machine.creditedHold, Duration.zero);
    });
  });

  group('re-targeting the grace budget', () {
    test('each cause keeps its own clock', () {
      final machine = holding(minute);
      final driver = Driver(machine)
        ..steps(200, step, FormVerdict.good)
        ..steps(25, step, FormVerdict.broken);
      expect(machine.graceElapsed, const Duration(milliseconds: 2400));

      driver.step(step, FormVerdict.indeterminate);
      expect(machine.state, SessionState.lost);
      expect(machine.graceElapsed, const Duration(milliseconds: 100),
          reason: 'the tracking-loss clock starts from zero, not from theirs');
      expect(machine.isTerminal, isFalse);

      // Their form-break clock is still where they left it, so a little more
      // bad form settles the attempt — the detour bought nothing.
      driver.steps(7, step, FormVerdict.broken);
      expect(machine.state, SessionState.ended);
    });

    test('a long tracking loss does not bankrupt the form-break budget', () {
      // This was a real defect, caught by the QA pass and fixed. The two
      // budgets used to share one accumulator, so nine seconds of "we cannot
      // see you" — our fault, well inside its own ten-second budget — was
      // charged against a three-second budget the instant the skeleton came
      // back looking imperfect, settling the attempt on that single frame.
      final machine = holding(minute);
      final driver = Driver(machine)
        ..steps(200, step, FormVerdict.good)
        ..steps(90, step, FormVerdict.indeterminate);
      expect(machine.state, SessionState.lost);
      expect(machine.graceElapsed, const Duration(milliseconds: 8900));
      expect(machine.isTerminal, isFalse);

      driver.step(step, FormVerdict.broken);
      expect(machine.state, SessionState.paused,
          reason: 'our perception failure must not spend their budget');
      expect(machine.graceElapsed, const Duration(milliseconds: 100));

      // They still only get three seconds of actual bad form.
      driver.steps(30, step, FormVerdict.broken);
      expect(machine.state, SessionState.ended);
      expect(machine.creditedHold, const Duration(seconds: 20),
          reason: 'whatever they held is still credited in full');
    });

    test('recovering to good form resets the budget whichever state it was in',
        () {
      for (final bad in [FormVerdict.broken, FormVerdict.indeterminate]) {
        final machine = holding(minute);
        Driver(machine)
          ..steps(100, step, FormVerdict.good)
          ..steps(20, step, bad)
          ..step(step, FormVerdict.good);
        expect(machine.graceElapsed, Duration.zero, reason: '$bad');
        expect(machine.state, SessionState.holding, reason: '$bad');
      }
    });

    test('outOfPosition and broken share one budget', () {
      final machine = holding(minute);
      final driver = Driver(machine)
        ..steps(200, step, FormVerdict.good)
        ..steps(16, step, FormVerdict.broken)
        ..steps(15, step, FormVerdict.outOfPosition);
      expect(machine.state, SessionState.ended,
          reason: '3s total across both, against a 3s budget');
      expect(driver.now, greaterThan(Duration.zero));
    });
  });

  group('degenerate targets', () {
    test('a zero target completes on the first credited frame', () {
      final machine = SessionMachine(
        target: Duration.zero,
        config: const SessionConfig(countdown: Duration.zero),
      )..beginCountdown();
      Driver(machine)
        ..frameAt(Duration.zero, FormVerdict.good)
        ..step(step, FormVerdict.good);
      expect(machine.state, SessionState.completed);
      expect(machine.creditedHold, Duration.zero);
    });

    test('progress on a zero target is 1, not a division by zero', () {
      final machine = SessionMachine(target: Duration.zero);
      expect(machine.progress, 1.0);
      expect(machine.remaining, Duration.zero);
    });

    test('remaining and progress stay consistent as credit accrues', () {
      final machine = holding(const Duration(seconds: 10));
      final driver = Driver(machine);
      for (var i = 0; i < 120 && !machine.isTerminal; i++) {
        driver.step(step, FormVerdict.good);
        expect(machine.remaining,
            const Duration(seconds: 10) - machine.creditedHold);
        expect(machine.progress,
            closeTo(machine.creditedHold.inMicroseconds / 10000000, 1e-12));
      }
      expect(machine.state, SessionState.completed);
      expect(machine.remaining, Duration.zero);
      expect(machine.progress, 1.0);
    });

    test('remaining never goes negative', () {
      final machine = holding(const Duration(seconds: 1));
      Driver(machine).steps(50, step, FormVerdict.good);
      expect(machine.remaining, Duration.zero);
      expect(machine.creditedHold, const Duration(seconds: 1));
    });
  });

  group('terminal states', () {
    test('every terminal state maps to exactly one outcome', () {
      const pairs = {
        SessionState.completed: SessionOutcome.completed,
        SessionState.ended: SessionOutcome.ended,
        SessionState.cancelled: SessionOutcome.cancelled,
      };
      expect(pairs.length, SessionOutcome.values.length);
    });

    test('non-terminal states have no outcome', () {
      final machine = SessionMachine(target: minute);
      expect(machine.outcome, isNull);
      machine.beginCountdown();
      expect(machine.outcome, isNull);
      Driver(machine)
        ..frameAt(Duration.zero, FormVerdict.good)
        ..steps(20, step, FormVerdict.good);
      expect(machine.state, SessionState.countdown);
      expect(machine.outcome, isNull);
    });

    test('a settled attempt ignores every later frame', () {
      final machine = holding(minute,
          config: const SessionConfig(
            countdown: Duration.zero,
            graceAfterFormBreak: Duration(milliseconds: 200),
          ));
      final driver = Driver(machine)
        ..steps(200, step, FormVerdict.good)
        ..steps(5, step, FormVerdict.broken);
      expect(machine.state, SessionState.ended);
      final credited = machine.creditedHold;

      driver.steps(100, step, FormVerdict.good);
      expect(machine.state, SessionState.ended);
      expect(machine.creditedHold, credited,
          reason: 'a settled attempt cannot be resurrected by good form');
    });

    test('abandon after settling is a no-op', () {
      final machine = holding(minute);
      Driver(machine).steps(200, step, FormVerdict.good);
      machine.abandon();
      expect(machine.state, SessionState.ended);
      final credited = machine.creditedHold;
      machine.abandon();
      expect(machine.creditedHold, credited);
    });
  });
}
