import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/exercise/form_hysteresis.dart';

void main() {
  group('FormBands', () {
    const bands = FormBands(degradedAt: 12, brokenAt: 22, releaseAt: 9);

    test('the good band is inclusive of its boundary', () {
      expect(bands.entryLevel(11.999), FormLevel.good.index);
      expect(bands.entryLevel(12), FormLevel.good.index);
      expect(bands.entryLevel(12.001), FormLevel.degraded.index);
      expect(bands.entryLevel(22), FormLevel.degraded.index);
      expect(bands.entryLevel(22.001), FormLevel.broken.index);
    });

    test('release thresholds sit below entry thresholds', () {
      expect(bands.releaseAt, lessThan(bands.degradedAt));
      expect(bands.brokenReleaseAt, lessThan(bands.brokenAt));
      // The same margin at both boundaries, so leaving broken is as deliberate
      // as leaving degraded.
      expect(bands.brokenAt - bands.brokenReleaseAt,
          bands.degradedAt - bands.releaseAt);
    });

    test('a frame is never better under release thresholds', () {
      for (var magnitude = 0.0; magnitude < 40; magnitude += 0.25) {
        expect(bands.releaseLevel(magnitude),
            greaterThanOrEqualTo(bands.entryLevel(magnitude)));
      }
    });

    test('the gap between the bands is where oscillation would live', () {
      // 10° is good enough to enter, not good enough to leave.
      expect(bands.entryLevel(10), FormLevel.good.index);
      expect(bands.releaseLevel(10), FormLevel.degraded.index);
    });

    test('a non-finite magnitude never accuses', () {
      expect(bands.entryLevel(double.nan), FormLevel.good.index);
      expect(bands.entryLevel(double.infinity), FormLevel.good.index);
      expect(bands.releaseLevel(double.nan), FormLevel.good.index);
    });
  });

  group('HysteresisLadder', () {
    HysteresisLadder ladder() => HysteresisLadder();

    void feed(HysteresisLadder subject, int level, int count) {
      for (var i = 0; i < count; i++) {
        subject.update(observed: level, release: level);
      }
    }

    test('starts good', () {
      expect(ladder().level, 0);
    });

    test('three of the last six never escalates', () {
      final subject = ladder();
      for (var i = 0; i < 60; i++) {
        subject.update(
          observed: i.isEven ? 0 : 2,
          release: i.isEven ? 0 : 2,
        );
        expect(subject.level, 0);
      }
    });

    test('four of the last six escalates, and not before', () {
      final subject = ladder();
      feed(subject, 0, 6);
      for (var i = 0; i < 3; i++) {
        subject.update(observed: 1, release: 1);
        expect(subject.level, 0, reason: 'after ${i + 1}');
      }
      subject.update(observed: 1, release: 1);
      expect(subject.level, 1);
    });

    test('escalation jumps to the worst level the votes support', () {
      final subject = ladder();
      feed(subject, 3, 4);
      expect(subject.level, 3);
    });

    test('release needs an unbroken run', () {
      final subject = ladder();
      feed(subject, 2, 4);
      expect(subject.level, 2);

      subject.update(observed: 0, release: 0);
      subject.update(observed: 0, release: 0);
      // One frame that is not clean enough resets the run entirely.
      subject.update(observed: 0, release: 2);
      expect(subject.level, 2);

      subject.update(observed: 0, release: 0);
      subject.update(observed: 0, release: 0);
      expect(subject.level, 2);
      subject.update(observed: 0, release: 0);
      expect(subject.level, 0);
    });

    test('release lands on the worst level seen during the run', () {
      final subject = ladder();
      feed(subject, 2, 4);
      subject.update(observed: 0, release: 1);
      subject.update(observed: 0, release: 0);
      subject.update(observed: 0, release: 1);
      // Three consecutive frames better than broken, but one of them was only
      // degraded, so we stop at degraded rather than declaring all clear.
      expect(subject.level, 1);
    });

    test('a frame at the release threshold forgives nothing', () {
      final subject = ladder();
      feed(subject, 1, 4);
      expect(subject.level, 1);
      for (var i = 0; i < 50; i++) {
        subject.update(observed: 0, release: 1);
      }
      expect(subject.level, 1);
    });

    test('hold does not feed the window in either direction', () {
      final subject = ladder();
      feed(subject, 0, 6);
      for (var i = 0; i < 100; i++) {
        subject.hold();
      }
      expect(subject.level, 0);
      expect(subject.windowLength, 6);

      feed(subject, 2, 4);
      expect(subject.level, 2);
      for (var i = 0; i < 100; i++) {
        subject.hold();
      }
      expect(subject.level, 2, reason: 'unreadable frames forgive nothing');
    });

    test('hold breaks a release run', () {
      final subject = ladder();
      feed(subject, 2, 4);
      subject.update(observed: 0, release: 0);
      subject.update(observed: 0, release: 0);
      subject.hold();
      subject.update(observed: 0, release: 0);
      expect(subject.level, 2);
    });

    test('the window really is only six deep', () {
      final subject = ladder();
      feed(subject, 2, 3);
      expect(subject.level, 0);
      // Six clean frames push the three bad ones out of the window, so the
      // fourth bad frame later is a lone frame again.
      feed(subject, 0, 6);
      subject.update(observed: 2, release: 2);
      expect(subject.level, 0);
    });

    test('reset returns it to the start', () {
      final subject = ladder();
      feed(subject, 3, 6);
      expect(subject.level, 3);
      subject.reset();
      expect(subject.level, 0);
      expect(subject.windowLength, 0);
    });

    test('out-of-range input is clamped rather than thrown', () {
      final subject = ladder();
      expect(() => subject.update(observed: 99, release: -4), returnsNormally);
      expect(subject.level, inInclusiveRange(0, 3));
    });

    test('no single frame ever moves a settled ladder', () {
      final random = math.Random(2026);
      for (var run = 0; run < 500; run++) {
        final subject = ladder();
        final settled = random.nextInt(4);
        feed(subject, settled, 6);
        expect(subject.level, settled);

        final before = subject.level;
        final rogue = random.nextInt(4);
        subject.update(observed: rogue, release: rogue);
        expect(subject.level, before,
            reason: 'settled at $settled, one frame at $rogue');
      }
    });
  });
}
