/// Loads fixtures off disk and replays them at their recorded timestamps
/// against a fake clock.
///
/// The point of the whole exercise: form evaluation is testable without a human
/// on the floor, and without waiting 90 real seconds to find out. A 90-second
/// plank replays in single-digit milliseconds because nothing here sleeps —
/// time advances because a frame carries a later timestamp, never because a
/// wall clock ticked.
///
/// Two ways to drive it:
///
/// * **Label-driven** (the default). Verdicts come from the sidecar's hand-
///   labelled timeline. This tests the *session machine* against the fixture
///   and proves the fixture itself is coherent. It needs no evaluator, which is
///   why the corpus can be built and proved before one exists.
/// * **Evaluator-driven.** Pass `verdicts:` to run a real evaluator over the
///   frames. Compare the result against the label-driven run, or use
///   [labelAgreement] to get a per-frame confusion breakdown. That comparison
///   *is* the evaluator regression test: did the evaluator change its mind
///   about a body it has already seen?
///
/// See `fixture_format.dart` for the format and — importantly — for what this
/// harness structurally cannot observe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

import 'fixture_format.dart';

/// Injected time. The domain takes `DateTime` directly rather than a clock
/// abstraction, so this exists to hand a deterministic instant to anything
/// outside the session loop (grants, schedules) while the session itself is
/// driven purely by frame timestamps.
///
/// It advances only when told to. There is no `Timer`, no `Future.delayed` and
/// no real elapsed time anywhere in this file, which is what makes a replay
/// deterministic and fast.
class FakeClock {
  FakeClock({DateTime? start}) : _now = start ?? DateTime.utc(2026, 1, 1, 9);

  DateTime _now;
  Duration _monotonic = Duration.zero;

  DateTime get now => _now;

  /// The monotonic reading, kept in lockstep with the frame stream.
  Duration get monotonic => _monotonic;

  void advance(Duration by) {
    if (by.isNegative) {
      throw ArgumentError.value(by, 'by', 'a fake clock never runs backwards');
    }
    _now = _now.add(by);
    _monotonic += by;
  }

  /// Jumps to a monotonic reading, which is how frame timestamps drive it.
  void advanceTo(Duration monotonic) {
    if (monotonic < _monotonic) return;
    advance(monotonic - _monotonic);
  }
}

/// A fixture as loaded: frames plus the sidecar.
class Fixture {
  const Fixture({required this.manifest, required this.frames, this.path});

  final FixtureManifest manifest;
  final List<PoseFrame> frames;

  /// Where it came from, for error messages.
  final String? path;

  String get name => manifest.name;

  Duration get duration =>
      frames.isEmpty ? Duration.zero : frames.last.monotonic;

  /// The hand-labelled verdict at a frame's timestamp.
  FormVerdict verdictFor(PoseFrame frame) {
    final verdict = manifest.verdictAtMs(frame.monotonic.inMilliseconds);
    if (verdict == null) {
      throw FixtureFormatException(
        'no label covers ${frame.monotonic.inMilliseconds}ms',
        source: path ?? name,
      );
    }
    return verdict;
  }

  List<FormVerdict> get labelledVerdicts =>
      [for (final frame in frames) verdictFor(frame)];
}

/// What a replay produced.
class ReplayResult {
  const ReplayResult({
    required this.fixture,
    required this.machine,
    required this.clock,
    required this.verdicts,
  });

  final Fixture fixture;
  final SessionMachine machine;
  final FakeClock clock;

  /// One verdict per frame actually dispatched. Shorter than the frame list if
  /// the machine reached a terminal state early.
  final List<FormVerdict> verdicts;

  SessionState get state => machine.state;
  SessionOutcome? get outcome => machine.outcome;
  Duration get creditedHold => machine.creditedHold;

  /// Mismatches against the sidecar's `expect` block. Empty means it passed.
  List<String> get expectationFailures {
    final expect = fixture.manifest.expect;
    final problems = <String>[];

    if (expect.state != null && machine.state != expect.state) {
      problems.add(
          'expected state ${expect.state!.name}, got ${machine.state.name}');
    }
    if (machine.outcome != expect.outcome) {
      problems.add('expected outcome ${expect.outcome?.name}, '
          'got ${machine.outcome?.name}');
    }
    final credited = expect.creditedHoldMs;
    if (credited != null &&
        !credited.contains(machine.creditedHold.inMilliseconds)) {
      problems.add('credited hold ${machine.creditedHold.inMilliseconds}ms '
          'outside $credited');
    }
    return problems;
  }
}

/// Feeds a fixture's frames to a session machine at their recorded timestamps.
///
/// [verdicts] turns a frame into a verdict; omit it to use the hand-labelled
/// timeline. [onFrame] is called after each frame is applied, for tests that
/// need to assert mid-stream.
ReplayResult replayFixture(
  Fixture fixture, {
  FormVerdict Function(PoseFrame frame)? verdicts,
  SessionMachine? machine,
  FakeClock? clock,
  bool beginCountdown = true,
  void Function(PoseFrame frame, FormVerdict verdict, SessionMachine machine)?
      onFrame,
}) {
  final session = machine ??
      SessionMachine(
        target: fixture.manifest.session.target,
        config: fixture.manifest.session.config,
      );
  final fakeClock = clock ?? FakeClock();
  final source = verdicts ?? fixture.verdictFor;
  final applied = <FormVerdict>[];

  if (beginCountdown) session.beginCountdown();

  for (final frame in fixture.frames) {
    if (session.isTerminal) break;
    // The clock moves because a frame said so. Nothing here waits.
    fakeClock.advanceTo(frame.monotonic);
    final verdict = source(frame);
    applied.add(verdict);
    session.onFrame(
        SessionFrame(monotonic: frame.monotonic, verdict: verdict));
    onFrame?.call(frame, verdict, session);
  }

  return ReplayResult(
    fixture: fixture,
    machine: session,
    clock: fakeClock,
    verdicts: applied,
  );
}

/// Per-frame comparison of an evaluator's verdicts against the hand labels.
class LabelAgreement {
  LabelAgreement(this.total, this.matched, this.confusion, this.firstDivergence);

  final int total;
  final int matched;

  /// `confusion[labelled][produced]` counts.
  final Map<FormVerdict, Map<FormVerdict, int>> confusion;

  /// Timestamp of the first disagreement, which is almost always the one worth
  /// looking at.
  final Duration? firstDivergence;

  double get agreement => total == 0 ? 1 : matched / total;

  /// Frames the evaluator called [FormVerdict.broken] where the human said
  /// [FormVerdict.good]. This is the number the design says to weight most
  /// heavily: a false reject costs the install, a false accept costs nothing.
  int get falseBreaks => confusion[FormVerdict.good]?[FormVerdict.broken] ?? 0;

  @override
  String toString() => 'agreement ${(agreement * 100).toStringAsFixed(1)}% '
      '($matched/$total), falseBreaks=$falseBreaks, '
      'firstDivergence=${firstDivergence?.inMilliseconds}ms';
}

LabelAgreement labelAgreement(
  Fixture fixture,
  FormVerdict Function(PoseFrame frame) verdicts,
) {
  final confusion = <FormVerdict, Map<FormVerdict, int>>{};
  var matched = 0;
  var total = 0;
  Duration? firstDivergence;

  for (final frame in fixture.frames) {
    final labelled = fixture.verdictFor(frame);
    final produced = verdicts(frame);
    total++;
    if (labelled == produced) {
      matched++;
    } else {
      firstDivergence ??= frame.monotonic;
    }
    (confusion[labelled] ??= {})
        .update(produced, (n) => n + 1, ifAbsent: () => 1);
  }

  return LabelAgreement(total, matched, confusion, firstDivergence);
}

/// Finds fixtures on disk.
///
/// Tests run with the working directory at the Flutter package root (`app/`),
/// but the corpus lives at the repository root so the recorder, the validator
/// and any future Swift/Kotlin consumer share one copy. This walks up to find
/// it rather than hard-coding `../`.
class FixtureLibrary {
  FixtureLibrary(this.directory);

  factory FixtureLibrary.locate() => FixtureLibrary(_findFixturesDirectory());

  final Directory directory;

  static Directory _findFixturesDirectory() {
    var dir = Directory.current.absolute;
    for (var i = 0; i < 8; i++) {
      final candidate = Directory('${dir.path}/fixtures');
      if (candidate.existsSync()) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    throw StateError(
        'no fixtures/ directory found above ${Directory.current.path}');
  }

  /// Fixture stems, sorted, one per `.jsonl` file.
  List<String> names() => directory
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.jsonl'))
      .map((n) => n.substring(0, n.length - '.jsonl'.length))
      .toList()
    ..sort();

  File framesFile(String name) => File('${directory.path}/$name.jsonl');
  File manifestFile(String name) => File('${directory.path}/$name.expected.json');

  Fixture load(String name) {
    final frames = framesFile(name);
    final sidecar = manifestFile(name);
    if (!frames.existsSync()) {
      throw FixtureFormatException('no frame stream', source: frames.path);
    }
    if (!sidecar.existsSync()) {
      throw FixtureFormatException(
        'every fixture needs a sidecar; expected ${sidecar.path}',
        source: frames.path,
      );
    }

    final parsed =
        FixtureCodec.decodeStream(frames.readAsStringSync(), source: frames.path);
    final manifest = FixtureManifest.fromJson(
      _decodeJsonObject(sidecar),
      source: sidecar.path,
    );

    if (manifest.name != name) {
      throw FixtureFormatException(
        'sidecar names itself "${manifest.name}" but the file stem is "$name"',
        source: sidecar.path,
      );
    }

    final problems = validateLabels(manifest, parsed);
    if (problems.isNotEmpty) {
      throw FixtureFormatException(problems.join('; '), source: sidecar.path);
    }

    return Fixture(manifest: manifest, frames: parsed, path: frames.path);
  }

  List<Fixture> loadAll() => [for (final name in names()) load(name)];

  /// Writes a fixture pair. Used by the synthetic-tier generator; recorded
  /// fixtures are written by the on-device recorder using the same codec.
  void write(String name, List<PoseFrame> frames, FixtureManifest manifest) {
    framesFile(name).writeAsStringSync(FixtureCodec.encodeStream(frames));
    manifestFile(name).writeAsStringSync(encodeManifest(manifest));
  }

  static Map<String, Object?> _decodeJsonObject(File file) {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw FixtureFormatException('sidecar must be a JSON object',
          source: file.path);
    }
    return decoded;
  }
}

/// Two-space-indented JSON with a trailing newline, so sidecars diff cleanly.
String encodeManifest(FixtureManifest manifest) =>
    '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n';
