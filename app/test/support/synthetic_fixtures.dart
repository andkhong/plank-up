/// The synthetic-tier fixtures committed under `fixtures/`.
///
/// These exist to prove the format end to end — codec, sidecar, label tiling,
/// loader, replay driver — with something small enough that a reviewer can open
/// the `.jsonl` and read it. They are generated from [PoseBuilder] rather than
/// typed by hand so the geometry is exactly what the sidecar claims, and
/// `fixture_corpus_test.dart` holds them as goldens so they cannot drift away
/// from this definition without CI saying so.
///
/// They are *not* the corpus. The real corpus is recorded off devices
/// (`FixtureTier.landmark`) and re-derived from archived video
/// (`FixtureTier.videoDerived`), and neither of those has a generator here.
/// The design's minimum before thresholds are locked is ≥5 subjects × ≥3 body
/// types × ≥2 devices per exercise; two noiseless synthetic clips are not a
/// down payment on that.
library;

import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'fixture_format.dart';
import 'pose_builder.dart';

class SyntheticFixture {
  const SyntheticFixture({
    required this.name,
    required this.frames,
    required this.manifest,
  });

  final String name;
  final List<PoseFrame> frames;
  final FixtureManifest manifest;
}

/// The frame rate the native bridge emits, and the rate these are authored at.
const double fixtureHz = 15;

const _blindSpots = [
  'Landmark-tier blindness: these frames begin after detection already '
      'succeeded, so nothing here can observe a person failing to be detected '
      'at all — the documented BlazeFace skin-tone recall gap included.',
  'Noiseless: real landmarks jitter, and a threshold that passes here can still '
      'oscillate on a device. Hysteresis and the 4-of-6 smoothing window need '
      'recorded fixtures, not these.',
  'Single body type, single framing, single lighting. Synthetic fixtures sweep '
      'the parameters we thought of.',
];

/// Every synthetic fixture, in the order they are written.
List<SyntheticFixture> syntheticFixtures() => [
      _cleanHold(),
      _briefDip(),
    ];

/// A clean plank held straight through to the target. The happy path, and the
/// one that proves credited time tracks real elapsed time.
SyntheticFixture _cleanHold() {
  const duration = Duration(seconds: 3);
  final frames = holdPose(
    const PoseBuilder(hipDeviationDegrees: -3),
    duration: duration,
    hz: fixtureHz,
  );

  return SyntheticFixture(
    name: 'plank_clean_hold',
    frames: frames,
    manifest: FixtureManifest(
      name: 'plank_clean_hold',
      tier: FixtureTier.synthetic,
      exercise: 'plank',
      description:
          'Three seconds of a straight plank at -3 degrees, phone level, '
          'side-on. Reaches a 2s target and completes.',
      frameRateHz: fixtureHz,
      provenance: const {
        'generator': 'test/support/synthetic_fixtures.dart',
        'geometry': 'hipDeviation=-3deg, obliquity=0deg, roll=0deg',
      },
      session: const FixtureSessionSetup(targetMs: 2000, countdownMs: 400),
      labels: [
        FixtureLabel(
          fromMs: 0,
          toMs: _coveredMs(frames),
          verdict: FormVerdict.good,
          note: 'well inside the <=12 degree good band throughout',
        ),
      ],
      expect: const FixtureExpectation(
        state: SessionState.completed,
        outcome: SessionOutcome.completed,
        // Exact, because reaching the target clamps.
        creditedHoldMs: RangeMs(2000, 2000),
        // A completed 2s target still pays nothing: the economy's credit floor
        // is 15s, without which repeated two-second holds would be the cheapest
        // path to unlimited access.
        earnedUnlockMs: RangeMs(0, 0),
      ),
      blindSpots: _blindSpots,
    ),
  );
}

/// Two seconds of sag inside a three-second grace budget. The design names this
/// case explicitly: a brief dip **must not** end the attempt. It is also the
/// case a naive implementation gets wrong by treating any bad frame as a
/// failure, which is precisely how you convert a committed user into a one-star
/// review.
SyntheticFixture _briefDip() {
  const duration = Duration(seconds: 5);
  const dipStartMs = 1500;
  const dipEndMs = 3500;

  final frames = poseStream(
    duration: duration,
    hz: fixtureHz,
    at: (elapsed) {
      final ms = elapsed.inMilliseconds;
      final sagging = ms >= dipStartMs && ms < dipEndMs;
      return PoseBuilder(hipDeviationDegrees: sagging ? -28 : -4);
    },
  );

  return SyntheticFixture(
    name: 'plank_brief_dip',
    frames: frames,
    manifest: FixtureManifest(
      name: 'plank_brief_dip',
      tier: FixtureTier.synthetic,
      exercise: 'plank',
      description:
          'A good hold, two seconds of hips at -28 degrees, then recovery. The '
          'dip is shorter than the 3s form grace, so the attempt survives it '
          'and resumes where it stopped.',
      frameRateHz: fixtureHz,
      provenance: const {
        'generator': 'test/support/synthetic_fixtures.dart',
        'geometry': 'hipDeviation -4deg, -28deg during the dip, obliquity=0',
      },
      session: const FixtureSessionSetup(targetMs: 30000, countdownMs: 400),
      labels: [
        const FixtureLabel(
          fromMs: 0,
          toMs: dipStartMs,
          verdict: FormVerdict.good,
        ),
        const FixtureLabel(
          fromMs: dipStartMs,
          toMs: dipEndMs,
          verdict: FormVerdict.broken,
          faults: ['hipSag'],
          note: '-28 degrees, past the >22 degree broken band',
        ),
        FixtureLabel(
          fromMs: dipEndMs,
          toMs: _coveredMs(frames),
          verdict: FormVerdict.good,
          note: 'recovered; accumulation resumes and grace resets',
        ),
      ],
      expect: const FixtureExpectation(
        state: SessionState.holding,
        outcome: null,
        // 1.1s before the dip plus 1.5s after it, less the frames spent on each
        // transition. Pinned as one frame period either side of the observed
        // 2533ms, because it is frame-quantised and an exact value would fail
        // on a cadence change without anything being wrong.
        creditedHoldMs: RangeMs(2466, 2600),
      ),
      blindSpots: _blindSpots,
    ),
  );
}

/// The end of the covered timeline: one frame period past the last frame, so
/// the labels tile the whole recording including the final frame's period.
int _coveredMs(List<PoseFrame> frames) =>
    frames.last.monotonic.inMilliseconds + (1000 / fixtureHz).round();
