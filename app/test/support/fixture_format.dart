/// The on-disk format for recorded landmark streams, and its codec.
///
/// ## Shape
///
/// A fixture is **two files** that share a stem, under `fixtures/`:
///
/// ```
/// fixtures/plank_clean_hold.jsonl          one frame per line, nothing else
/// fixtures/plank_clean_hold.expected.json  metadata, timeline labels, expectations
/// ```
///
/// The frame file is JSON Lines so the debug recorder can append a line per
/// frame and survive being killed mid-session: a truncated final line is the
/// only damage possible, and everything before it is still a valid corpus. It
/// also means a 90-second recording diffs as 1350 independent lines rather than
/// as one 500 KB blob.
///
/// A frame line:
///
/// ```json
/// {"tMs":0,"gravity":[0.0,1.0],"detection":0.95,"persons":1,
///  "joints":{"leftShoulder":[0.19,0.5,0.97],"leftHip":[0.47,0.51,0.96]}}
/// ```
///
/// * `tMs` is the **native monotonic capture timestamp**, not a wall clock, and
///   not a frame index. Everything is scored off it. It must be non-negative
///   and strictly increasing down the file.
/// * `joints` maps [Joint] enum names to `[x, y, confidence]` in normalised
///   image space, y downward. A joint that is absent from the map is absent
///   from the frame — that is how dropout is recorded. An unrecognised joint
///   name is an error rather than a skip, so a landmark-schema change fails
///   loudly instead of silently degrading the corpus.
/// * `gravity` is the measured accelerometer direction in image space. It is
///   per-frame because the phone can be knocked over mid-session, and that
///   event is a gravity discontinuity.
///
/// ## Labels live on the clip timeline, not on the landmarks
///
/// The sidecar's `labels` are `[fromMs, toMs)` intervals over the *same
/// timeline*, and they must tile the recording with no gap and no overlap.
/// That is deliberate: it is what lets the same label set be reused when the
/// landmarks are re-derived from the original video by a different pose
/// backend. Swapping backends then costs one processing pass instead of a
/// re-shoot, and the two derived corpora are directly comparable because they
/// are judged against identical ground truth.
///
/// ## What this harness cannot see — read before trusting it
///
/// **A landmark-stream corpus begins at the moment landmarks already exist.**
/// It therefore cannot observe any failure of the detection stage:
///
/// * **Demographic acquisition failure.** BlazePose uses a face detector as its
///   person-detector proxy, and that family has a documented recall gap on
///   dark-skinned subjects. The failure mode is not "the hip angle is 4° off",
///   it is **"no person detected"** — and a fixture that starts from landmarks
///   has, by construction, already succeeded at the step that failed. Green
///   fixtures say nothing whatsoever about this.
/// * **Model drift.** The pose model ships with the OS and changes underneath
///   us. These fixtures cannot be pinned to a model version, so they measure
///   our evaluator against a frozen recording, not our pipeline against a
///   moving model.
/// * **Framing, lighting, clothing, camera geometry.** Anything that decides
///   whether landmarks appear at all.
///
/// Those need the video tier: raw clips, access-controlled, never bundled, run
/// nightly and against every OS beta. This harness is the per-PR tier. It
/// answers "did the evaluator change its mind about a body it can already see",
/// which is a real and useful question, and it is not coverage of the product.
library;

import 'dart:convert';

import 'package:plank_up/domain/pose/pose_frame.dart';
import 'package:plank_up/domain/session/session_machine.dart';

/// Bumped when the on-disk shape changes incompatibly. The loader refuses a
/// version it does not know rather than guessing.
const int fixtureFormatVersion = 1;

class FixtureFormatException implements Exception {
  FixtureFormatException(this.message, {this.source, this.line});

  final String message;
  final String? source;
  final int? line;

  @override
  String toString() {
    final where = [
      if (source != null) source,
      if (line != null) 'line $line',
    ].join(':');
    return where.isEmpty
        ? 'FixtureFormatException: $message'
        : 'FixtureFormatException ($where): $message';
  }
}

/// Where a fixture came from. The tiers are not interchangeable and the
/// difference matters when a fixture disagrees with reality.
enum FixtureTier {
  /// Generated from [PoseBuilder]. Exhaustive, noiseless, and exactly as
  /// trustworthy as the model that generated it.
  synthetic,

  /// Recorded off a device from a real human. Carries real noise. Cannot see
  /// the detection stage, since it begins after detection succeeded.
  landmark,

  /// Re-derived offline from an archived video clip by running a pose backend
  /// over it. Same blind spot as [landmark] for the detector, but re-derivable
  /// when the backend changes.
  videoDerived,
}

/// One `[fromMs, toMs)` interval of ground truth on the clip timeline.
class FixtureLabel {
  const FixtureLabel({
    required this.fromMs,
    required this.toMs,
    required this.verdict,
    this.faults = const [],
    this.note,
  });

  final int fromMs;
  final int toMs;
  final FormVerdict verdict;

  /// Fault codes named as strings rather than as the enum, so the corpus does
  /// not break every time the enum gains a member. The evaluator tests map them.
  final List<String> faults;

  final String? note;

  bool contains(int tMs) => tMs >= fromMs && tMs < toMs;

  Map<String, Object?> toJson() => {
        'fromMs': fromMs,
        'toMs': toMs,
        'verdict': verdict.name,
        if (faults.isNotEmpty) 'faults': faults,
        if (note != null) 'note': note,
      };

  static FixtureLabel fromJson(Map<String, Object?> json) => FixtureLabel(
        fromMs: _int(json, 'fromMs'),
        toMs: _int(json, 'toMs'),
        verdict: _enumByName(FormVerdict.values, _string(json, 'verdict'), 'verdict'),
        faults: [
          for (final f in (json['faults'] as List<Object?>? ?? const []))
            f.toString(),
        ],
        note: json['note'] as String?,
      );
}

/// An inclusive range assertion. Written as a range rather than an exact value
/// because accumulation is frame-quantised: the true answer is bounded, not
/// pinned, and pretending otherwise produces a test that fails on a frame-rate
/// change without anything being wrong.
class RangeMs {
  const RangeMs(this.min, this.max);

  final int min;
  final int max;

  bool contains(int value) => value >= min && value <= max;

  Map<String, Object?> toJson() => {'min': min, 'max': max};

  static RangeMs fromJson(Object? json, String field) {
    if (json is! Map<String, Object?>) {
      throw FixtureFormatException('$field must be an object with min and max');
    }
    return RangeMs(_int(json, 'min'), _int(json, 'max'));
  }

  @override
  String toString() => '[$min..$max]ms';
}

/// What replaying this fixture must produce.
class FixtureExpectation {
  const FixtureExpectation({
    this.state,
    this.outcome,
    this.creditedHoldMs,
    this.earnedUnlockMs,
  });

  /// [SessionState] at the end of the replay.
  final SessionState? state;

  /// [SessionOutcome], or null if the fixture is expected to end mid-attempt.
  final SessionOutcome? outcome;

  final RangeMs? creditedHoldMs;

  /// Optional: the unlock time the credited hold buys. Ties the fixture to the
  /// economy, which is the number the user actually experiences.
  final RangeMs? earnedUnlockMs;

  Map<String, Object?> toJson() => {
        if (state != null) 'state': state!.name,
        'outcome': outcome?.name,
        if (creditedHoldMs != null) 'creditedHoldMs': creditedHoldMs!.toJson(),
        if (earnedUnlockMs != null) 'earnedUnlockMs': earnedUnlockMs!.toJson(),
      };

  static FixtureExpectation fromJson(Map<String, Object?> json) {
    final outcomeName = json['outcome'];
    return FixtureExpectation(
      state: json['state'] == null
          ? null
          : _enumByName(SessionState.values, _string(json, 'state'), 'state'),
      outcome: outcomeName == null
          ? null
          : _enumByName(
              SessionOutcome.values, outcomeName.toString(), 'outcome'),
      creditedHoldMs: json['creditedHoldMs'] == null
          ? null
          : RangeMs.fromJson(json['creditedHoldMs'], 'creditedHoldMs'),
      earnedUnlockMs: json['earnedUnlockMs'] == null
          ? null
          : RangeMs.fromJson(json['earnedUnlockMs'], 'earnedUnlockMs'),
    );
  }
}

/// How the session machine should be configured for this fixture. Only the
/// knobs a fixture plausibly needs; everything else takes the product default,
/// so a fixture stays honest about what it is actually exercising.
class FixtureSessionSetup {
  const FixtureSessionSetup({
    this.targetMs = 60000,
    this.countdownMs,
    this.graceAfterFormBreakMs,
    this.graceAfterTrackingLossMs,
    this.cancelWindowMs,
    this.maxSingleFrameGapMs,
  });

  final int targetMs;
  final int? countdownMs;
  final int? graceAfterFormBreakMs;
  final int? graceAfterTrackingLossMs;
  final int? cancelWindowMs;
  final int? maxSingleFrameGapMs;

  Duration get target => Duration(milliseconds: targetMs);

  SessionConfig get config {
    const defaults = SessionConfig();
    return SessionConfig(
      countdown: countdownMs == null
          ? defaults.countdown
          : Duration(milliseconds: countdownMs!),
      graceAfterFormBreak: graceAfterFormBreakMs == null
          ? defaults.graceAfterFormBreak
          : Duration(milliseconds: graceAfterFormBreakMs!),
      graceAfterTrackingLoss: graceAfterTrackingLossMs == null
          ? defaults.graceAfterTrackingLoss
          : Duration(milliseconds: graceAfterTrackingLossMs!),
      cancelWindow: cancelWindowMs == null
          ? defaults.cancelWindow
          : Duration(milliseconds: cancelWindowMs!),
      maxSingleFrameGap: maxSingleFrameGapMs == null
          ? defaults.maxSingleFrameGap
          : Duration(milliseconds: maxSingleFrameGapMs!),
    );
  }

  Map<String, Object?> toJson() => {
        'targetMs': targetMs,
        if (countdownMs != null) 'countdownMs': countdownMs,
        if (graceAfterFormBreakMs != null)
          'graceAfterFormBreakMs': graceAfterFormBreakMs,
        if (graceAfterTrackingLossMs != null)
          'graceAfterTrackingLossMs': graceAfterTrackingLossMs,
        if (cancelWindowMs != null) 'cancelWindowMs': cancelWindowMs,
        if (maxSingleFrameGapMs != null)
          'maxSingleFrameGapMs': maxSingleFrameGapMs,
      };

  static FixtureSessionSetup fromJson(Map<String, Object?>? json) {
    if (json == null) return const FixtureSessionSetup();
    return FixtureSessionSetup(
      targetMs: _int(json, 'targetMs'),
      countdownMs: _optInt(json, 'countdownMs'),
      graceAfterFormBreakMs: _optInt(json, 'graceAfterFormBreakMs'),
      graceAfterTrackingLossMs: _optInt(json, 'graceAfterTrackingLossMs'),
      cancelWindowMs: _optInt(json, 'cancelWindowMs'),
      maxSingleFrameGapMs: _optInt(json, 'maxSingleFrameGapMs'),
    );
  }
}

/// The sidecar.
class FixtureManifest {
  const FixtureManifest({
    required this.name,
    required this.tier,
    required this.exercise,
    required this.description,
    required this.labels,
    this.formatVersion = fixtureFormatVersion,
    this.frameRateHz,
    this.provenance = const {},
    this.session = const FixtureSessionSetup(),
    this.expect = const FixtureExpectation(),
    this.blindSpots = const [],
  });

  final String name;
  final FixtureTier tier;

  /// [ExerciseId] name. A string rather than the enum so the corpus outlives
  /// enum churn.
  final String exercise;

  final String description;
  final List<FixtureLabel> labels;
  final int formatVersion;
  final double? frameRateHz;

  /// Free-form: subject id, device, body type, lighting, mat position. Never
  /// anything that identifies a person — the consent archive holds that, the
  /// repo does not.
  final Map<String, Object?> provenance;

  final FixtureSessionSetup session;
  final FixtureExpectation expect;

  /// What this particular recording is known *not* to cover.
  final List<String> blindSpots;

  FormVerdict? verdictAtMs(int tMs) {
    for (final label in labels) {
      if (label.contains(tMs)) return label.verdict;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'formatVersion': formatVersion,
        'fixture': name,
        'tier': tier.name,
        'exercise': exercise,
        'description': description,
        if (frameRateHz != null) 'frameRateHz': frameRateHz,
        if (provenance.isNotEmpty) 'provenance': provenance,
        'session': session.toJson(),
        'labels': [for (final l in labels) l.toJson()],
        'expect': expect.toJson(),
        if (blindSpots.isNotEmpty) 'blindSpots': blindSpots,
      };

  static FixtureManifest fromJson(Map<String, Object?> json, {String? source}) {
    final version = _int(json, 'formatVersion');
    if (version != fixtureFormatVersion) {
      throw FixtureFormatException(
        'unsupported formatVersion $version (this build reads $fixtureFormatVersion)',
        source: source,
      );
    }
    final labelsJson = json['labels'];
    if (labelsJson is! List || labelsJson.isEmpty) {
      throw FixtureFormatException('labels must be a non-empty list',
          source: source);
    }
    return FixtureManifest(
      name: _string(json, 'fixture'),
      tier: _enumByName(FixtureTier.values, _string(json, 'tier'), 'tier'),
      exercise: _string(json, 'exercise'),
      description: _string(json, 'description'),
      frameRateHz: (json['frameRateHz'] as num?)?.toDouble(),
      provenance: (json['provenance'] as Map<String, Object?>?) ?? const {},
      session:
          FixtureSessionSetup.fromJson(json['session'] as Map<String, Object?>?),
      labels: [
        for (final l in labelsJson)
          FixtureLabel.fromJson(l as Map<String, Object?>),
      ],
      expect: FixtureExpectation.fromJson(
          (json['expect'] as Map<String, Object?>?) ?? const {}),
      blindSpots: [
        for (final b in (json['blindSpots'] as List<Object?>? ?? const []))
          b.toString(),
      ],
      formatVersion: version,
    );
  }
}

/// Encodes and decodes the `.jsonl` frame stream.
class FixtureCodec {
  const FixtureCodec._();

  static String encodeFrame(PoseFrame frame) {
    final joints = <String, Object?>{};
    for (final entry in frame.landmarks.entries) {
      joints[entry.key.name] = [
        _round(entry.value.x),
        _round(entry.value.y),
        _round(entry.value.confidence),
      ];
    }
    return jsonEncode({
      'tMs': frame.monotonic.inMilliseconds,
      'gravity': [_round(frame.gravity.x), _round(frame.gravity.y)],
      'detection': _round(frame.detectionConfidence),
      'persons': frame.personCount,
      'joints': joints,
    });
  }

  static PoseFrame decodeFrame(String line, {String? source, int? lineNumber}) {
    final Object? parsed;
    try {
      parsed = jsonDecode(line);
    } on FormatException catch (e) {
      throw FixtureFormatException('not valid JSON: ${e.message}',
          source: source, line: lineNumber);
    }
    if (parsed is! Map<String, Object?>) {
      throw FixtureFormatException('each line must be a JSON object',
          source: source, line: lineNumber);
    }

    final tMs = _int(parsed, 'tMs');
    if (tMs < 0) {
      throw FixtureFormatException('tMs must be non-negative, got $tMs',
          source: source, line: lineNumber);
    }

    final gravity = parsed['gravity'];
    if (gravity is! List || gravity.length != 2) {
      throw FixtureFormatException('gravity must be [x, y]',
          source: source, line: lineNumber);
    }

    final jointsJson = parsed['joints'];
    if (jointsJson is! Map<String, Object?>) {
      throw FixtureFormatException('joints must be an object',
          source: source, line: lineNumber);
    }

    final landmarks = <Joint, Landmark>{};
    for (final entry in jointsJson.entries) {
      final joint = _jointByName(entry.key, source: source, line: lineNumber);
      final value = entry.value;
      if (value is! List || value.length != 3) {
        throw FixtureFormatException(
            'joint ${entry.key} must be [x, y, confidence]',
            source: source,
            line: lineNumber);
      }
      landmarks[joint] = Landmark(
        (value[0] as num).toDouble(),
        (value[1] as num).toDouble(),
        (value[2] as num).toDouble(),
      );
    }

    return PoseFrame(
      monotonic: Duration(milliseconds: tMs),
      landmarks: Map.unmodifiable(landmarks),
      gravity: Vec2(
        (gravity[0] as num).toDouble(),
        (gravity[1] as num).toDouble(),
      ),
      detectionConfidence: ((parsed['detection'] as num?) ?? 1).toDouble(),
      personCount: ((parsed['persons'] as num?) ?? 1).toInt(),
    );
  }

  /// Parses a whole `.jsonl` body. Blank lines are skipped so a trailing
  /// newline is not an error; a truncated final line is, because silently
  /// dropping it would hide a recorder crash.
  static List<PoseFrame> decodeStream(String contents, {String? source}) {
    final frames = <PoseFrame>[];
    final lines = const LineSplitter().convert(contents);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      frames.add(decodeFrame(line, source: source, lineNumber: i + 1));
    }
    if (frames.isEmpty) {
      throw FixtureFormatException('no frames', source: source);
    }
    for (var i = 1; i < frames.length; i++) {
      if (frames[i].monotonic <= frames[i - 1].monotonic) {
        throw FixtureFormatException(
          'timestamps must strictly increase: '
          '${frames[i - 1].monotonic.inMilliseconds}ms then '
          '${frames[i].monotonic.inMilliseconds}ms',
          source: source,
          line: i + 1,
        );
      }
    }
    return frames;
  }

  static String encodeStream(Iterable<PoseFrame> frames) =>
      '${frames.map(encodeFrame).join('\n')}\n';
}

/// Rejects a fixture whose labels do not tile its frames. Returns the problems
/// rather than throwing, so a validator can report all of them at once.
List<String> validateLabels(FixtureManifest manifest, List<PoseFrame> frames) {
  final problems = <String>[];
  final labels = manifest.labels;

  for (final label in labels) {
    if (label.toMs <= label.fromMs) {
      problems.add('label [${label.fromMs}, ${label.toMs}) is empty or inverted');
    }
  }

  final sorted = [...labels]..sort((a, b) => a.fromMs.compareTo(b.fromMs));
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].fromMs < sorted[i - 1].toMs) {
      problems.add('labels overlap at ${sorted[i].fromMs}ms');
    } else if (sorted[i].fromMs > sorted[i - 1].toMs) {
      problems.add(
          'label gap between ${sorted[i - 1].toMs}ms and ${sorted[i].fromMs}ms');
    }
  }

  for (final frame in frames) {
    if (manifest.verdictAtMs(frame.monotonic.inMilliseconds) == null) {
      problems.add('frame at ${frame.monotonic.inMilliseconds}ms has no label');
      break;
    }
  }

  return problems;
}

/// Six decimal places is ~1/1,000,000 of frame width, three orders of magnitude
/// below any landmark's own noise, and it keeps a line diffable. Negative zero
/// is folded away so a level phone does not record its gravity as `[-0.0, 1.0]`.
double _round(double v) {
  final rounded = (v * 1000000).roundToDouble() / 1000000;
  return rounded == 0 ? 0 : rounded;
}

Joint _jointByName(String name, {String? source, int? line}) {
  for (final joint in Joint.values) {
    if (joint.name == name) return joint;
  }
  throw FixtureFormatException(
    'unknown joint "$name" — the landmark schema changed, so this fixture '
    'cannot be trusted rather than partially read',
    source: source,
    line: line,
  );
}

T _enumByName<T extends Enum>(List<T> values, String name, String field) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FixtureFormatException(
      '$field "$name" is not one of ${values.map((v) => v.name).join(', ')}');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FixtureFormatException('missing or non-numeric "$key"');
  }
  return value.toInt();
}

int? _optInt(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is num ? value.toInt() : null;
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FixtureFormatException('missing "$key"');
  return value;
}
