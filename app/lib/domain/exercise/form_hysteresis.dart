/// Temporal debouncing shared by every evaluator.
///
/// Bare thresholds flicker at the boundary. A user holding a plank right on 12°
/// would get a cue, lose it, get it again, several times a second, and conclude
/// the app is broken — and they would be right. So no evaluator ever emits a
/// state change from a single frame.
///
/// The rule the design specifies: enter a worse state on **4 of the last 6**
/// frames (~270 ms at 15 Hz), and return to a better one only on **3
/// consecutive** frames judged against a **tighter release threshold**.
/// Asymmetric on purpose — slow to accuse, slow to forgive, and never
/// oscillating between the two.
library;

import 'dart:math' as math;

/// Ordered severity. The ladder works on the indices, so the declaration order
/// is load-bearing: worse states must sort higher.
enum FormLevel {
  /// Inside tolerance. The clock runs.
  good,

  /// Outside tolerance but still recognisably the exercise. The user gets a
  /// cue; the clock keeps running.
  degraded,

  /// Far enough out that we stop crediting. The session machine pauses here.
  broken,

  /// Not attempting the exercise any more.
  outOfPosition,
}

/// Entry and release thresholds for one measured quantity, in degrees.
class FormBands {
  const FormBands({
    required this.degradedAt,
    required this.brokenAt,
    required this.releaseAt,
  });

  /// Above this magnitude the frame reads as degraded. `good ≤ degradedAt`.
  final double degradedAt;

  /// Above this magnitude the frame reads as broken.
  final double brokenAt;

  /// The tighter threshold a frame must clear to count toward returning to
  /// good. The gap between this and [degradedAt] is the whole anti-oscillation
  /// margin.
  final double releaseAt;

  /// The same margin applied to the broken boundary, so leaving broken is as
  /// deliberate as leaving degraded.
  double get brokenReleaseAt => brokenAt - (degradedAt - releaseAt);

  /// Severity of one frame under the entry thresholds.
  int entryLevel(double magnitude) {
    if (!magnitude.isFinite) return FormLevel.good.index;
    if (magnitude > brokenAt) return FormLevel.broken.index;
    if (magnitude > degradedAt) return FormLevel.degraded.index;
    return FormLevel.good.index;
  }

  /// Severity of one frame under the tighter release thresholds. Always at
  /// least [entryLevel], since the release thresholds sit lower.
  int releaseLevel(double magnitude) {
    if (!magnitude.isFinite) return FormLevel.good.index;
    if (magnitude > brokenReleaseAt) return FormLevel.broken.index;
    if (magnitude > releaseAt) return FormLevel.degraded.index;
    return FormLevel.good.index;
  }
}

/// A monotone-ish debouncer over [FormLevel] indices.
class HysteresisLadder {
  HysteresisLadder({
    this.levels = 4,
    this.window = 6,
    this.votesToEscalate = 4,
    this.framesToRelease = 3,
  });

  final int levels;
  final int window;
  final int votesToEscalate;
  final int framesToRelease;

  final List<int> _recent = <int>[];
  int _level = 0;
  int _releaseStreak = 0;
  int _releaseCeiling = 0;

  int get level => _level;

  int get windowLength => _recent.length;

  void reset() {
    _recent.clear();
    _level = 0;
    _releaseStreak = 0;
    _releaseCeiling = 0;
  }

  /// Call for a frame that could not be judged.
  ///
  /// The voting window is *held* rather than fed: a frame we could not read is
  /// evidence of nothing, and in particular it is not evidence of bad form.
  /// Feeding it in either direction would let a tracking dropout manufacture a
  /// verdict. The release streak does reset, because forgiveness should rest on
  /// frames we actually saw.
  void hold() {
    _releaseStreak = 0;
    _releaseCeiling = 0;
  }

  /// Feeds one judged frame and returns the debounced level.
  ///
  /// [observed] is the frame's severity under the entry thresholds; [release]
  /// is its severity under the tighter release thresholds.
  int update({required int observed, required int release}) {
    final obs = observed.clamp(0, levels - 1);
    final rel = release.clamp(obs, levels - 1);

    _recent.add(obs);
    while (_recent.length > window) {
      _recent.removeAt(0);
    }

    // Escalate to the worst level that 4 of the last 6 frames support. Checking
    // downward from the top lets a genuinely sudden collapse jump straight past
    // degraded instead of climbing one rung per window.
    for (var candidate = levels - 1; candidate > _level; candidate--) {
      final votes = _recent.where((l) => l >= candidate).length;
      if (votes >= votesToEscalate) {
        _level = candidate;
        _releaseStreak = 0;
        _releaseCeiling = 0;
        return _level;
      }
    }

    if (rel < _level) {
      _releaseStreak++;
      _releaseCeiling = math.max(_releaseCeiling, rel);
      if (_releaseStreak >= framesToRelease) {
        _level = _releaseCeiling;
        _releaseStreak = 0;
        _releaseCeiling = 0;
      }
    } else {
      _releaseStreak = 0;
      _releaseCeiling = 0;
    }
    return _level;
  }
}
