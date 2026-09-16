/// The domain-purity guard.
///
/// `lib/domain/` is the correctness core: unlock economy, enforcement
/// precedence, schedules, the session machine. Its whole value is that it runs
/// in milliseconds with no device, no camera and no Screen Time entitlement.
/// One `package:flutter` import or one `DateTime.now()` takes that away, and it
/// happens by accident — someone reaches for `Duration` and their IDE offers
/// `package:flutter/material.dart`, or someone needs "now" and Dart hands it to
/// them ambiently.
///
/// So this is a test that fails CI, not a convention people remember.
///
/// It checks four rules, each of which is load-bearing for a different reason:
///
/// 1. **No Flutter, no plugins.** Keeps the core runnable as plain Dart and
///    keeps the evaluators fixture-testable rather than device-testable.
/// 2. **No ambient time.** `DateTime.now()`, `DateTime.timestamp()`, `Timer`,
///    `Stopwatch` and `Future.delayed` all read a clock the caller did not
///    supply. Session timing comes from native frame timestamps; that is what
///    makes pipeline latency and UI jank mathematically irrelevant to what a
///    user is credited with.
/// 3. **No ambient I/O.** `dart:io`, `dart:ui`, `dart:ffi` and friends are
///    platform surfaces; a pure core has none.
/// 4. **`lib/` never imports `test/`.** The design names test infrastructure as
///    an attack surface: a debug clock shipped in the release binary is a
///    one-tap infinite unlock and the cheapest bypass in the product. This is
///    the cheap half of that check — the other half belongs on the release
///    artifact.
///
/// Violations are reported with file and line, all at once, because fixing them
/// one CI run at a time is how a guard becomes something people disable.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `dart:` libraries the domain may use. Everything here is pure computation.
const _allowedDartLibraries = {
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:core',
  'dart:math',
  'dart:typed_data',
};

/// Banned outright, with the reason shown in the failure.
const _bannedImportReasons = {
  'dart:io': 'platform I/O — the core must run anywhere, including a browser',
  'dart:ui': 'Flutter engine binding',
  'dart:ffi': 'native binding',
  'dart:isolate': 'concurrency primitive; the core is synchronous and pure',
  'dart:html': 'browser binding',
  'dart:js': 'browser binding',
  'dart:js_interop': 'browser binding',
  'dart:mirrors': 'reflection',
};

/// Identifiers that read a clock nobody injected.
final _ambientTimePatterns = <({RegExp pattern, String reason})>[
  (
    pattern: RegExp(r'\bDateTime\s*\.\s*now\s*\('),
    reason: 'DateTime.now() — take the instant as a parameter instead',
  ),
  (
    pattern: RegExp(r'\bDateTime\s*\.\s*timestamp\s*\('),
    reason: 'DateTime.timestamp() — same ambient clock, different spelling',
  ),
  (
    pattern: RegExp(r'\bStopwatch\s*\('),
    reason: 'Stopwatch — session timing comes from native frame timestamps',
  ),
  (
    pattern: RegExp(r'\bTimer\s*(\.\s*periodic\s*)?\('),
    reason: 'Timer — a Dart timer makes scoring vulnerable to UI-thread jank',
  ),
  (
    pattern: RegExp(r'\bFuture\s*\.\s*delayed\s*\('),
    reason: 'Future.delayed — ambient wall time',
  ),
];

final _importPattern =
    RegExp(r'''^\s*(?:import|export)\s+(?:'([^']+)'|"([^"]+)")''', multiLine: true);

void main() {
  final packageRoot = _findPackageRoot();
  final domain = Directory('${packageRoot.path}/lib/domain');
  final lib = Directory('${packageRoot.path}/lib');

  test('lib/domain exists and is not empty', () {
    expect(domain.existsSync(), isTrue,
        reason: 'the guard is pointed at ${domain.path}, which does not exist');
    expect(_dartFilesIn(domain), isNotEmpty);
  });

  test('lib/domain imports no Flutter and no plugins', () {
    final violations = auditImports(domain, packageRoot);
    expect(violations, isEmpty, reason: _report('purity', violations));
  });

  test('lib/domain reads no ambient clock', () {
    final violations = auditAmbientTime(domain, packageRoot);
    expect(violations, isEmpty, reason: _report('ambient time', violations));
  });

  group('the guard actually catches what it claims to', () {
    // A guard nobody has seen fail is a guard nobody knows works, and this one
    // is only ever exercised in the passing direction. So: build a throwaway
    // domain tree containing the exact things the rules exist to reject, and
    // run the real audit over it.
    late Directory root;
    late Directory fakeDomain;

    setUp(() {
      root = Directory.systemTemp.createTempSync('plankup_purity');
      fakeDomain = Directory('${root.path}/lib/domain/session')
        ..createSync(recursive: true);
    });

    tearDown(() => root.deleteSync(recursive: true));

    void writeDomainFile(String name, String source) =>
        File('${fakeDomain.path}/$name').writeAsStringSync(source);

    Directory domainRoot() => Directory('${root.path}/lib/domain');

    test('a Flutter import is caught', () {
      writeDomainFile('bad.dart', "import 'package:flutter/material.dart';\n");
      expect(auditImports(domainRoot(), root), hasLength(1));
      expect(auditImports(domainRoot(), root).single, contains('flutter'));
    });

    test('a plugin import is caught', () {
      writeDomainFile('bad.dart', "import 'package:camera/camera.dart';\n");
      expect(auditImports(domainRoot(), root), hasLength(1));
    });

    test('dart:io is caught', () {
      writeDomainFile('bad.dart', "import 'dart:io';\n");
      expect(auditImports(domainRoot(), root).single, contains('dart:io'));
    });

    test('a relative import escaping the core is caught', () {
      writeDomainFile('bad.dart', "import '../../services/camera.dart';\n");
      expect(auditImports(domainRoot(), root).single,
          contains('resolves outside lib/domain'));
    });

    test('relative imports inside the core are allowed', () {
      Directory('${root.path}/lib/domain/pose').createSync(recursive: true);
      File('${root.path}/lib/domain/pose/pose_frame.dart').writeAsStringSync('');
      writeDomainFile('ok.dart',
          "import '../pose/pose_frame.dart';\nimport 'dart:math';\n");
      expect(auditImports(domainRoot(), root), isEmpty);
    });

    test('each ambient clock is caught', () {
      writeDomainFile('bad.dart', '''
final a = DateTime.now();
final b = DateTime.timestamp();
final c = Stopwatch();
void d() => Timer.periodic(Duration.zero, (_) {});
final e = Future.delayed(Duration.zero);
''');
      expect(auditAmbientTime(domainRoot(), root), hasLength(5));
    });

    test('the rule may be discussed in comments and strings', () {
      // Every domain file already does this — the doc comments say
      // "no DateTime.now()" — so a naive grep would fail on a clean tree.
      writeDomainFile('ok.dart', '''
/// Never call DateTime.now() in here.
/* Stopwatch() is banned too. */
const help = 'use DateTime.now() nowhere';
const more = "Timer( is fine inside a string";
''');
      expect(auditAmbientTime(domainRoot(), root), isEmpty);
    });

    test('violations are reported with the right line number', () {
      writeDomainFile('bad.dart', '''
// line 1
/// line 2
final t = DateTime.now();
''');
      expect(auditAmbientTime(domainRoot(), root).single, contains(':3 '));
    });
  });

  test('lib never imports test scaffolding', () {
    // A debug clock or a fixture loader reachable from the release binary is
    // the cheapest bypass in the product.
    final violations = <String>[];

    for (final file in _dartFilesIn(lib)) {
      final relative = _relative(file, packageRoot);
      final source = file.readAsStringSync();
      for (final match in _importPattern.allMatches(source)) {
        final uri = match.group(1) ?? match.group(2)!;
        if (uri.contains('test/') ||
            uri.startsWith('package:flutter_test') ||
            uri.startsWith('package:test')) {
          violations
              .add('$relative:${_lineOf(source, match.start)} imports $uri');
        }
      }
    }

    expect(violations, isEmpty,
        reason: _report('test code reachable from lib/', violations));
  });
}

/// Every import in [domain] that the core is not allowed to have, reported as
/// `path:line reason`. [root] is the package root, used only to shorten paths.
List<String> auditImports(Directory domain, Directory root) {
  final violations = <String>[];
  final domainPath = domain.absolute.path;

  for (final file in _dartFilesIn(domain)) {
    final relative = _relative(file, root);
    final source = file.readAsStringSync();

    for (final match in _importPattern.allMatches(source)) {
      final uri = match.group(1) ?? match.group(2)!;
      final line = _lineOf(source, match.start);

      if (uri.startsWith('dart:')) {
        final banned = _bannedImportReasons[uri];
        if (banned != null) {
          violations.add('$relative:$line imports $uri ($banned)');
        } else if (!_allowedDartLibraries.contains(uri)) {
          violations.add('$relative:$line imports $uri, which is not on the '
              'allow-list ${_allowedDartLibraries.toList()..sort()}');
        }
        continue;
      }

      if (uri.startsWith('package:')) {
        // Self-imports are fine; anything else is a dependency the core is not
        // allowed to have.
        if (!uri.startsWith('package:plank_up/domain/')) {
          violations.add('$relative:$line imports $uri — lib/domain takes no '
              'package dependencies, only relative imports within the core');
        }
        continue;
      }

      // A relative import must resolve to somewhere still inside the core.
      // `../pose/pose_frame.dart` is fine; `../../services/camera.dart` is how
      // the boundary leaks.
      final resolved =
          File(file.parent.uri.resolve(uri).toFilePath()).absolute.path;
      if (!resolved.startsWith('$domainPath/')) {
        violations.add(
            '$relative:$line imports $uri, which resolves outside lib/domain');
      }
    }
  }

  return violations;
}

/// Every ambient-clock read in [domain]. Comments and string literals are
/// stripped first, so the rule can be discussed in a doc comment without
/// tripping itself — which every domain file already does.
List<String> auditAmbientTime(Directory domain, Directory root) {
  final violations = <String>[];

  for (final file in _dartFilesIn(domain)) {
    final relative = _relative(file, root);
    final source = _stripCommentsAndStrings(file.readAsStringSync());

    for (final rule in _ambientTimePatterns) {
      for (final match in rule.pattern.allMatches(source)) {
        violations
            .add('$relative:${_lineOf(source, match.start)} uses ${rule.reason}');
      }
    }
  }

  return violations;
}

String _report(String kind, List<String> violations) =>
    'lib/domain/ must stay pure. ${violations.length} $kind violation(s):\n'
    '${violations.map((v) => '  - $v').join('\n')}';

List<File> _dartFilesIn(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

String _relative(File file, Directory root) =>
    file.path.startsWith(root.path)
        ? file.path.substring(root.path.length + 1)
        : file.path;

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// Replaces comment and string content with spaces, preserving offsets so line
/// numbers stay accurate.
String _stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;

  void blank(int count) {
    for (var n = 0; n < count; n++) {
      out.write(' ');
    }
  }

  while (i < source.length) {
    final rest = source.length - i;

    if (rest >= 2 && source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      final stop = end == -1 ? source.length : end;
      blank(stop - i);
      i = stop;
      continue;
    }

    if (rest >= 2 && source.startsWith('/*', i)) {
      var depth = 0;
      final start = i;
      while (i < source.length) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) break;
        } else {
          i++;
        }
      }
      blank(i - start);
      continue;
    }

    final quote = _quoteAt(source, i);
    if (quote != null) {
      final start = i;
      i += quote.length;
      while (i < source.length) {
        if (source[i] == r'\') {
          i += 2;
          continue;
        }
        if (source.startsWith(quote, i)) {
          i += quote.length;
          break;
        }
        i++;
      }
      if (i > source.length) i = source.length;
      for (var n = start; n < i; n++) {
        out.write(source[n] == '\n' ? '\n' : ' ');
      }
      continue;
    }

    out.write(source[i]);
    i++;
  }

  return out.toString();
}

/// Returns the opening delimiter of a string literal at [i], longest first so
/// triple quotes win over single ones.
String? _quoteAt(String source, int i) {
  for (final quote in const ["'''", '"""', "'", '"']) {
    if (source.startsWith(quote, i)) return quote;
  }
  return null;
}

Directory _findPackageRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib/domain').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('no Flutter package with lib/domain found above '
      '${Directory.current.path}');
}
