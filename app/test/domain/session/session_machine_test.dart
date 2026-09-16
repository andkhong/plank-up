import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/session/session_machine.dart';

/// Feeds frames at a fixed cadence so tests read as elapsed time rather than
/// as frame counts.
class Feeder {
  Feeder(this.machine, {this.step = const Duration(milliseconds: 100)});

  final SessionMachine machine;
  final Duration step;
  Duration _now = Duration.zero;

  Duration get now => _now;

  void run(Duration span, FormVerdict verdict) {
    final end = _now + span;
    while (_now < end) {
      _now += step;
      machine.onFrame(SessionFrame(monotonic: _now, verdict: verdict));
    }
  }

  /// Simulates frames stopping entirely, then resuming.
  void gap(Duration span, FormVerdict verdict) {
    _now += span;
    machine.onFrame(SessionFrame(monotonic: _now, verdict: verdict));
  }

  void startHolding() {
    machine.beginCountdown();
    run(machine.config.countdown + step, FormVerdict.good);
  }
}

SessionMachine machineFor(Duration target) => SessionMachine(target: target);

void main() {
  const target = Duration(seconds: 60);

  group('countdown', () {
    test('starts in framing and does not accumulate', () {
      final m = machineFor(target);
      final f = Feeder(m);
      f.run(const Duration(seconds: 5), FormVerdict.good);
      expect(m.state, SessionState.framing);
      expect(m.creditedHold, Duration.zero);
    });

    test('countdown elapses into holding', () {
      final m = machineFor(target);
      final f = Feeder(m);
      m.beginCountdown();
      expect(m.state, SessionState.countdown);
      f.run(const Duration(seconds: 2), FormVerdict.good);
      expect(m.state, SessionState.countdown);
      f.run(const Duration(seconds: 2), FormVerdict.good);
      expect(m.state, SessionState.holding);
    });

    test('no credit accrues during the countdown', () {
      final m = machineFor(target);
      final f = Feeder(m);
      m.beginCountdown();
      f.run(const Duration(seconds: 3), FormVerdict.good);
      expect(m.creditedHold, Duration.zero);
    });

    test('beginCountdown is ignored once past framing', () {
      final m = machineFor(target);
      final f = Feeder(m)..startHolding();
      m.beginCountdown();
      expect(m.state, SessionState.holding);
      f.run(const Duration(seconds: 1), FormVerdict.good);
      expect(m.creditedHold, greaterThan(Duration.zero));
    });
  });

  group('accumulation', () {
    test('good form accrues credit', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 10), FormVerdict.good);
      expect(m.creditedHold.inMilliseconds, closeTo(10000, 200));
    });

    test('reaching the target completes and clamps', () {
      final m = machineFor(const Duration(seconds: 5));
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 8), FormVerdict.good);
      expect(m.state, SessionState.completed);
      expect(m.creditedHold, const Duration(seconds: 5));
      expect(m.outcome, SessionOutcome.completed);
      expect(m.remaining, Duration.zero);
      expect(m.progress, 1.0);
    });
  });

  group('form break pauses but never fails', () {
    test('broken form moves to paused and stops the clock', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 10), FormVerdict.good);
      final atBreak = m.creditedHold;

      f.run(const Duration(seconds: 2), FormVerdict.broken);
      expect(m.state, SessionState.paused);
      expect(m.creditedHold, atBreak);
    });

    test('recovering resumes accumulation and resets grace', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 10), FormVerdict.good)
        ..run(const Duration(seconds: 2), FormVerdict.broken);
      expect(m.graceElapsed, greaterThan(Duration.zero));

      f.run(const Duration(seconds: 1), FormVerdict.good);
      expect(m.state, SessionState.holding);
      expect(m.graceElapsed, Duration.zero);
      expect(m.creditedHold.inMilliseconds, closeTo(11000, 300));
    });

    test('repeated brief breaks never end the attempt', () {
      final m = machineFor(const Duration(seconds: 30));
      final f = Feeder(m, step: const Duration(milliseconds: 100))
        ..startHolding();
      const cycles = 20;
      for (var i = 0; i < cycles; i++) {
        f.run(const Duration(seconds: 1), FormVerdict.good);
        f.run(const Duration(seconds: 2), FormVerdict.broken);
      }
      expect(m.isTerminal, isFalse);

      // Each good->bad and bad->good transition spends one frame on the switch
      // without crediting it, so accumulation lags true good-form time by at
      // most two frame periods per cycle. It under-credits, never over-credits.
      const goodFormTime = cycles * 1000;
      const maxLag = cycles * 2 * 100;
      expect(m.creditedHold.inMilliseconds, lessThanOrEqualTo(goodFormTime));
      expect(m.creditedHold.inMilliseconds,
          greaterThanOrEqualTo(goodFormTime - maxLag));
    });

    test('accumulation is conservative: never more than real good-form time',
        () {
      final m = machineFor(const Duration(minutes: 10));
      final f = Feeder(m)..startHolding();
      var goodFormMs = 0;

      for (var i = 0; i < 30; i++) {
        f.run(const Duration(milliseconds: 700), FormVerdict.good);
        goodFormMs += 700;
        f.run(const Duration(milliseconds: 300), FormVerdict.broken);
      }

      expect(m.creditedHold.inMilliseconds, lessThanOrEqualTo(goodFormMs));
    });

    test('sustained bad form settles with partial credit, not failure', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(seconds: 4), FormVerdict.broken);

      expect(m.state, SessionState.ended);
      expect(m.outcome, SessionOutcome.ended);
      expect(m.creditedHold.inMilliseconds, closeTo(20000, 300));
    });

    test('leaving position behaves the same as broken form', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(seconds: 4), FormVerdict.outOfPosition);
      expect(m.state, SessionState.ended);
    });
  });

  group('tracking loss is our fault', () {
    test('indeterminate frames go to lost, not paused', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 5), FormVerdict.good)
        ..run(const Duration(seconds: 1), FormVerdict.indeterminate);
      expect(m.state, SessionState.lost);
    });

    test('lost gets a far longer budget than a form break', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(seconds: 5), FormVerdict.indeterminate);

      // Five seconds of bad form would already have settled the attempt.
      expect(m.isTerminal, isFalse);
      expect(m.state, SessionState.lost);

      f.run(const Duration(seconds: 6), FormVerdict.indeterminate);
      expect(m.state, SessionState.ended);
    });

    test('recovering from lost resumes where it stopped', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(seconds: 8), FormVerdict.indeterminate)
        ..run(const Duration(seconds: 5), FormVerdict.good);
      expect(m.state, SessionState.holding);
      expect(m.creditedHold.inMilliseconds, closeTo(25000, 400));
    });

    test('switching between lost and paused does not refund spent grace', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(milliseconds: 2500), FormVerdict.broken);
      expect(m.isTerminal, isFalse);

      f.run(const Duration(milliseconds: 800), FormVerdict.indeterminate);
      expect(m.state, SessionState.lost);
      expect(m.graceElapsed.inMilliseconds, greaterThan(3000));
    });
  });

  group('frame gaps', () {
    test('a long gap credits nobody', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 10), FormVerdict.good);
      final before = m.creditedHold;

      f.gap(const Duration(seconds: 30), FormVerdict.good);
      expect(m.creditedHold, before);
      expect(m.state, SessionState.holding);
    });

    test('a gap does not burn grace either', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 20), FormVerdict.good)
        ..run(const Duration(milliseconds: 500), FormVerdict.broken);
      final grace = m.graceElapsed;

      f.gap(const Duration(seconds: 30), FormVerdict.broken);
      expect(m.graceElapsed, grace);
      expect(m.isTerminal, isFalse);
    });

    test('a backwards timestamp is ignored rather than crediting negative', () {
      final m = machineFor(target);
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 10), FormVerdict.good);
      final before = m.creditedHold;

      m.onFrame(SessionFrame(
        monotonic: f.now - const Duration(seconds: 5),
        verdict: FormVerdict.good,
      ));
      expect(m.creditedHold, before);
    });
  });

  group('abandoning', () {
    test('stopping early enough reads as cancelled', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 2), FormVerdict.good);
      m.abandon();
      expect(m.state, SessionState.cancelled);
      expect(m.outcome, SessionOutcome.cancelled);
    });

    test('stopping after real effort keeps the credit', () {
      final m = machineFor(target);
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 40), FormVerdict.good);
      m.abandon();
      expect(m.state, SessionState.ended);
      expect(m.creditedHold.inMilliseconds, closeTo(40000, 300));
    });

    test('giving up and timing out earn identical credit', () {
      final gaveUp = machineFor(target);
      Feeder(gaveUp)
        ..startHolding()
        ..run(const Duration(seconds: 30), FormVerdict.good);
      gaveUp.abandon();

      final timedOut = machineFor(target);
      Feeder(timedOut)
        ..startHolding()
        ..run(const Duration(seconds: 30), FormVerdict.good)
        ..run(const Duration(seconds: 4), FormVerdict.broken);

      expect(gaveUp.outcome, timedOut.outcome);
      expect((gaveUp.creditedHold - timedOut.creditedHold).inMilliseconds.abs(),
          lessThan(400));
    });
  });

  group('terminal states absorb', () {
    test('frames after completion change nothing', () {
      final m = machineFor(const Duration(seconds: 5));
      final f = Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 6), FormVerdict.good);
      expect(m.state, SessionState.completed);

      f.run(const Duration(seconds: 10), FormVerdict.broken);
      expect(m.state, SessionState.completed);
      expect(m.creditedHold, const Duration(seconds: 5));
    });

    test('abandon after terminal is a no-op', () {
      final m = machineFor(const Duration(seconds: 5));
      Feeder(m)
        ..startHolding()
        ..run(const Duration(seconds: 6), FormVerdict.good);
      m.abandon();
      expect(m.state, SessionState.completed);
    });
  });

  group('properties', () {
    test('credited hold never decreases and never exceeds the target',
        () {
      final random = Random(20260916);
      const verdicts = FormVerdict.values;

      for (var run = 0; run < 200; run++) {
        final m = machineFor(const Duration(seconds: 30));
        final f = Feeder(m)..startHolding();
        var previous = Duration.zero;

        for (var i = 0; i < 120 && !m.isTerminal; i++) {
          f.run(
            Duration(milliseconds: 100 + random.nextInt(900)),
            verdicts[random.nextInt(verdicts.length)],
          );
          expect(m.creditedHold, greaterThanOrEqualTo(previous));
          expect(m.creditedHold, lessThanOrEqualTo(const Duration(seconds: 30)));
          previous = m.creditedHold;
        }
      }
    });

    test('completion is only ever reached at the full target', () {
      final random = Random(7);
      const verdicts = FormVerdict.values;

      for (var run = 0; run < 200; run++) {
        final m = machineFor(const Duration(seconds: 20));
        final f = Feeder(m)..startHolding();

        for (var i = 0; i < 200 && !m.isTerminal; i++) {
          f.run(
            Duration(milliseconds: 100 + random.nextInt(600)),
            verdicts[random.nextInt(verdicts.length)],
          );
        }

        if (m.outcome == SessionOutcome.completed) {
          expect(m.creditedHold, const Duration(seconds: 20));
        }
      }
    });

    test('progress stays within bounds under random input', () {
      final random = Random(99);
      const verdicts = FormVerdict.values;
      final m = machineFor(const Duration(seconds: 30));
      final f = Feeder(m)..startHolding();

      for (var i = 0; i < 400 && !m.isTerminal; i++) {
        f.run(
          Duration(milliseconds: 50 + random.nextInt(500)),
          verdicts[random.nextInt(verdicts.length)],
        );
        expect(m.progress, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
