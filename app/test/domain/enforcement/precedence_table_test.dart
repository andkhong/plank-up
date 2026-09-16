/// The precedence ladder as a truth table, not as anecdotes.
///
/// `shouldBlock(app, now)` is specified once and implemented three times — Dart
/// here, Swift in the iOS extensions, Kotlin on Android — because a 6 MB
/// `DeviceActivityMonitor` extension cannot host a Dart VM. The design's answer
/// to "one source of truth where Dart is dead" is that you cannot share the
/// code, so you share the specification *and its tests*.
///
/// The existing tests check nine or ten interesting instants. That is useful
/// and it is not a conformance corpus: it does not enumerate the state space,
/// so it cannot be the artifact the Swift and Kotlin ports are held against.
/// This does — every combination of every input, each one decided by an
/// independent reading of the ladder rather than by calling the kernel.
///
/// The ladder, after the failure cooldown was cut:
///
/// 1. Master off, or the friction wait has elapsed  → allow (`off`)
/// 2. Nothing in the blocklist                      → allow (`unconfigured`)
/// 3. A live pass                                   → allow (`passActive`)
/// 4. Inside an enabled schedule window             → block (`wallUp`)
/// 5. Otherwise                                     → allow (`wallDown`)
///
/// Rule 3 outranking rule 4 is the entire product: an earned unlock beats a
/// scheduled window, or there was no point working for it.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/enforcement/enforcement_kernel.dart';
import 'package:plank_up/domain/schedule/block_schedule.dart';

/// 2026-09-16 is a Wednesday.
DateTime wed(int hour, [int minute = 0]) =>
    DateTime(2026, 9, 16, hour, minute);

final BlockSchedule workday = BlockSchedule(
  id: 'work',
  label: 'work',
  days: const {
    Weekday.monday,
    Weekday.tuesday,
    Weekday.wednesday,
    Weekday.thursday,
    Weekday.friday,
  },
  startMinuteOfDay: 9 * 60,
  endMinuteOfDay: 18 * 60,
);

enum GrantCase { none, live, expired }

enum DisableCase { none, pending, elapsed }

/// One row of the table.
class Row {
  Row({
    required this.masterEnabled,
    required this.blockedAppCount,
    required this.insideWindow,
    required this.grant,
    required this.disable,
  });

  final bool masterEnabled;
  final int blockedAppCount;
  final bool insideWindow;
  final GrantCase grant;
  final DisableCase disable;

  DateTime get now => insideWindow ? wed(12) : wed(20);

  EnforcementState get state => EnforcementState(
        masterEnabled: masterEnabled,
        schedules: [workday],
        blockedAppCount: blockedAppCount,
        activeGrant: switch (grant) {
          GrantCase.none => null,
          GrantCase.live => UnlockGrant(
              id: 'g',
              grantedAt: now.subtract(const Duration(minutes: 5)),
              expiresAt: now.add(const Duration(minutes: 10)),
              earnedFrom: 60,
            ),
          GrantCase.expired => UnlockGrant(
              id: 'g',
              grantedAt: now.subtract(const Duration(minutes: 30)),
              expiresAt: now.subtract(const Duration(minutes: 1)),
              earnedFrom: 60,
            ),
        },
        disableEffectiveAt: switch (disable) {
          DisableCase.none => null,
          DisableCase.pending => now.add(const Duration(minutes: 3)),
          DisableCase.elapsed => now.subtract(const Duration(minutes: 1)),
        },
      );

  /// The ladder, read straight off the specification.
  EnforcementMode get expectedMode {
    if (!masterEnabled || disable == DisableCase.elapsed) {
      return EnforcementMode.off;
    }
    if (blockedAppCount == 0) return EnforcementMode.unconfigured;
    if (grant == GrantCase.live) return EnforcementMode.passActive;
    if (insideWindow) return EnforcementMode.wallUp;
    return EnforcementMode.wallDown;
  }

  bool get expectedBlocking => expectedMode == EnforcementMode.wallUp;

  @override
  String toString() => 'master=$masterEnabled apps=$blockedAppCount '
      'window=$insideWindow grant=${grant.name} disable=${disable.name}';
}

List<Row> allRows() => [
      for (final masterEnabled in [true, false])
        for (final blockedAppCount in [0, 6])
          for (final insideWindow in [true, false])
            for (final grant in GrantCase.values)
              for (final disable in DisableCase.values)
                Row(
                  masterEnabled: masterEnabled,
                  blockedAppCount: blockedAppCount,
                  insideWindow: insideWindow,
                  grant: grant,
                  disable: disable,
                ),
    ];

void main() {
  const kernel = EnforcementKernel();
  final rows = allRows();

  group('the whole table', () {
    test('covers every combination exactly once', () {
      expect(rows, hasLength(2 * 2 * 2 * 3 * 3));
      expect(rows.map((r) => r.toString()).toSet(), hasLength(rows.length));
    });

    test('every row lands where the ladder says it does', () {
      final mismatches = <String>[];
      for (final row in rows) {
        final verdict = kernel.evaluate(row.state, row.now);
        if (verdict.mode != row.expectedMode ||
            verdict.blocking != row.expectedBlocking) {
          mismatches.add('$row -> ${verdict.mode.name}/${verdict.blocking}, '
              'expected ${row.expectedMode.name}/${row.expectedBlocking}');
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('every mode is actually reachable', () {
      final reached = {
        for (final row in rows) kernel.evaluate(row.state, row.now).mode,
      };
      expect(reached, containsAll(EnforcementMode.values));
    });

    test('canStartAttempt agrees with blocking on every row', () {
      // Working out while nothing is blocked would earn a pass against a wall
      // that is not there, which is how "earn 60 minutes at 08:00 for a window
      // that opens at 09:00" gets in.
      for (final row in rows) {
        expect(kernel.canStartAttempt(row.state, row.now),
            kernel.evaluate(row.state, row.now).blocking,
            reason: '$row');
      }
    });

    test('a live pass never leaves anything blocked', () {
      for (final row in rows.where((r) => r.grant == GrantCase.live)) {
        expect(kernel.evaluate(row.state, row.now).blocking, isFalse,
            reason: '$row');
      }
    });

    test('a live pass always refuses a fresh attempt', () {
      for (final row in rows.where((r) => r.grant == GrantCase.live)) {
        expect(kernel.canStartAttempt(row.state, row.now), isFalse,
            reason: '$row');
      }
    });

    test('an expired pass never changes the answer', () {
      // The only difference between "no grant" and "a grant that has run out"
      // must be nothing at all.
      for (final withNone in rows.where((r) => r.grant == GrantCase.none)) {
        final withExpired = Row(
          masterEnabled: withNone.masterEnabled,
          blockedAppCount: withNone.blockedAppCount,
          insideWindow: withNone.insideWindow,
          grant: GrantCase.expired,
          disable: withNone.disable,
        );
        expect(kernel.evaluate(withExpired.state, withExpired.now).mode,
            kernel.evaluate(withNone.state, withNone.now).mode,
            reason: '$withNone');
      }
    });

    test('a pending friction wait changes nothing until it elapses', () {
      for (final withNone in rows.where((r) => r.disable == DisableCase.none)) {
        final pending = Row(
          masterEnabled: withNone.masterEnabled,
          blockedAppCount: withNone.blockedAppCount,
          insideWindow: withNone.insideWindow,
          grant: withNone.grant,
          disable: DisableCase.pending,
        );
        expect(kernel.evaluate(pending.state, pending.now).mode,
            kernel.evaluate(withNone.state, withNone.now).mode,
            reason: '$withNone');
      }
    });

    test('an elapsed friction wait turns everything off regardless', () {
      for (final row in rows.where((r) => r.disable == DisableCase.elapsed)) {
        final verdict = kernel.evaluate(row.state, row.now);
        expect(verdict.mode, EnforcementMode.off, reason: '$row');
        expect(verdict.blocking, isFalse, reason: '$row');
      }
    });
  });

  group('verdict shape is consistent with its mode', () {
    test('only wallUp ever blocks', () {
      for (final row in rows) {
        final verdict = kernel.evaluate(row.state, row.now);
        expect(verdict.blocking, verdict.mode == EnforcementMode.wallUp,
            reason: '$row');
      }
    });

    test('passRemaining is present exactly when a pass is active', () {
      for (final row in rows) {
        final verdict = kernel.evaluate(row.state, row.now);
        expect(verdict.passRemaining != null,
            verdict.mode == EnforcementMode.passActive,
            reason: '$row');
        if (verdict.passRemaining != null) {
          expect(verdict.passRemaining, greaterThan(Duration.zero));
        }
      }
    });

    test('the wall underneath is still reported during a pass', () {
      // The UI has to be able to say what happens when the pass runs out.
      final row = Row(
        masterEnabled: true,
        blockedAppCount: 6,
        insideWindow: true,
        grant: GrantCase.live,
        disable: DisableCase.none,
      );
      final verdict = kernel.evaluate(row.state, row.now);
      expect(verdict.mode, EnforcementMode.passActive);
      expect(verdict.activeScheduleIds, ['work']);
    });

    test('schedule ids are only reported when a schedule is actually live', () {
      for (final row in rows) {
        final verdict = kernel.evaluate(row.state, row.now);
        if (verdict.activeScheduleIds.isNotEmpty) {
          expect(row.insideWindow, isTrue, reason: '$row');
          expect(verdict.mode,
              anyOf(EnforcementMode.wallUp, EnforcementMode.passActive),
              reason: '$row');
        }
      }
    });
  });

  group('boundaries', () {
    test('a pass expires at its instant, not a tick later', () {
      final state = EnforcementState(
        schedules: [workday],
        blockedAppCount: 6,
        activeGrant: UnlockGrant(
          id: 'g',
          grantedAt: wed(12),
          expiresAt: wed(12, 15),
          earnedFrom: 60,
        ),
      );
      expect(kernel.evaluate(state, wed(12, 14)).blocking, isFalse);
      expect(
          kernel
              .evaluate(
                  state, wed(12, 15).subtract(const Duration(microseconds: 1)))
              .blocking,
          isFalse);
      expect(kernel.evaluate(state, wed(12, 15)).blocking, isTrue);
    });

    test('the friction wait releases at its instant, inclusively', () {
      final state = EnforcementState(
        schedules: [workday],
        blockedAppCount: 6,
        disableEffectiveAt: wed(12, 5),
      );
      expect(
          kernel
              .evaluate(
                  state, wed(12, 5).subtract(const Duration(seconds: 1)))
              .blocking,
          isTrue);
      expect(kernel.evaluate(state, wed(12, 5)).mode, EnforcementMode.off);
    });

    test('a single blocked app is enough to be configured', () {
      final state =
          EnforcementState(schedules: [workday], blockedAppCount: 1);
      expect(state.hasBlocklist, isTrue);
      expect(kernel.evaluate(state, wed(12)).mode, EnforcementMode.wallUp);
      expect(
          EnforcementState(schedules: [workday]).hasBlocklist, isFalse);
    });
  });

  group('UnlockGrant', () {
    final grant = UnlockGrant(
      id: 'g',
      grantedAt: wed(12),
      expiresAt: wed(12, 15),
      earnedFrom: 60,
    );

    test('is live right up to but not including its expiry', () {
      expect(grant.isLiveAt(wed(12)), isTrue);
      expect(
          grant.isLiveAt(wed(12, 15).subtract(const Duration(microseconds: 1))),
          isTrue);
      expect(grant.isLiveAt(wed(12, 15)), isFalse);
      expect(grant.isLiveAt(wed(13)), isFalse);
    });

    test('remaining time counts down and then clamps at zero', () {
      expect(grant.remainingAt(wed(12)), const Duration(minutes: 15));
      expect(grant.remainingAt(wed(12, 10)), const Duration(minutes: 5));
      expect(grant.remainingAt(wed(12, 15)), Duration.zero);
      expect(grant.remainingAt(wed(20)), Duration.zero);
    });

    test('remaining time is never negative, at any instant', () {
      final random = Random(20260916);
      for (var i = 0; i < 2000; i++) {
        final now = wed(0).add(Duration(seconds: random.nextInt(86400)));
        expect(grant.remainingAt(now), greaterThanOrEqualTo(Duration.zero));
      }
    });

    test('records the effort that bought it', () {
      // Stored so a history screen can show what a window cost, and so a future
      // economy change does not retroactively rewrite past grants.
      expect(grant.earnedFrom, 60);
    });
  });

  group('EnforcementState.copyWith', () {
    final base = EnforcementState(
      schedules: [workday],
      blockedAppCount: 6,
      activeGrant: UnlockGrant(
        id: 'g',
        grantedAt: wed(12),
        expiresAt: wed(12, 15),
        earnedFrom: 60,
      ),
      disableEffectiveAt: wed(13),
    );

    test('with nothing changed it is an exact copy', () {
      final copy = base.copyWith();
      expect(copy.masterEnabled, base.masterEnabled);
      expect(copy.schedules, base.schedules);
      expect(copy.blockedAppCount, base.blockedAppCount);
      expect(copy.activeGrant, same(base.activeGrant));
      expect(copy.disableEffectiveAt, base.disableEffectiveAt);
    });

    test('passing null does NOT clear a grant', () {
      // The classic copyWith trap, and here it is the safe direction: a caller
      // who meant to clear and forgot leaves the user's earned pass intact
      // rather than silently revoking it.
      expect(base.copyWith(activeGrant: null).activeGrant,
          same(base.activeGrant));
      expect(base.copyWith(disableEffectiveAt: null).disableEffectiveAt,
          base.disableEffectiveAt);
    });

    test('clearing is explicit and works', () {
      expect(base.copyWith(clearGrant: true).activeGrant, isNull);
      expect(base.copyWith(clearDisable: true).disableEffectiveAt, isNull);
    });

    test('clearing one thing leaves the other alone', () {
      final cleared = base.copyWith(clearGrant: true);
      expect(cleared.activeGrant, isNull);
      expect(cleared.disableEffectiveAt, base.disableEffectiveAt);
      expect(cleared.blockedAppCount, 6);
    });

    test('clearing beats replacing when both are given', () {
      final replacement = UnlockGrant(
        id: 'other',
        grantedAt: wed(14),
        expiresAt: wed(15),
        earnedFrom: 90,
      );
      expect(
          base.copyWith(activeGrant: replacement, clearGrant: true).activeGrant,
          isNull);
    });

    test('cancelling a pending disable restores blocking', () {
      final pending = EnforcementState(
        schedules: [workday],
        blockedAppCount: 6,
        disableEffectiveAt: wed(11),
      );
      expect(kernel.evaluate(pending, wed(12)).mode, EnforcementMode.off);
      expect(
          kernel.evaluate(pending.copyWith(clearDisable: true), wed(12)).mode,
          EnforcementMode.wallUp);
    });
  });

  group('the kernel is total', () {
    test('it never throws, whatever it is handed', () {
      final random = Random(7);
      for (var i = 0; i < 3000; i++) {
        final scheduleCount = random.nextInt(4);
        final state = EnforcementState(
          masterEnabled: random.nextBool(),
          blockedAppCount: random.nextInt(60),
          schedules: [
            for (var s = 0; s < scheduleCount; s++)
              BlockSchedule(
                id: 's$s',
                label: 's$s',
                days: {
                  for (final day in Weekday.values)
                    if (random.nextBool()) day,
                },
                startMinuteOfDay: random.nextInt(1440),
                endMinuteOfDay: random.nextInt(1440),
                enabled: random.nextBool(),
              ),
          ],
          activeGrant: random.nextBool()
              ? UnlockGrant(
                  id: 'g',
                  grantedAt: wed(0).add(Duration(minutes: random.nextInt(2880))),
                  expiresAt: wed(0).add(Duration(minutes: random.nextInt(2880))),
                  earnedFrom: random.nextInt(120),
                )
              : null,
          disableEffectiveAt: random.nextBool()
              ? wed(0).add(Duration(minutes: random.nextInt(2880)))
              : null,
        );
        final now = wed(0).add(Duration(minutes: random.nextInt(2880)));

        final verdict = kernel.evaluate(state, now);
        expect(verdict.blocking, verdict.mode == EnforcementMode.wallUp);
        expect(verdict.activeScheduleIds.length,
            lessThanOrEqualTo(state.schedules.length));
      }
    });

    test('with no schedules at all the wall is simply down', () {
      const state = EnforcementState(blockedAppCount: 6);
      expect(kernel.evaluate(state, wed(12)).mode, EnforcementMode.wallDown);
      expect(kernel.canStartAttempt(state, wed(12)), isFalse);
    });

    test('a schedule list with duplicates reports each id it matched', () {
      final state = EnforcementState(
        schedules: [workday, workday],
        blockedAppCount: 6,
      );
      expect(kernel.evaluate(state, wed(12)).activeScheduleIds,
          ['work', 'work']);
    });
  });
}
