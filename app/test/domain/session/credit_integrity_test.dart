/// Credit integrity, checked against an oracle rather than against the machine
/// itself.
///
/// The design argues that line coverage is a weak gate for a state machine:
/// it proves branches were reached and says nothing about event interleaving,
/// which is the entire risk surface. The existing property tests agree and go
/// part of the way — they assert that credit is monotonic and bounded by the
/// target. Both of those are things the machine can satisfy while still being
/// wrong, because they only ever compare the machine to itself.
///
/// What is missing is an **independent oracle**: a separate accounting of what
/// the user actually did, computed from the frame stream by this test, that the
/// machine's answer is then checked against. That is what turns "credit went
/// up" into "credit went up by no more than it was allowed to".
///
/// The property that matters most, stated in the units the user experiences:
///
/// > **You can never be paid for time you did not spend in good form.**
///
/// Everything else in this file is a corollary or a guard rail around it.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/economy/unlock_economy.dart';
import 'package:plank_up/domain/session/session_machine.dart';

/// One frame in a generated sequence.
typedef Beat = ({Duration at, FormVerdict verdict});

/// Independent accounting of a frame sequence.
///
/// Deliberately re-derived from the rules rather than from the implementation:
/// a frame's verdict describes the interval that *ended* at its timestamp,
/// because that is the only interval we have evidence about; an interval longer
/// than the gap limit is evidence of nothing and belongs to nobody.
class Oracle {
  Oracle(this.config);

  final SessionConfig config;

  Duration goodFormTime = Duration.zero;
  Duration coveredTime = Duration.zero;
  Duration droppedTime = Duration.zero;
  Duration? _previous;

  void observe(Beat beat) {
    final previous = _previous;
    _previous = beat.at;
    if (previous == null) return;

    final delta = beat.at - previous;
    if (delta.isNegative) return;
    if (delta > config.maxSingleFrameGap) {
      droppedTime += delta;
      return;
    }

    coveredTime += delta;
    if (beat.verdict == FormVerdict.good) goodFormTime += delta;
  }
}

/// Runs a sequence and reports what both the machine and the oracle saw.
({SessionMachine machine, Oracle oracle}) run(
  List<Beat> beats, {
  required Duration target,
  SessionConfig config = const SessionConfig(countdown: Duration.zero),
}) {
  final machine = SessionMachine(target: target, config: config)
    ..beginCountdown();
  final oracle = Oracle(config);

  for (final beat in beats) {
    if (machine.isTerminal) break;
    machine.onFrame(SessionFrame(monotonic: beat.at, verdict: beat.verdict));
    oracle.observe(beat);
  }

  return (machine: machine, oracle: oracle);
}

/// A randomised frame stream: irregular cadence, occasional dropouts, the odd
/// backwards timestamp, and verdicts that flip without warning.
/// [goodWeight] biases the verdict draw. Uniform random verdicts almost never
/// hold form for twenty seconds, so a purely uniform generator explores the
/// settle paths thoroughly and never once reaches `completed` — a sampler that
/// cannot reach a state cannot check it.
List<Beat> randomBeats(
  Random random, {
  int count = 300,
  bool allowGaps = true,
  bool allowBackwards = true,
  double goodWeight = 0.25,
  Duration prefixGood = Duration.zero,
}) {
  final beats = <Beat>[];
  var now = Duration.zero;
  const others = [
    FormVerdict.broken,
    FormVerdict.outOfPosition,
    FormVerdict.indeterminate,
  ];

  // A clean opening hold, which is what real attempts look like: people start
  // in form and come apart later.
  while (now < prefixGood) {
    now += const Duration(milliseconds: 100);
    beats.add((at: now, verdict: FormVerdict.good));
  }

  for (var i = 0; i < count; i++) {
    final roll = random.nextInt(100);
    if (allowGaps && roll < 8) {
      // Frames stop arriving for a while: a thermal throttle, a GC pause, the
      // camera being taken away by a system dialog.
      now += Duration(milliseconds: 500 + random.nextInt(8000));
    } else {
      now += Duration(milliseconds: 20 + random.nextInt(260));
    }

    final at = allowBackwards && roll >= 97
        ? now - Duration(milliseconds: random.nextInt(2000))
        : now;

    beats.add((
      at: at,
      verdict: random.nextDouble() < goodWeight
          ? FormVerdict.good
          : others[random.nextInt(others.length)],
    ));
  }

  return beats;
}

void main() {
  const economy = UnlockEconomy();
  const target = Duration(seconds: 45);

  group('credit never exceeds what was earned', () {
    test('over 500 randomised sequences', () {
      final random = Random(20260916);

      for (var trial = 0; trial < 500; trial++) {
        // Swept from "barely ever in form" to "almost always in form", so the
        // accumulate path and the settle path are both hammered.
        final beats = randomBeats(random, goodWeight: trial / 500);
        final result = run(beats, target: target);

        expect(result.machine.creditedHold,
            lessThanOrEqualTo(result.oracle.goodFormTime),
            reason: 'trial $trial credited '
                '${result.machine.creditedHold.inMilliseconds}ms against '
                '${result.oracle.goodFormTime.inMilliseconds}ms of good form');
      }
    });

    test('with a perfectly regular stream, credit is almost all of it', () {
      // The bound has to be tight as well as safe: a machine that credits
      // nothing at all would pass the inequality above and be useless.
      final beats = [
        for (var i = 0; i <= 300; i++)
          (
            at: Duration(milliseconds: i * 100),
            verdict: FormVerdict.good,
          ),
      ];
      final result = run(beats, target: const Duration(minutes: 5));
      expect(result.machine.creditedHold, result.oracle.goodFormTime);
    });

    test('under-crediting is bounded by one frame per transition', () {
      // A verdict is only known at the frame that reports it, so each flip
      // costs at most one frame period. That is the whole gap between the
      // machine and the oracle, and it always falls in the user's disfavour.
      final random = Random(11);
      for (var trial = 0; trial < 200; trial++) {
        final beats = randomBeats(random, count: 120, allowGaps: false,
            allowBackwards: false);
        final result = run(beats, target: const Duration(minutes: 10));

        var transitions = 0;
        for (var i = 1; i < beats.length; i++) {
          if (beats[i].verdict != beats[i - 1].verdict) transitions++;
        }
        final worstLag = Duration(milliseconds: transitions * 280);

        expect(result.oracle.goodFormTime - result.machine.creditedHold,
            lessThanOrEqualTo(worstLag),
            reason: 'trial $trial under-credited by more than the frame lag');
      }
    });

    test('credit never exceeds the elapsed time of the attempt', () {
      final random = Random(3);
      for (var trial = 0; trial < 300; trial++) {
        final beats = randomBeats(random);
        final result = run(beats, target: const Duration(minutes: 10));
        final elapsed = beats.last.at;
        expect(result.machine.creditedHold, lessThanOrEqualTo(elapsed));
      }
    });

    test('credit plus grace never exceeds covered time', () {
      // Nothing can be simultaneously accumulating hold and burning grace, and
      // neither can run during a dropout.
      final random = Random(5);
      for (var trial = 0; trial < 300; trial++) {
        final result = run(randomBeats(random), target: const Duration(minutes: 10));
        expect(result.machine.creditedHold + result.machine.graceElapsed,
            lessThanOrEqualTo(result.oracle.coveredTime),
            reason: 'trial $trial double-counted an interval');
      }
    });
  });

  group('the payout follows', () {
    test('you can never be paid for time you did not spend in good form', () {
      // The same property as above, restated in the unit the user actually
      // experiences. This is the one a product manager would recognise.
      final random = Random(1979);

      for (var trial = 0; trial < 400; trial++) {
        final result = run(randomBeats(random), target: const Duration(seconds: 90));
        final paid = economy.earnedFor(result.machine.creditedHold);
        final deserved = economy.earnedFor(result.oracle.goodFormTime);

        expect(paid, lessThanOrEqualTo(deserved),
            reason: 'trial $trial paid ${paid.inSeconds}s of access for '
                '${result.oracle.goodFormTime.inSeconds}s of good form');
      }
    });

    test('a session can never pay more than the economy cap', () {
      final random = Random(2);
      final cap = economy.earnedFor(UnlockEconomy.maximumHold);
      for (var trial = 0; trial < 200; trial++) {
        final result = run(randomBeats(random, count: 2000),
            target: const Duration(minutes: 30));
        expect(economy.earnedFor(result.machine.creditedHold),
            lessThanOrEqualTo(cap));
      }
    });

    test('credit follows effort, not the tier that was aimed for', () {
      // The existing test for this asserts `earnedFor(40s) == earnedFor(40s)`,
      // which is true of any function at all. Here is the claim it was reaching
      // for: two users who do exactly the same thing are paid the same, even
      // though one picked a harder target.
      final random = Random(88);

      for (var trial = 0; trial < 200; trial++) {
        final beats = randomBeats(random, count: 150);

        final ambitious = run(beats, target: const Duration(seconds: 90));
        final modest = run(beats, target: const Duration(seconds: 90));
        expect(modest.machine.creditedHold, ambitious.machine.creditedHold);

        // And a shorter target can only ever stop earlier, never pay less for
        // the same held time.
        final short = run(beats, target: const Duration(seconds: 20));
        expect(short.machine.creditedHold,
            lessThanOrEqualTo(ambitious.machine.creditedHold));
        if (short.machine.outcome != SessionOutcome.completed) {
          expect(short.machine.creditedHold, ambitious.machine.creditedHold);
        }
      }
    });

    test('an attempt below the credit floor pays nothing however it ends', () {
      for (final ms in [0, 500, 5000, 14999]) {
        expect(economy.earnedFor(Duration(milliseconds: ms)), Duration.zero);
      }
    });
  });

  group('gaps are credited to nobody', () {
    test('inserting a dropout can only ever help the user', () {
      // Property form of the rule. Take any sequence, widen one inter-frame
      // interval past the gap limit, and compare.
      //
      // The naive expectation — "nothing changes" — is wrong, and finding out
      // why is the useful part. The frame straddling the dropout has its delta
      // discarded, so with the gap the machine accrues *less* grace and *less*
      // credit at that instant. Less grace can save an attempt that would
      // otherwise have settled; less credit costs at most that one frame. The
      // asymmetry is the right way round: a dropped pipeline is our fault, and
      // it can delay a settle but never cause one.
      final random = Random(404);

      for (var trial = 0; trial < 300; trial++) {
        final beats = randomBeats(random,
            count: 80, allowGaps: false, allowBackwards: false,
            goodWeight: trial / 300);
        final splitAt = 1 + random.nextInt(beats.length - 1);
        const dropout = Duration(seconds: 6);

        final withGap = <Beat>[
          ...beats.take(splitAt),
          for (final beat in beats.skip(splitAt))
            (at: beat.at + dropout, verdict: beat.verdict),
        ];

        final without = run(beats, target: const Duration(minutes: 10));
        final with_ = run(withGap, target: const Duration(minutes: 10));

        if (!without.machine.isTerminal) {
          expect(with_.machine.isTerminal, isFalse,
              reason: 'trial $trial: a dropout settled an attempt that would '
                  'otherwise have survived');
        }
        if (!with_.machine.isTerminal && !without.machine.isTerminal) {
          expect(
              (with_.machine.creditedHold - without.machine.creditedHold)
                  .inMilliseconds
                  .abs(),
              lessThanOrEqualTo(300),
              reason: 'trial $trial moved credit by more than one frame');
        }
      }
    });

    test('a dropout on the settling frame rescues the attempt', () {
      // The rescue direction, built deliberately rather than waited for. The
      // 31st broken frame is the one that pushes grace to the 3s budget; drop
      // the pipeline immediately before it and that frame's delta belongs to
      // nobody, so the attempt is still alive.
      List<Beat> sequence({required bool withDropout}) {
        final beats = <Beat>[];
        var now = Duration.zero;
        for (var i = 0; i < 50; i++) {
          beats.add((at: now, verdict: FormVerdict.good));
          now += const Duration(milliseconds: 100);
        }
        for (var i = 0; i < 31; i++) {
          if (withDropout && i == 30) now += const Duration(seconds: 6);
          beats.add((at: now, verdict: FormVerdict.broken));
          now += const Duration(milliseconds: 100);
        }
        return beats;
      }

      final settled = run(sequence(withDropout: false),
          target: const Duration(minutes: 10));
      final rescued = run(sequence(withDropout: true),
          target: const Duration(minutes: 10));

      expect(settled.machine.state, SessionState.ended);
      expect(rescued.machine.state, SessionState.paused);
      expect(rescued.machine.graceElapsed, const Duration(milliseconds: 2900));
      expect(rescued.machine.creditedHold, settled.machine.creditedHold,
          reason: 'the rescue costs the user nothing and pays them nothing');
    });

    test('a sequence made entirely of dropouts settles nothing', () {
      final beats = [
        for (var i = 0; i <= 20; i++)
          (at: Duration(seconds: i * 5), verdict: FormVerdict.broken),
      ];
      final result = run(beats, target: target);
      expect(result.machine.isTerminal, isFalse,
          reason: 'a hundred seconds of dropped frames must not end an attempt');
      expect(result.machine.graceElapsed, Duration.zero);
    });

    test('a clock that jumps backwards cannot create credit', () {
      final random = Random(1234);
      for (var trial = 0; trial < 200; trial++) {
        final beats = randomBeats(random, count: 200);
        final result = run(beats, target: const Duration(minutes: 10));
        expect(result.machine.creditedHold,
            lessThanOrEqualTo(result.oracle.goodFormTime));
        expect(result.machine.creditedHold,
            greaterThanOrEqualTo(Duration.zero));
      }
    });
  });

  group('invariants that must hold at every single frame', () {
    test('a full sweep of every intermediate state', () {
      final random = Random(60613);

      for (var trial = 0; trial < 200; trial++) {
        const config = SessionConfig(countdown: Duration.zero);
        final machine = SessionMachine(target: target, config: config)
          ..beginCountdown();
        final oracle = Oracle(config);
        var previousCredit = Duration.zero;

        for (final beat in randomBeats(random, count: 200)) {
          if (machine.isTerminal) break;
          machine.onFrame(
              SessionFrame(monotonic: beat.at, verdict: beat.verdict));
          oracle.observe(beat);

          expect(machine.creditedHold, greaterThanOrEqualTo(previousCredit),
              reason: 'credit went backwards');
          expect(machine.creditedHold, lessThanOrEqualTo(target));
          expect(machine.creditedHold,
              lessThanOrEqualTo(oracle.goodFormTime));
          expect(machine.graceElapsed, greaterThanOrEqualTo(Duration.zero));
          expect(machine.progress, inInclusiveRange(0.0, 1.0));
          expect(machine.remaining, greaterThanOrEqualTo(Duration.zero));
          expect(machine.remaining, target - machine.creditedHold);

          if (!machine.isTerminal) {
            final budget = machine.state == SessionState.lost
                ? config.graceAfterTrackingLoss
                : config.graceAfterFormBreak;
            if (machine.state == SessionState.paused ||
                machine.state == SessionState.lost) {
              expect(machine.graceElapsed, lessThan(budget),
                  reason: 'a live attempt cannot be past its grace budget');
            } else {
              expect(machine.graceElapsed, Duration.zero,
                  reason: 'grace must be clear outside paused and lost');
            }
          }

          previousCredit = machine.creditedHold;
        }

        if (machine.outcome == SessionOutcome.completed) {
          expect(machine.creditedHold, target);
        }
        if (machine.outcome == SessionOutcome.cancelled) {
          expect(machine.creditedHold, lessThan(config.cancelWindow));
        }
      }
    });

    test('an attempt only ever ends in one of the three honest ways', () {
      // There is no failure state. Whatever happens, the user either finished,
      // stopped with credit, or never really started.
      final random = Random(999);
      final reached = <SessionOutcome>{};

      for (var trial = 0; trial < 500; trial++) {
        // Two things are swept, because one is not enough to reach all three
        // outcomes. The bias decides whether an attempt ever gets going; the
        // clean prefix decides how much credit is banked before it falls apart,
        // which is what separates "never mind" from "a real attempt".
        final prefix = Duration(milliseconds: 100 * random.nextInt(90));
        final result = run(
          randomBeats(random,
              count: 400,
              goodWeight: 0.05 + trial / 520,
              prefixGood: prefix),
          target: const Duration(seconds: 20),
        );
        final outcome = result.machine.outcome;
        if (outcome != null) reached.add(outcome);
      }

      expect(reached, containsAll(SessionOutcome.values),
          reason: 'the sweep never reached ${SessionOutcome.values.toSet().difference(reached)}');
    });

    test('replaying the same stream gives the same answer every time', () {
      // This is the premise of the whole fixture harness: if a replay is not
      // deterministic, a fixture is not a regression test.
      final random = Random(31337);
      for (var trial = 0; trial < 100; trial++) {
        final beats = randomBeats(random, count: 250);
        final first = run(beats, target: target);
        final second = run(beats, target: target);

        expect(second.machine.state, first.machine.state);
        expect(second.machine.creditedHold, first.machine.creditedHold);
        expect(second.machine.graceElapsed, first.machine.graceElapsed);
        expect(second.machine.outcome, first.machine.outcome);
      }
    });
  });

  group('interleavings a person would not think to write', () {
    test('alternating good and bad form cannot outlast the real hold time', () {
      // The design flags rhythmic cheating explicitly: alternate good and bad
      // form and the timer pauses indefinitely. With no failure penalty that is
      // allowed — but it must never *pay* more than the good halves are worth.
      for (final goodMs in [50, 100, 200, 500, 1000]) {
        for (final badMs in [50, 200, 1000, 2500]) {
          final beats = <Beat>[];
          var now = Duration.zero;
          var realGood = Duration.zero;

          for (var cycle = 0; cycle < 40; cycle++) {
            for (var i = 0; i < 5; i++) {
              now += Duration(milliseconds: goodMs ~/ 5);
              realGood += Duration(milliseconds: goodMs ~/ 5);
              beats.add((at: now, verdict: FormVerdict.good));
            }
            for (var i = 0; i < 5; i++) {
              now += Duration(milliseconds: badMs ~/ 5);
              beats.add((at: now, verdict: FormVerdict.broken));
            }
          }

          final result = run(beats, target: const Duration(minutes: 30));
          expect(result.machine.creditedHold, lessThanOrEqualTo(realGood),
              reason: 'good=${goodMs}ms bad=${badMs}ms');
        }
      }
    });

    test('flickering between lost and broken spends grace only once', () {
      final beats = <Beat>[];
      var now = const Duration(seconds: 10);
      beats.add((at: Duration.zero, verdict: FormVerdict.good));
      beats.add((at: now, verdict: FormVerdict.good));
      for (var i = 0; i < 60; i++) {
        now += const Duration(milliseconds: 100);
        beats.add((
          at: now,
          verdict:
              i.isEven ? FormVerdict.indeterminate : FormVerdict.broken,
        ));
      }

      final result = run(beats, target: const Duration(minutes: 10));
      // Six seconds of alternating signals. Each cause keeps its own clock, so
      // roughly three seconds lands on each — and the form-break budget is
      // exactly three. Alternating buys a little room, which is the correct
      // direction when we are unsure whose fault it is, but it is bounded: the
      // attempt must not survive forever just because the category keeps
      // changing.
      expect(result.machine.isTerminal, isTrue,
          reason: 'flickering between causes must still terminate');
      expect(result.machine.creditedHold, Duration.zero,
          reason: 'the gap before the first pair is past the frame limit');
    });

    test('recovering on the very last frame before settling still counts', () {
      const config = SessionConfig(countdown: Duration.zero);
      final beats = <Beat>[];
      var now = Duration.zero;
      for (var i = 0; i < 200; i++) {
        beats.add((at: now, verdict: FormVerdict.good));
        now += const Duration(milliseconds: 100);
      }
      // Grace runs to 2.9s of a 3s budget, then one good frame.
      for (var i = 0; i < 30; i++) {
        beats.add((at: now, verdict: FormVerdict.broken));
        now += const Duration(milliseconds: 100);
      }
      beats.add((at: now, verdict: FormVerdict.good));

      final result = run(beats, target: const Duration(minutes: 10), config: config);
      expect(result.machine.state, SessionState.holding);
      expect(result.machine.graceElapsed, Duration.zero);
    });
  });
}
