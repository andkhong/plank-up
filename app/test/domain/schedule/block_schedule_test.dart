/// `BlockSchedule` on its own terms.
///
/// The existing coverage for this class is incidental — it lives inside
/// `enforcement_kernel_test.dart` and exercises the handful of instants someone
/// thought of. That is exactly the shape of testing that misses wrap-around
/// bugs, because a midnight-crossing window has 10,080 interesting instants a
/// week and a person picks six of them.
///
/// So the central test here is an exhaustive week sweep against an independent
/// model of what the window *means*. Every minute of every day, both ways.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/schedule/block_schedule.dart';

const int _minutesPerWeek = 7 * BlockSchedule.minutesPerDay;

/// Monday 2026-09-14 at 00:00. UTC so the sweep is unaffected by whatever
/// timezone CI happens to run in, and so no DST transition can appear inside a
/// week and quietly change the arithmetic.
final DateTime weekStart = DateTime.utc(2026, 9, 14);

DateTime atMinuteOfWeek(int minute) =>
    weekStart.add(Duration(minutes: minute));

/// What the window covers, derived from the definition rather than from the
/// implementation: for each selected day, the window starts at that day's
/// `start` and runs for `durationMinutes`, wrapping into the next day.
Set<int> coveredMinutes(BlockSchedule schedule) {
  if (!schedule.enabled) return const {};
  final covered = <int>{};
  for (var day = 0; day < Weekday.values.length; day++) {
    if (!schedule.days.contains(Weekday.values[day])) continue;
    final from = day * BlockSchedule.minutesPerDay + schedule.startMinuteOfDay;
    for (var k = 0; k < schedule.durationMinutes; k++) {
      covered.add((from + k) % _minutesPerWeek);
    }
  }
  return covered;
}

void sweepWeek(BlockSchedule schedule, {required String label}) {
  final expected = coveredMinutes(schedule);
  final disagreements = <int>[];

  for (var minute = 0; minute < _minutesPerWeek; minute++) {
    final actual = schedule.containsLocal(atMinuteOfWeek(minute));
    if (actual != expected.contains(minute)) disagreements.add(minute);
  }

  expect(disagreements, isEmpty,
      reason: '$label disagrees with the model at ${disagreements.length} '
          'minute(s), first at ${disagreements.isEmpty ? '-' : _describe(disagreements.first)}');
}

String _describe(int minuteOfWeek) {
  final day = Weekday.values[minuteOfWeek ~/ BlockSchedule.minutesPerDay];
  final inDay = minuteOfWeek % BlockSchedule.minutesPerDay;
  return '${day.name} '
      '${(inDay ~/ 60).toString().padLeft(2, '0')}:'
      '${(inDay % 60).toString().padLeft(2, '0')}';
}

BlockSchedule schedule({
  String id = 's',
  Set<Weekday> days = const {Weekday.monday},
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

void main() {
  group('the week, minute by minute', () {
    test('a plain weekday window', () {
      sweepWeek(
        schedule(days: const {
          Weekday.monday,
          Weekday.tuesday,
          Weekday.wednesday,
          Weekday.thursday,
          Weekday.friday,
        }),
        label: 'weekday 09:00-18:00',
      );
    });

    test('a bedtime window crossing midnight every day', () {
      sweepWeek(
        schedule(days: Weekday.values.toSet(), start: 22 * 60, end: 7 * 60),
        label: 'nightly 22:00-07:00',
      );
    });

    test('a single-day window crossing midnight', () {
      // The case where the day mask and the covered minutes belong to
      // different days, which is where a naive implementation breaks.
      sweepWeek(
        schedule(days: const {Weekday.sunday}, start: 23 * 60, end: 2 * 60),
        label: 'Sunday 23:00-02:00',
      );
    });

    test('a window crossing the week boundary', () {
      // Sunday night wraps into Monday, i.e. index 6 wraps to index 0.
      sweepWeek(
        schedule(days: const {Weekday.sunday}, start: 23 * 60 + 30, end: 30),
        label: 'Sunday 23:30-00:30',
      );
    });

    test('a window that is exactly the minimum length', () {
      sweepWeek(
        schedule(days: const {Weekday.wednesday}, start: 720, end: 735),
        label: '15 minutes on Wednesday',
      );
    });

    test('a window starting at midnight', () {
      sweepWeek(
        schedule(days: const {Weekday.friday}, start: 0, end: 60),
        label: 'Friday 00:00-01:00',
      );
    });

    test('a window ending at the last minute of the day', () {
      sweepWeek(
        schedule(days: const {Weekday.friday}, start: 23 * 60, end: 1439),
        label: 'Friday 23:00-23:59',
      );
    });

    test('every single-day window on every day', () {
      for (final day in Weekday.values) {
        sweepWeek(schedule(days: {day}, start: 8 * 60, end: 9 * 60),
            label: '${day.name} 08:00-09:00');
      }
    });

    test('a disabled schedule covers nothing at all', () {
      sweepWeek(
        schedule(days: Weekday.values.toSet(), start: 0, end: 1439, enabled: false),
        label: 'disabled',
      );
    });
  });

  group('start == end means all day', () {
    // Worth pinning either way, because it is surprising: the window is not
    // empty, it is twenty-four hours. A schedule editor that lets a user set
    // both ends to 09:00 hands them a full-day block.
    final allDay = schedule(days: const {Weekday.monday}, start: 9 * 60, end: 9 * 60);

    test('it is treated as crossing midnight', () {
      expect(allDay.crossesMidnight, isTrue);
    });

    test('its duration is a full day', () {
      expect(allDay.durationMinutes, BlockSchedule.minutesPerDay);
    });

    test('it is valid, so the editor is the thing that has to refuse it', () {
      expect(allDay.isValid, isTrue);
    });

    test('it covers Monday 09:00 through Tuesday 09:00 and nothing else', () {
      sweepWeek(allDay, label: 'Monday all-day from 09:00');
      expect(allDay.containsLocal(DateTime.utc(2026, 9, 14, 9)), isTrue);
      expect(allDay.containsLocal(DateTime.utc(2026, 9, 15, 8, 59)), isTrue);
      expect(allDay.containsLocal(DateTime.utc(2026, 9, 15, 9)), isFalse);
      expect(allDay.containsLocal(DateTime.utc(2026, 9, 14, 8, 59)), isFalse);
    });
  });

  group('validation', () {
    test('a midnight-crossing window can still be too short', () {
      // 23:50 -> 00:00 is ten minutes, and the wrap arithmetic must not hide it.
      expect(schedule(start: 23 * 60 + 50, end: 0).isValid, isFalse);
      expect(schedule(start: 23 * 60 + 45, end: 0).isValid, isTrue);
    });

    test('the floor is the DeviceActivity floor, not an arbitrary number', () {
      // `DeviceActivitySchedule` cannot reliably fire an interval shorter than
      // fifteen minutes, so this constant is a platform fact.
      expect(BlockSchedule.minimumWindowMinutes, 15);
      expect(schedule(start: 600, end: 614).isValid, isFalse);
      expect(schedule(start: 600, end: 615).isValid, isTrue);
    });

    test('the schedule cap leaves DeviceActivity slots for unlock chaining', () {
      // iOS caps concurrent monitoring at 20 and chained unlock segments
      // consume several of them.
      expect(BlockSchedule.maxSchedules, lessThan(20));
    });

    test('minute bounds are half-open at the top of the day', () {
      expect(schedule(start: 0, end: 600).isValid, isTrue);
      expect(schedule(start: 1439, end: 1430).isValid, isTrue);
      expect(schedule(start: 1440, end: 600).isValid, isFalse);
      expect(schedule(start: 600, end: 1440).isValid, isFalse);
      expect(schedule(start: -1, end: 600).isValid, isFalse);
      expect(schedule(start: 600, end: -1).isValid, isFalse);
    });

    test('a schedule with no days is invalid however long it is', () {
      expect(schedule(days: const {}, start: 0, end: 1200).isValid, isFalse);
    });

    test('validity is independent of enabled', () {
      // A user switching a schedule off must not make an invalid one look fine.
      expect(schedule(start: 600, end: 605, enabled: false).isValid, isFalse);
      expect(schedule(start: 600, end: 900, enabled: false).isValid, isTrue);
    });
  });

  group('weekday mapping', () {
    test('every day of a full week maps to the right enum value', () {
      const expected = [
        Weekday.monday,
        Weekday.tuesday,
        Weekday.wednesday,
        Weekday.thursday,
        Weekday.friday,
        Weekday.saturday,
        Weekday.sunday,
      ];
      for (var i = 0; i < 7; i++) {
        expect(weekStart.add(Duration(days: i)).weekdayEnum, expected[i],
            reason: 'day $i');
      }
    });

    test('the enum is ordered so that index 0 is Monday', () {
      // `containsLocal` steps backwards through this list to find "yesterday",
      // so the ordering is load-bearing rather than cosmetic.
      expect(Weekday.values.first, Weekday.monday);
      expect(Weekday.values.last, Weekday.sunday);
    });
  });

  group('copyWith', () {
    final original = schedule(
      id: 'work',
      days: const {Weekday.monday, Weekday.friday},
      start: 9 * 60,
      end: 17 * 60,
    );

    test('with nothing changed it is an exact copy', () {
      final copy = original.copyWith();
      expect(copy.id, original.id);
      expect(copy.label, original.label);
      expect(copy.days, original.days);
      expect(copy.startMinuteOfDay, original.startMinuteOfDay);
      expect(copy.endMinuteOfDay, original.endMinuteOfDay);
      expect(copy.enabled, original.enabled);
    });

    test('the id is never copied over', () {
      // Ring 0 keys off the id, and a rename that silently changed it would
      // orphan the native side's monitoring registration.
      expect(original.copyWith(label: 'Deep work').id, 'work');
      expect(original.copyWith(label: 'Deep work').label, 'Deep work');
    });

    test('each field can be replaced independently', () {
      expect(original.copyWith(days: const {Weekday.sunday}).days,
          const {Weekday.sunday});
      expect(original.copyWith(startMinuteOfDay: 60).startMinuteOfDay, 60);
      expect(original.copyWith(endMinuteOfDay: 120).endMinuteOfDay, 120);
      expect(original.copyWith(enabled: false).enabled, isFalse);
      expect(original.copyWith(enabled: false).startMinuteOfDay,
          original.startMinuteOfDay);
    });

    test('toggling enabled changes coverage and nothing else', () {
      final off = original.copyWith(enabled: false);
      expect(off.durationMinutes, original.durationMinutes);
      expect(off.isValid, original.isValid);
      sweepWeek(off, label: 'disabled copy');
    });
  });

  group('durations', () {
    test('a plain window is end minus start', () {
      expect(schedule(start: 9 * 60, end: 18 * 60).durationMinutes, 9 * 60);
    });

    test('a wrapping window counts through midnight', () {
      expect(schedule(start: 22 * 60, end: 7 * 60).durationMinutes, 9 * 60);
    });

    test('duration always matches the minutes actually covered', () {
      for (final start in [0, 1, 600, 1380, 1439]) {
        for (final end in [0, 30, 600, 1439]) {
          final s = schedule(days: const {Weekday.monday}, start: start, end: end);
          expect(coveredMinutes(s), hasLength(s.durationMinutes),
              reason: 'start=$start end=$end');
        }
      }
    });
  });
}
