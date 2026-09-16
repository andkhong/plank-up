#!/usr/bin/env dart
// Structural validation of the fixture corpus, with no Flutter and no package
// dependencies.
//
//   dart run tool/validate_fixtures.dart [fixtures_dir]
//
// The Dart loader in `app/test/support/frame_replay.dart` is the authoritative
// gate — it runs in `flutter test`, it decodes into real `PoseFrame`s and it
// replays them. This exists for the two places that one cannot reach:
//
//   * the debug fixture recorder, which writes files on a machine that may not
//     have the app package resolved, and wants to check its own output before
//     anyone commits it;
//   * a future Swift or Kotlin consumer of the same corpus, for whom this file
//     doubles as an executable statement of the format.
//
// It deliberately duplicates the structural rules rather than importing them.
// If the two ever disagree, the Dart loader wins and this file is the one to
// fix.
//
// Exit code 0 if every fixture is well formed, 1 otherwise.

import 'dart:convert';
import 'dart:io';

const int expectedFormatVersion = 1;

const Set<String> knownJoints = {
  'nose',
  'leftEar',
  'rightEar',
  'leftShoulder',
  'rightShoulder',
  'leftElbow',
  'rightElbow',
  'leftWrist',
  'rightWrist',
  'leftHip',
  'rightHip',
  'leftKnee',
  'rightKnee',
  'leftAnkle',
  'rightAnkle',
};

const Set<String> knownVerdicts = {
  'good',
  'broken',
  'outOfPosition',
  'indeterminate',
};

const Set<String> knownTiers = {'synthetic', 'landmark', 'videoDerived'};

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : _findFixturesDir();
  final dir = Directory(root);

  if (!dir.existsSync()) {
    stderr.writeln('no fixtures directory at $root');
    exit(1);
  }

  final stems = dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.jsonl'))
      .map((n) => n.substring(0, n.length - '.jsonl'.length))
      .toList()
    ..sort();

  if (stems.isEmpty) {
    stderr.writeln('no .jsonl fixtures found in $root');
    exit(1);
  }

  var failed = 0;
  for (final stem in stems) {
    final problems = validate(dir, stem);
    if (problems.isEmpty) {
      stdout.writeln('ok    $stem');
    } else {
      failed++;
      stdout.writeln('FAIL  $stem');
      for (final problem in problems) {
        stdout.writeln('        $problem');
      }
    }
  }

  stdout.writeln('${stems.length - failed}/${stems.length} fixtures valid');
  exit(failed == 0 ? 0 : 1);
}

List<String> validate(Directory dir, String stem) {
  final problems = <String>[];
  final framesFile = File('${dir.path}/$stem.jsonl');
  final sidecarFile = File('${dir.path}/$stem.expected.json');

  if (!sidecarFile.existsSync()) {
    return ['missing sidecar $stem.expected.json'];
  }

  // --- frames ------------------------------------------------------------
  final timestamps = <int>[];
  final lines = const LineSplitter().convert(framesFile.readAsStringSync());
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final where = '$stem.jsonl:${i + 1}';

    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      problems.add('$where is not valid JSON (${e.message})');
      continue;
    }
    if (decoded is! Map<String, Object?>) {
      problems.add('$where is not a JSON object');
      continue;
    }

    final t = decoded['tMs'];
    if (t is! num) {
      problems.add('$where has no numeric tMs');
    } else if (t < 0) {
      problems.add('$where has a negative tMs');
    } else {
      if (timestamps.isNotEmpty && t <= timestamps.last) {
        problems.add('$where timestamp ${t.toInt()}ms does not increase past '
            '${timestamps.last}ms');
      }
      timestamps.add(t.toInt());
    }

    final gravity = decoded['gravity'];
    if (gravity is! List || gravity.length != 2 || gravity.any((v) => v is! num)) {
      problems.add('$where gravity must be [x, y]');
    }

    final joints = decoded['joints'];
    if (joints is! Map<String, Object?>) {
      problems.add('$where joints must be an object');
    } else {
      for (final entry in joints.entries) {
        if (!knownJoints.contains(entry.key)) {
          problems.add('$where unknown joint "${entry.key}"');
        }
        final v = entry.value;
        if (v is! List || v.length != 3 || v.any((n) => n is! num)) {
          problems.add('$where joint "${entry.key}" must be [x, y, confidence]');
        }
      }
    }
  }

  if (timestamps.isEmpty) {
    problems.add('$stem.jsonl contains no frames');
  }

  // --- sidecar -----------------------------------------------------------
  Object? sidecar;
  try {
    sidecar = jsonDecode(sidecarFile.readAsStringSync());
  } on FormatException catch (e) {
    return [...problems, '$stem.expected.json is not valid JSON (${e.message})'];
  }
  if (sidecar is! Map<String, Object?>) {
    return [...problems, '$stem.expected.json is not a JSON object'];
  }

  if (sidecar['formatVersion'] != expectedFormatVersion) {
    problems.add('$stem.expected.json formatVersion is '
        '${sidecar['formatVersion']}, expected $expectedFormatVersion');
  }
  if (sidecar['fixture'] != stem) {
    problems.add('$stem.expected.json names itself "${sidecar['fixture']}"');
  }
  if (!knownTiers.contains(sidecar['tier'])) {
    problems.add('$stem.expected.json tier "${sidecar['tier']}" is not one of '
        '${knownTiers.join(', ')}');
  }
  for (final required in ['exercise', 'description']) {
    final value = sidecar[required];
    if (value is! String || value.isEmpty) {
      problems.add('$stem.expected.json is missing "$required"');
    }
  }
  final blindSpots = sidecar['blindSpots'];
  if (blindSpots is! List || blindSpots.isEmpty) {
    problems.add('$stem.expected.json must document its blindSpots — a '
        'landmark stream that claims none is one nobody has thought about');
  }

  // --- labels tile the frames -------------------------------------------
  final labels = sidecar['labels'];
  if (labels is! List || labels.isEmpty) {
    problems.add('$stem.expected.json has no labels');
    return problems;
  }

  final intervals = <({int from, int to})>[];
  for (final label in labels) {
    if (label is! Map<String, Object?>) {
      problems.add('$stem.expected.json has a non-object label');
      continue;
    }
    final from = label['fromMs'];
    final to = label['toMs'];
    if (from is! num || to is! num) {
      problems.add('$stem.expected.json label needs numeric fromMs and toMs');
      continue;
    }
    if (to <= from) {
      problems.add('$stem.expected.json label [$from, $to) is empty or '
          'inverted');
      continue;
    }
    if (!knownVerdicts.contains(label['verdict'])) {
      problems.add('$stem.expected.json label verdict "${label['verdict']}" is '
          'not one of ${knownVerdicts.join(', ')}');
    }
    intervals.add((from: from.toInt(), to: to.toInt()));
  }

  intervals.sort((a, b) => a.from.compareTo(b.from));
  for (var i = 1; i < intervals.length; i++) {
    if (intervals[i].from < intervals[i - 1].to) {
      problems.add('$stem.expected.json labels overlap at ${intervals[i].from}ms');
    } else if (intervals[i].from > intervals[i - 1].to) {
      problems.add('$stem.expected.json has a label gap between '
          '${intervals[i - 1].to}ms and ${intervals[i].from}ms');
    }
  }

  for (final t in timestamps) {
    if (!intervals.any((i) => t >= i.from && t < i.to)) {
      problems.add('$stem.expected.json has no label covering the frame at ${t}ms');
      break;
    }
  }

  return problems;
}

/// Walks up from the working directory looking for `fixtures/`, so the script
/// runs from the repository root or from anywhere inside it.
String _findFixturesDir() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}/fixtures');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '${Directory.current.path}/fixtures';
}
