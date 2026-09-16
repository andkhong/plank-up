/// Tests for the fixture codec and the replay driver.
///
/// A fixture format is a contract between a debug recorder that runs on a
/// device and a test suite that runs in CI, and the two are written months
/// apart by people who cannot see each other's work. So the interesting tests
/// here are the *rejections*: the cases where a fixture is subtly wrong and the
/// loader has to say so loudly instead of quietly producing a green run over a
/// corrupt corpus.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'fixture_format.dart';
import 'frame_replay.dart';
import 'pose_builder.dart';

FixtureManifest manifestFor(
  List<PoseFrame> frames, {
  String name = 'test_fixture',
  List<FixtureLabel>? labels,
  FixtureSessionSetup session = const FixtureSessionSetup(targetMs: 10000),
  FixtureExpectation expect = const FixtureExpectation(),
}) =>
    FixtureManifest(
      name: name,
      tier: FixtureTier.synthetic,
      exercise: 'plank',
      description: 'generated in a test',
      labels: labels ??
          [
            FixtureLabel(
              fromMs: 0,
              toMs: frames.last.monotonic.inMilliseconds + 100,
              verdict: FormVerdict.good,
            ),
          ],
      session: session,
      expect: expect,
      blindSpots: const ['synthetic'],
    );

void main() {
  final sample = holdPose(const PoseBuilder(hipDeviationDegrees: -5),
      duration: const Duration(seconds: 2));

  group('codec round trip', () {
    test('a frame survives encode and decode', () {
      final original = const PoseBuilder(
        monotonic: Duration(milliseconds: 1234),
        hipDeviationDegrees: -11,
        obliquityDegrees: 18,
        phoneRollDegrees: 9,
        personCount: 2,
        detectionConfidence: 0.71,
      ).build();

      final decoded = FixtureCodec.decodeFrame(FixtureCodec.encodeFrame(original));

      expect(decoded.monotonic, original.monotonic);
      expect(decoded.personCount, 2);
      expect(decoded.detectionConfidence, closeTo(0.71, 1e-9));
      expect(decoded.gravity.x, closeTo(original.gravity.x, 1e-6));
      expect(decoded.gravity.y, closeTo(original.gravity.y, 1e-6));
      expect(decoded.landmarks.keys.toSet(), original.landmarks.keys.toSet());
      for (final joint in original.landmarks.keys) {
        expect(decoded[joint].x, closeTo(original[joint].x, 1e-6));
        expect(decoded[joint].y, closeTo(original[joint].y, 1e-6));
        expect(decoded[joint].confidence,
            closeTo(original[joint].confidence, 1e-6));
      }
    });

    test('encoding is idempotent, so goldens are stable', () {
      final once = FixtureCodec.encodeFrame(sample.first);
      final twice = FixtureCodec.encodeFrame(FixtureCodec.decodeFrame(once));
      expect(twice, once);
    });

    test('absent joints stay absent rather than becoming zeroes', () {
      final original =
          const PoseBuilder(missing: {Joint.nose, Joint.leftAnkle}).build();
      final decoded =
          FixtureCodec.decodeFrame(FixtureCodec.encodeFrame(original));
      expect(decoded.landmarks.containsKey(Joint.nose), isFalse);
      expect(decoded[Joint.nose].confidence, 0);
      expect(decoded.landmarks.containsKey(Joint.rightAnkle), isTrue);
    });

    test('a whole stream round trips', () {
      final decoded = FixtureCodec.decodeStream(
          FixtureCodec.encodeStream(sample));
      expect(decoded.length, sample.length);
      expect(decoded.last.monotonic, sample.last.monotonic);
    });

    test('a trailing newline is not an error', () {
      expect(
          FixtureCodec.decodeStream(
              '${FixtureCodec.encodeStream(sample)}\n\n'),
          hasLength(sample.length));
    });
  });

  group('the codec refuses what it cannot trust', () {
    test('a truncated final line fails rather than being dropped', () {
      final encoded = FixtureCodec.encodeStream(sample);
      final truncated = encoded.substring(0, encoded.length - 40);
      expect(() => FixtureCodec.decodeStream(truncated),
          throwsA(isA<FixtureFormatException>()));
    });

    test('an unknown joint name fails loudly', () {
      // The model ships with the OS and its landmark schema can change under
      // us. Silently skipping an unrecognised joint would leave a corpus that
      // looks green while measuring half a body.
      const line = '{"tMs":0,"gravity":[0,1],"joints":{"leftToe":[0.1,0.2,0.9]}}';
      expect(
        () => FixtureCodec.decodeFrame(line),
        throwsA(isA<FixtureFormatException>().having(
            (e) => e.message, 'message', contains('leftToe'))),
      );
    });

    test('non-increasing timestamps fail', () {
      final out = [
        FixtureCodec.encodeFrame(sample[2]),
        FixtureCodec.encodeFrame(sample[1]),
      ].join('\n');
      expect(
        () => FixtureCodec.decodeStream(out),
        throwsA(isA<FixtureFormatException>().having(
            (e) => e.message, 'message', contains('strictly increase'))),
      );
    });

    test('a duplicate timestamp fails', () {
      final line = FixtureCodec.encodeFrame(sample.first);
      expect(() => FixtureCodec.decodeStream('$line\n$line'),
          throwsA(isA<FixtureFormatException>()));
    });

    test('a negative timestamp fails', () {
      expect(
          () => FixtureCodec.decodeFrame(
              '{"tMs":-1,"gravity":[0,1],"joints":{}}'),
          throwsA(isA<FixtureFormatException>()));
    });

    test('a missing gravity vector fails', () {
      expect(() => FixtureCodec.decodeFrame('{"tMs":0,"joints":{}}'),
          throwsA(isA<FixtureFormatException>()));
    });

    test('an empty stream fails', () {
      expect(() => FixtureCodec.decodeStream('\n\n'),
          throwsA(isA<FixtureFormatException>()));
    });

    test('an unknown format version is refused, not guessed at', () {
      expect(
        () => FixtureManifest.fromJson({
          'formatVersion': fixtureFormatVersion + 1,
          'fixture': 'x',
          'tier': 'synthetic',
          'exercise': 'plank',
          'description': 'x',
          'labels': <Object?>[],
        }),
        throwsA(isA<FixtureFormatException>().having(
            (e) => e.message, 'message', contains('formatVersion'))),
      );
    });

    test('errors name the file and the line', () {
      final broken = 'not json';
      expect(
        () => FixtureCodec.decodeStream(broken, source: 'fixtures/x.jsonl'),
        throwsA(isA<FixtureFormatException>().having((e) => e.toString(),
            'toString', allOf(contains('fixtures/x.jsonl'), contains('line 1')))),
      );
    });
  });

  group('label tiling', () {
    test('a gap between labels is a problem', () {
      final manifest = manifestFor(sample, labels: const [
        FixtureLabel(fromMs: 0, toMs: 1000, verdict: FormVerdict.good),
        FixtureLabel(fromMs: 1500, toMs: 3000, verdict: FormVerdict.good),
      ]);
      expect(validateLabels(manifest, sample),
          contains(contains('label gap between 1000ms and 1500ms')));
    });

    test('overlapping labels are a problem', () {
      final manifest = manifestFor(sample, labels: const [
        FixtureLabel(fromMs: 0, toMs: 1500, verdict: FormVerdict.good),
        FixtureLabel(fromMs: 1000, toMs: 3000, verdict: FormVerdict.broken),
      ]);
      expect(validateLabels(manifest, sample),
          contains(contains('overlap')));
    });

    test('an inverted label is a problem', () {
      final manifest = manifestFor(sample, labels: const [
        FixtureLabel(fromMs: 2000, toMs: 500, verdict: FormVerdict.good),
      ]);
      expect(validateLabels(manifest, sample), isNotEmpty);
    });

    test('frames past the end of the labels are a problem', () {
      final manifest = manifestFor(sample, labels: const [
        FixtureLabel(fromMs: 0, toMs: 500, verdict: FormVerdict.good),
      ]);
      expect(validateLabels(manifest, sample),
          contains(contains('has no label')));
    });

    test('a correctly tiled set has no problems', () {
      expect(validateLabels(manifestFor(sample), sample), isEmpty);
    });

    test('intervals are half-open, so a boundary belongs to exactly one label',
        () {
      final manifest = manifestFor(sample, labels: const [
        FixtureLabel(fromMs: 0, toMs: 1000, verdict: FormVerdict.good),
        FixtureLabel(fromMs: 1000, toMs: 5000, verdict: FormVerdict.broken),
      ]);
      expect(manifest.verdictAtMs(999), FormVerdict.good);
      expect(manifest.verdictAtMs(1000), FormVerdict.broken);
    });
  });

  group('the fake clock', () {
    test('advances only when told to', () {
      final clock = FakeClock(start: DateTime.utc(2026, 5, 1, 12));
      final before = clock.now;
      expect(clock.now, before);
      clock.advance(const Duration(minutes: 5));
      expect(clock.now.difference(before), const Duration(minutes: 5));
      expect(clock.monotonic, const Duration(minutes: 5));
    });

    test('never runs backwards', () {
      final clock = FakeClock();
      expect(() => clock.advance(const Duration(seconds: -1)), throwsArgumentError);
    });

    test('advanceTo a past reading is a no-op rather than a rewind', () {
      final clock = FakeClock()..advanceTo(const Duration(seconds: 10));
      clock.advanceTo(const Duration(seconds: 4));
      expect(clock.monotonic, const Duration(seconds: 10));
    });
  });

  group('replay', () {
    late Directory temp;
    late FixtureLibrary library;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('plankup_fixtures');
      Directory('${temp.path}/fixtures').createSync();
      library = FixtureLibrary(Directory('${temp.path}/fixtures'));
    });

    tearDown(() => temp.deleteSync(recursive: true));

    Fixture write(String name, List<PoseFrame> frames, FixtureManifest m) {
      library.write(name, frames, m);
      return library.load(name);
    }

    test('drives the machine at recorded timestamps, not wall time', () {
      final frames = holdPose(const PoseBuilder(),
          duration: const Duration(seconds: 90), hz: 15);
      final fixture = write(
        'long_hold',
        frames,
        manifestFor(frames,
            name: 'long_hold',
            session: const FixtureSessionSetup(
                targetMs: 60000, countdownMs: 1000)),
      );

      final started = DateTime.now();
      final result = replayFixture(fixture);
      final wall = DateTime.now().difference(started);

      // Ninety seconds of plank, replayed in a blink.
      expect(result.state, SessionState.completed);
      expect(result.creditedHold, const Duration(seconds: 60));
      expect(wall, lessThan(const Duration(seconds: 1)));
    });

    test('the fake clock ends up at the last frame dispatched', () {
      final fixture = write('short', sample, manifestFor(sample, name: 'short'));
      final result = replayFixture(fixture);
      expect(result.clock.monotonic, result.fixture.frames.last.monotonic);
    });

    test('label-driven and evaluator-driven runs agree when the evaluator does',
        () {
      final fixture = write('short', sample, manifestFor(sample, name: 'short'));
      final labelled = replayFixture(fixture);
      final evaluated =
          replayFixture(fixture, verdicts: (_) => FormVerdict.good);
      expect(evaluated.creditedHold, labelled.creditedHold);
      expect(evaluated.state, labelled.state);
    });

    test('an evaluator that cries wolf is visible in the agreement report', () {
      final fixture = write('short', sample, manifestFor(sample, name: 'short'));
      // Every frame is labelled good; this evaluator breaks on every other one.
      var i = 0;
      final agreement = labelAgreement(fixture, (_) {
        final even = i.isEven;
        i++;
        return even ? FormVerdict.good : FormVerdict.broken;
      });

      expect(agreement.total, sample.length);
      expect(agreement.agreement, closeTo(0.5, 0.05));
      expect(agreement.falseBreaks, greaterThan(0));
      expect(agreement.firstDivergence, isNotNull);
    });

    test('a perfect evaluator scores 1.0 with no false breaks', () {
      final fixture = write('short', sample, manifestFor(sample, name: 'short'));
      final agreement = labelAgreement(fixture, fixture.verdictFor);
      expect(agreement.agreement, 1.0);
      expect(agreement.falseBreaks, 0);
    });

    test('replay stops at a terminal state instead of feeding past it', () {
      final frames = holdPose(const PoseBuilder(),
          duration: const Duration(seconds: 10), hz: 15);
      final fixture = write(
        'early_finish',
        frames,
        manifestFor(frames,
            name: 'early_finish',
            session: const FixtureSessionSetup(targetMs: 1000, countdownMs: 0)),
      );
      final result = replayFixture(fixture);
      expect(result.state, SessionState.completed);
      expect(result.verdicts.length, lessThan(frames.length));
    });

    test('onFrame sees every dispatched frame in order', () {
      final fixture = write('short', sample, manifestFor(sample, name: 'short'));
      final seen = <Duration>[];
      replayFixture(fixture,
          onFrame: (frame, _, _) => seen.add(frame.monotonic));
      expect(seen.length, sample.length);
      expect(seen, orderedEquals(List.of(seen)..sort()));
    });

    test('expectation failures name the mismatch', () {
      final fixture = write(
        'wrong',
        sample,
        manifestFor(sample,
            name: 'wrong',
            expect: const FixtureExpectation(
              state: SessionState.completed,
              outcome: SessionOutcome.completed,
              creditedHoldMs: RangeMs(99000, 99000),
            )),
      );
      final failures = replayFixture(fixture).expectationFailures;
      expect(failures, hasLength(3));
      expect(failures.join(), contains('expected state completed'));
      expect(failures.join(), contains('outside [99000..99000]ms'));
    });

    test('session config overrides in the sidecar actually take effect', () {
      // Without this, a fixture could silently be measured against the product
      // defaults while claiming to test a tighter grace budget.
      final frames = <PoseFrame>[
        ...holdPose(const PoseBuilder(), duration: const Duration(seconds: 2)),
      ];
      final labels = [
        const FixtureLabel(fromMs: 0, toMs: 1000, verdict: FormVerdict.good),
        FixtureLabel(
            fromMs: 1000,
            toMs: frames.last.monotonic.inMilliseconds + 100,
            verdict: FormVerdict.broken),
      ];

      final strict = write(
        'strict',
        frames,
        manifestFor(frames,
            name: 'strict',
            labels: labels,
            session: const FixtureSessionSetup(
              targetMs: 60000,
              countdownMs: 0,
              graceAfterFormBreakMs: 200,
              cancelWindowMs: 100,
            )),
      );
      expect(replayFixture(strict).state, SessionState.ended);

      final lenient = write(
        'lenient',
        frames,
        manifestFor(frames,
            name: 'lenient',
            labels: labels,
            session: const FixtureSessionSetup(
              targetMs: 60000,
              countdownMs: 0,
              graceAfterFormBreakMs: 30000,
            )),
      );
      expect(replayFixture(lenient).state, SessionState.paused);
    });
  });

  group('the library', () {
    late Directory temp;
    late FixtureLibrary library;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('plankup_fixtures');
      Directory('${temp.path}/fixtures').createSync();
      library = FixtureLibrary(Directory('${temp.path}/fixtures'));
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('a frame stream with no sidecar is refused', () {
      library.framesFile('orphan')
          .writeAsStringSync(FixtureCodec.encodeStream(sample));
      expect(
        () => library.load('orphan'),
        throwsA(isA<FixtureFormatException>().having((e) => e.message, 'message',
            contains('needs a sidecar'))),
      );
    });

    test('a sidecar naming a different fixture is refused', () {
      library.write('a', sample, manifestFor(sample, name: 'b'));
      expect(
        () => library.load('a'),
        throwsA(isA<FixtureFormatException>().having(
            (e) => e.message, 'message', contains('names itself'))),
      );
    });

    test('a badly labelled fixture is refused at load, not at replay', () {
      library.write(
          'bad',
          sample,
          manifestFor(sample, name: 'bad', labels: const [
            FixtureLabel(fromMs: 0, toMs: 100, verdict: FormVerdict.good),
          ]));
      expect(() => library.load('bad'), throwsA(isA<FixtureFormatException>()));
    });

    test('names() lists stems, not filenames', () {
      library.write('a', sample, manifestFor(sample, name: 'a'));
      library.write('b', sample, manifestFor(sample, name: 'b'));
      expect(library.names(), ['a', 'b']);
      expect(library.loadAll(), hasLength(2));
    });

    test('the real corpus is found from the package root', () {
      // Tests run with the working directory at app/, but fixtures live at the
      // repository root so the recorder and any native consumer share one copy.
      expect(FixtureLibrary.locate().directory.existsSync(), isTrue);
    });
  });
}
