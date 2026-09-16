import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/enforcement/enforcement_kernel.dart';
import 'package:plank_up/domain/schedule/block_schedule.dart';

BlockSchedule schedule({
  String id = 'work',
  Set<Weekday> days = const {
    Weekday.monday,
    Weekday.tuesday,
    Weekday.wednesday,
    Weekday.thursday,
    Weekday.friday,
  },
  int start = 9 * 60,
  int end = 18 * 60,
  bool enabled = true,
}) =>
    BlockSchedule(
      id: id,
      label: id,
      days: days,
      startMinuteOfDay: start,
      endMinuteOfDay: end,
      enabled: enabled,
    );

/// 2026-09-16 is a Wednesday.
DateTime wed(int hour, [int minute = 0]) =>
    DateTime(2026, 9, 16, hour, minute);
DateTime sat(int hour, [int minute = 0]) =>
    DateTime(2026, 9, 19, hour, minute);
DateTime thu(int hour, [int minute = 0]) =>
    DateTime(2026, 9, 17, hour, minute);

void main() {
  const kernel = EnforcementKernel();

  group('weekday mapping', () {
    test('DateTime maps onto the Weekday enum', () {
      expect(wed(12).weekdayEnum, Weekday.wednesday);
      expect(sat(12).weekdayEnum, Weekday.saturday);
      expect(thu(12).weekdayEnum, Weekday.thursday);
    });
  });

  group('plain windows', () {
    final s = schedule();

    test('inside the window on a selected day', () {
      expect(s.containsLocal(wed(12)), isTrue);
    });

    test('start is inclusive, end is exclusive', () {
      expect(s.containsLocal(wed(9)), isTrue);
      expect(s.containsLocal(wed(18)), isFalse);
      expect(s.containsLocal(wed(17, 59)), isTrue);
    });

    test('outside the window on a selected day', () {
      expect(s.containsLocal(wed(8, 59)), isFalse);
      expect(s.containsLocal(wed(21)), isFalse);
    });

    test('correct hour on an unselected day', () {
      expect(s.containsLocal(sat(12)), isFalse);
    });

    test('a disabled schedule never contains anything', () {
      expect(schedule(enabled: false).containsLocal(wed(12)), isFalse);
    });
  });

  group('midnight-crossing windows', () {
    // Bedtime: every day 22:00 -> 07:00. The day mask refers to the day the
    // window STARTS, so Wednesday's window runs into Thursday morning.
    final bedtime = schedule(
      id: 'bedtime',
      days: Weekday.values.toSet(),
      start: 22 * 60,
      end: 7 * 60,
    );

    test('is detected as crossing midnight', () {
      expect(bedtime.crossesMidnight, isTrue);
      expect(schedule().crossesMidnight, isFalse);
    });

    test('evening portion is inside', () {
      expect(bedtime.containsLocal(wed(23)), isTrue);
      expect(bedtime.containsLocal(wed(22)), isTrue);
    });

    test('morning portion is inside', () {
      expect(bedtime.containsLocal(thu(2)), isTrue);
      expect(bedtime.containsLocal(thu(6, 59)), isTrue);
    });

    test('the gap between them is outside', () {
      expect(bedtime.containsLocal(wed(12)), isFalse);
      expect(bedtime.containsLocal(thu(7)), isFalse);
      expect(bedtime.containsLocal(wed(21, 59)), isFalse);
    });

    test('the morning portion belongs to the previous day mask', () {
      // Monday-only 22:00->07:00 should cover Tuesday morning, not Monday's.
      final mondayOnly = schedule(
        id: 'mon',
        days: {Weekday.monday},
        start: 22 * 60,
        end: 7 * 60,
      );
      final mondayNight = DateTime(2026, 9, 14, 23);
      final tuesdayMorning = DateTime(2026, 9, 15, 3);
      final mondayMorning = DateTime(2026, 9, 14, 3);

      expect(mondayOnly.containsLocal(mondayNight), isTrue);
      expect(mondayOnly.containsLocal(tuesdayMorning), isTrue);
      expect(mondayOnly.containsLocal(mondayMorning), isFalse);
    });

    test('duration accounts for the wrap', () {
      expect(bedtime.durationMinutes, 9 * 60);
      expect(schedule().durationMinutes, 9 * 60);
    });
  });

  group('validation', () {
    test('rejects a window shorter than the DeviceActivity floor', () {
      expect(schedule(start: 600, end: 610).isValid, isFalse);
      expect(schedule(start: 600, end: 615).isValid, isTrue);
    });

    test('rejects an empty day set', () {
      expect(schedule(days: const {}).isValid, isFalse);
    });

    test('rejects out-of-range minutes', () {
      expect(schedule(start: -1, end: 600).isValid, isFalse);
      expect(schedule(start: 600, end: 1440).isValid, isFalse);
    });
  });

  group('precedence', () {
    final state = EnforcementState(
      schedules: [schedule()],
      blockedAppCount: 6,
    );

    test('blocks inside a wall window', () {
      final verdict = kernel.evaluate(state, wed(12));
      expect(verdict.blocking, isTrue);
      expect(verdict.mode, EnforcementMode.wallUp);
      expect(verdict.activeScheduleIds, ['work']);
    });

    test('allows outside every window', () {
      final verdict = kernel.evaluate(state, wed(20));
      expect(verdict.blocking, isFalse);
      expect(verdict.mode, EnforcementMode.wallDown);
    });

    test('a live pass outranks the wall', () {
      final withGrant = state.copyWith(
        activeGrant: UnlockGrant(
          id: 'g1',
          grantedAt: wed(12),
          expiresAt: wed(12, 15),
          earnedFrom: 60,
        ),
      );
      final verdict = kernel.evaluate(withGrant, wed(12, 5));
      expect(verdict.blocking, isFalse);
      expect(verdict.mode, EnforcementMode.passActive);
      expect(verdict.passRemaining, const Duration(minutes: 10));
      // The wall is still noted underneath, so the UI can say what comes next.
      expect(verdict.activeScheduleIds, ['work']);
    });

    test('an expired pass stops outranking the wall', () {
      final withGrant = state.copyWith(
        activeGrant: UnlockGrant(
          id: 'g1',
          grantedAt: wed(12),
          expiresAt: wed(12, 15),
          earnedFrom: 60,
        ),
      );
      expect(kernel.evaluate(withGrant, wed(12, 15)).blocking, isTrue);
      expect(kernel.evaluate(withGrant, wed(12, 16)).blocking, isTrue);
    });

    test('a pass outliving the wall simply keeps the wall down', () {
      final withGrant = state.copyWith(
        activeGrant: UnlockGrant(
          id: 'g1',
          grantedAt: wed(17, 55),
          expiresAt: wed(18, 10),
          earnedFrom: 60,
        ),
      );
      expect(kernel.evaluate(withGrant, wed(18, 5)).blocking, isFalse);
      expect(kernel.evaluate(withGrant, wed(18, 5)).mode,
          EnforcementMode.passActive);
    });

    test('master off allows everything', () {
      final off = state.copyWith(masterEnabled: false);
      final verdict = kernel.evaluate(off, wed(12));
      expect(verdict.blocking, isFalse);
      expect(verdict.mode, EnforcementMode.off);
    });

    test('an empty blocklist is unconfigured, not blocking', () {
      final empty = state.copyWith(blockedAppCount: 0);
      expect(kernel.evaluate(empty, wed(12)).mode,
          EnforcementMode.unconfigured);
      expect(kernel.evaluate(empty, wed(12)).blocking, isFalse);
    });

    test('overlapping windows both report as active', () {
      final overlapping = state.copyWith(schedules: [
        schedule(id: 'work', start: 9 * 60, end: 18 * 60),
        schedule(id: 'focus', start: 11 * 60, end: 13 * 60),
      ]);
      final verdict = kernel.evaluate(overlapping, wed(12));
      expect(verdict.blocking, isTrue);
      expect(verdict.activeScheduleIds, containsAll(['work', 'focus']));
    });

    test('a disabled schedule does not hold the wall up alone', () {
      final disabled =
          state.copyWith(schedules: [schedule(enabled: false)]);
      expect(kernel.evaluate(disabled, wed(12)).blocking, isFalse);
    });
  });

  group('pending disable', () {
    final state = EnforcementState(
      schedules: [schedule()],
      blockedAppCount: 6,
      disableEffectiveAt: wed(12, 5),
    );

    test('keeps blocking until the wait elapses', () {
      expect(kernel.evaluate(state, wed(12)).blocking, isTrue);
      expect(kernel.evaluate(state, wed(12, 4, )).blocking, isTrue);
    });

    test('releases once the wait has passed', () {
      expect(kernel.evaluate(state, wed(12, 5)).blocking, isFalse);
      expect(kernel.evaluate(state, wed(12, 6)).mode, EnforcementMode.off);
    });
  });

  group('canStartAttempt', () {
    final state = EnforcementState(
      schedules: [schedule()],
      blockedAppCount: 6,
    );

    test('allowed only while something is actually blocked', () {
      expect(kernel.canStartAttempt(state, wed(12)), isTrue);
      expect(kernel.canStartAttempt(state, wed(20)), isFalse);
    });

    test('refused during an active pass, since nothing is blocked', () {
      final withGrant = state.copyWith(
        activeGrant: UnlockGrant(
          id: 'g1',
          grantedAt: wed(12),
          expiresAt: wed(12, 15),
          earnedFrom: 60,
        ),
      );
      expect(kernel.canStartAttempt(withGrant, wed(12, 5)), isFalse);
    });

    test('refused when blocking is off entirely', () {
      expect(
          kernel.canStartAttempt(state.copyWith(masterEnabled: false), wed(12)),
          isFalse);
    });
  });
}
