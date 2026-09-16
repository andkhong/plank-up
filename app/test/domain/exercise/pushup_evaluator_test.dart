import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/exercise_evaluator.dart';
import 'package:plank_up/domain/exercise/pushup_evaluator.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'evaluator_fixtures.dart';
import 'pushup_fixtures.dart';

/// Feeds a stream and returns the last output.
EvalOutput feed(PushupEvaluator e, List<PoseFrame> frames) {
  var last = EvalOutput.unusable;
  for (final f in frames) {
    last = e.evaluate(f);
  }
  return last;
}

List<PoseFrame> repsStream({
  required int count,
  double bottomDepth = 1.0,
  double forearmConfidence = 0.9,
  Duration descent = const Duration(milliseconds: 700),
  Duration ascent = const Duration(milliseconds: 700),
}) {
  final frames = <PoseFrame>[];
  var t = Duration.zero;

  void add(List<PoseFrame> batch) {
    for (final f in batch) {
      frames.add(f);
    }
    if (frames.isNotEmpty) {
      t = frames.last.monotonic + const Duration(milliseconds: 33);
    }
  }

  add(pushupTop(
      start: t,
      span: const Duration(milliseconds: 600),
      forearmConfidence: forearmConfidence));
  for (var i = 0; i < count; i++) {
    add(pushupRep(
      start: t,
      bottomDepth: bottomDepth,
      forearmConfidence: forearmConfidence,
      descent: descent,
      ascent: ascent,
    ));
    add(pushupTop(
        start: t,
        span: const Duration(milliseconds: 500),
        forearmConfidence: forearmConfidence));
  }
  return frames;
}

void main() {
  group('the fixture is physically honest', () {
    test('descending genuinely bends the elbow', () {
      double angleAt(double depth) {
        final f = pushupFrame(depth: depth);
        final s = f[Joint.leftShoulder].position;
        final e = f[Joint.leftElbow].position;
        final w = f[Joint.leftWrist].position;
        final a = s - e;
        final b = w - e;
        final cos = a.dot(b) / (a.length * b.length);
        return cos.clamp(-1.0, 1.0);
      }

      // Cosine rises toward 1 as the angle closes. Top should be straighter
      // than bottom — if this fails, every test below is meaningless.
      expect(angleAt(1.0), greaterThan(angleAt(0.0)));
    });

    test('descending lowers the shoulder toward the ankle', () {
      final top = pushupFrame(depth: 0);
      final bottom = pushupFrame(depth: 1);
      expect(bottom[Joint.leftShoulder].y,
          greaterThan(top[Joint.leftShoulder].y),
          reason: 'y grows downward in image space');
    });
  });

  group('rep counting', () {
    test('a clean set counts every rep', () {
      final e = PushupEvaluator()..reset();
      final out = feed(e, repsStream(count: 5));
      expect(out.reps, 5);
      expect(e.repCount, 5);
    });

    test('reps accumulate rather than resetting', () {
      final e = PushupEvaluator()..reset();
      feed(e, repsStream(count: 3));
      expect(e.repCount, 3);
    });

    test('holding at the top counts nothing', () {
      final e = PushupEvaluator()..reset();
      final out = feed(
          e,
          pushupTop(
              start: Duration.zero, span: const Duration(seconds: 4)));
      expect(out.reps, 0);
    });

    test('reset clears the count', () {
      final e = PushupEvaluator()..reset();
      feed(e, repsStream(count: 2));
      expect(e.repCount, greaterThan(0));
      e.reset();
      expect(e.repCount, 0);
      expect(e.phase, PushupPhase.unknown);
    });
  });

  group('the forearm is not trusted alone', () {
    test('reps still count when the forearm is invisible', () {
      // The whole reason this evaluator measures shoulder descent as well as
      // elbow flexion: in a floor-level side view the forearm is under the
      // torso and routinely unreadable. A rep must survive that.
      final e = PushupEvaluator()..reset();
      final out = feed(e, repsStream(count: 4, forearmConfidence: 0.1));
      expect(out.reps, 4,
          reason: 'descent alone should be enough to count a rep');
    });

    test('a long set does not silently stop counting', () {
      // The regression this guards: the descent reference used to re-anchor at
      // whatever height the shoulder held when the top phase was entered, which
      // is slightly below true lockout. That ratcheted the anchor down every
      // rep until achievable travel fell under the threshold and counting
      // stopped mid-set. A four-rep test caught it at 2; a long set is what
      // makes the shape of the failure obvious.
      final e = PushupEvaluator()..reset();
      final out = feed(e, repsStream(count: 15, forearmConfidence: 0.1));
      expect(out.reps, 15);
    });

    test('a long set counts correctly with the forearm visible too', () {
      final e = PushupEvaluator()..reset();
      expect(feed(e, repsStream(count: 15)).reps, 15);
    });

    test('a hallucinated far arm cannot manufacture a rep', () {
      // Body never moves; only the low-confidence far-side landmarks jitter.
      final e = PushupEvaluator()..reset();
      final frames = <PoseFrame>[];
      for (var i = 0; i < 200; i++) {
        frames.add(pushupFrame(
          depth: 0,
          forearmConfidence: 0.2,
          monotonic: Duration(milliseconds: i * 33),
        ));
      }
      expect(feed(e, frames).reps, 0);
    });
  });

  group('bad reps do not count', () {
    test('a shallow rep is not counted', () {
      final e = PushupEvaluator()..reset();
      final out = feed(e, repsStream(count: 4, bottomDepth: 0.25));
      expect(out.reps, 0);
    });

    test('a bounced rep is too fast to count', () {
      final e = PushupEvaluator()..reset();
      final out = feed(
        e,
        repsStream(
          count: 4,
          descent: const Duration(milliseconds: 150),
          ascent: const Duration(milliseconds: 150),
        ),
      );
      expect(out.reps, 0, reason: 'under the minimum rep duration');
    });
  });

  group('form and failure semantics', () {
    test('a broken body line never fails the session', () {
      final e = PushupEvaluator()..reset();
      final out = e.evaluate(plankFrame(deviationDegrees: -40));
      expect(out.verdict, isNot(FormVerdict.indeterminate));
      expect(out.reps, 0);
    });

    test('reps already earned survive a form break', () {
      final e = PushupEvaluator()..reset();
      feed(e, repsStream(count: 3));
      final earned = e.repCount;
      expect(earned, greaterThan(0));

      for (var i = 0; i < 60; i++) {
        e.evaluate(plankFrame(
          deviationDegrees: -40,
          monotonic: Duration(milliseconds: 20000 + i * 33),
        ));
      }
      expect(e.repCount, earned, reason: 'a fault must not claw back reps');
    });

    test('a dropout neither invents nor destroys reps', () {
      final e = PushupEvaluator()..reset();
      feed(e, repsStream(count: 2));
      final before = e.repCount;

      for (var i = 0; i < 90; i++) {
        e.evaluate(frameOf(const {},
            monotonic: Duration(milliseconds: 30000 + i * 33)));
      }
      expect(e.repCount, before);
    });

    test('an unreadable frame reports indeterminate, never broken', () {
      final e = PushupEvaluator()..reset();
      final out = e.evaluate(frameOf(const {}));
      expect(out.verdict, FormVerdict.indeterminate);
    });
  });

  group('identity', () {
    test('is registered and self-describing', () {
      final e = PushupEvaluator();
      expect(e.id, ExerciseId.pushup);
      expect(e.displayName, 'Pushups');
      expect(e.setup.landscape, isTrue);
      expect(e.thresholdVersion, greaterThan(0));
    });

    test('does not require the forearm to start', () {
      // Framing must not block on the least reliable landmarks on the body.
      final required = PushupEvaluator().setup.requiredJoints;
      expect(required, isNot(contains(Joint.leftElbow)));
      expect(required, isNot(contains(Joint.leftWrist)));
    });
  });
}
