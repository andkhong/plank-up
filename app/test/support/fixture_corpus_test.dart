/// Every fixture in the repository, loaded and replayed.
///
/// Three separate jobs, and it is worth being clear which is which:
///
/// 1. **The format holds.** Every `.jsonl` parses, every sidecar parses, every
///    label set tiles its frames. A malformed fixture fails here rather than
///    surfacing as a confusing evaluator failure three months later.
/// 2. **The sidecar's expectations are met.** Replaying the hand-labelled
///    timeline through the session machine produces what the sidecar says it
///    will. This is what makes a fixture an assertion rather than a file.
/// 3. **The synthetic fixtures match their generator.** They are goldens; if
///    the pose builder changes shape, the committed bytes must be regenerated
///    deliberately rather than drifting.
///
/// Regenerate the synthetic tier with:
/// `PLANKUP_REGENERATE_FIXTURES=1 flutter test test/support/fixture_corpus_test.dart`
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/economy/unlock_economy.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'fixture_format.dart';
import 'frame_replay.dart';
import 'synthetic_fixtures.dart';

void main() {
  final library = FixtureLibrary.locate();
  final regenerate =
      Platform.environment['PLANKUP_REGENERATE_FIXTURES'] == '1';

  if (regenerate) {
    for (final fixture in syntheticFixtures()) {
      library.write(fixture.name, fixture.frames, fixture.manifest);
    }
  }

  test('the corpus is not empty', () {
    expect(library.names(), isNotEmpty,
        reason: 'no fixtures found in ${library.directory.path}');
  });

  group('synthetic fixtures match their generator', () {
    for (final fixture in syntheticFixtures()) {
      test(fixture.name, () {
        final frames = library.framesFile(fixture.name);
        final sidecar = library.manifestFile(fixture.name);
        expect(frames.existsSync(), isTrue, reason: '${frames.path} is missing');
        expect(sidecar.existsSync(), isTrue,
            reason: '${sidecar.path} is missing');

        expect(frames.readAsStringSync(),
            FixtureCodec.encodeStream(fixture.frames),
            reason: 'frame stream drifted from the generator; regenerate with '
                'PLANKUP_REGENERATE_FIXTURES=1');
        expect(sidecar.readAsStringSync(), encodeManifest(fixture.manifest),
            reason: 'sidecar drifted from the generator');
      });
    }
  });

  group('every fixture loads, validates and replays', () {
    for (final name in library.names()) {
      group(name, () {
        late Fixture fixture;

        setUp(() => fixture = library.load(name));

        test('loads and its labels tile its frames', () {
          expect(fixture.frames, isNotEmpty);
          expect(validateLabels(fixture.manifest, fixture.frames), isEmpty);
          expect(fixture.manifest.description, isNotEmpty);
          // Every fixture has to say what it cannot see. A landmark stream that
          // claims no blind spots is a landmark stream nobody has thought about.
          expect(fixture.manifest.blindSpots, isNotEmpty,
              reason: 'document what this fixture is blind to');
        });

        test('replays to the sidecar expectations', () {
          final result = replayFixture(fixture);
          expect(result.expectationFailures, isEmpty,
              reason: 'replay of $name diverged:\n'
                  '${result.expectationFailures.join('\n')}');
        });

        test('replay is deterministic', () {
          final first = replayFixture(fixture);
          final second = replayFixture(fixture);
          expect(second.state, first.state);
          expect(second.creditedHold, first.creditedHold);
          expect(second.verdicts, first.verdicts);
        });

        test('credited time never exceeds the labelled good-form time', () {
          // The property the whole product rests on, checked against ground
          // truth rather than against the machine's own arithmetic.
          final result = replayFixture(fixture);
          final config = fixture.manifest.session.config;

          var goodFormMs = 0;
          Duration? previous;
          for (var i = 0; i < result.verdicts.length; i++) {
            final frame = fixture.frames[i];
            if (previous != null && result.verdicts[i] == FormVerdict.good) {
              final delta = frame.monotonic - previous;
              if (delta <= config.maxSingleFrameGap) {
                goodFormMs += delta.inMilliseconds;
              }
            }
            previous = frame.monotonic;
          }

          expect(result.creditedHold.inMilliseconds,
              lessThanOrEqualTo(goodFormMs),
              reason: 'credited more than the labels allow');
        });

        test('replaying costs no real time', () {
          // A 90-second plank has to replay in milliseconds or the corpus stops
          // being run per PR. Nothing in the harness sleeps; this pins it.
          final started = DateTime.now();
          replayFixture(fixture);
          expect(DateTime.now().difference(started),
              lessThan(const Duration(milliseconds: 500)));
        });
      });
    }
  });

  group('expectations tie through to what the user is paid', () {
    test('a completed fixture buys exactly what the economy says', () {
      const economy = UnlockEconomy();
      for (final name in library.names()) {
        final fixture = library.load(name);
        final expected = fixture.manifest.expect.earnedUnlockMs;
        if (expected == null) continue;
        final result = replayFixture(fixture);
        expect(expected.contains(economy.earnedFor(result.creditedHold).inMilliseconds),
            isTrue,
            reason: '$name paid '
                '${economy.earnedFor(result.creditedHold).inMilliseconds}ms, '
                'expected $expected');
      }
    });
  });
}
