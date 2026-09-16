/// A recurring window during which the blocklist is enforced — "the Wall".
library;

enum Weekday { monday, tuesday, wednesday, thursday, friday, saturday, sunday }

extension WeekdayFromDateTime on DateTime {
  Weekday get weekdayEnum => Weekday.values[weekday - 1];
}

class BlockSchedule {
  const BlockSchedule({
    required this.id,
    required this.label,
    required this.days,
    required this.startMinuteOfDay,
    required this.endMinuteOfDay,
    this.enabled = true,
  });

  final String id;
  final String label;
  final Set<Weekday> days;
  final int startMinuteOfDay;
  final int endMinuteOfDay;
  final bool enabled;

  /// `DeviceActivitySchedule` cannot reliably fire an interval shorter than
  /// this, so the editor must refuse to save one.
  static const int minimumWindowMinutes = 15;

  /// iOS caps concurrent DeviceActivity monitoring at 20, and unlock-window
  /// chaining reserves several slots.
  static const int maxSchedules = 15;

  static const int minutesPerDay = 1440;

  /// A window whose end is at or before its start runs past midnight into the
  /// following day. The day mask always refers to the day the window *starts*.
  bool get crossesMidnight => endMinuteOfDay <= startMinuteOfDay;

  int get durationMinutes => crossesMidnight
      ? minutesPerDay - startMinuteOfDay + endMinuteOfDay
      : endMinuteOfDay - startMinuteOfDay;

  bool get isValid =>
      days.isNotEmpty &&
      startMinuteOfDay >= 0 &&
      startMinuteOfDay < minutesPerDay &&
      endMinuteOfDay >= 0 &&
      endMinuteOfDay < minutesPerDay &&
      durationMinutes >= minimumWindowMinutes;

  bool containsLocal(DateTime now) {
    if (!enabled) return false;

    final minuteOfDay = now.hour * 60 + now.minute;
    final today = now.weekdayEnum;

    if (!crossesMidnight) {
      return days.contains(today) &&
          minuteOfDay >= startMinuteOfDay &&
          minuteOfDay < endMinuteOfDay;
    }

    if (days.contains(today) && minuteOfDay >= startMinuteOfDay) return true;

    final yesterday =
        Weekday.values[(today.index + Weekday.values.length - 1) % Weekday.values.length];
    return days.contains(yesterday) && minuteOfDay < endMinuteOfDay;
  }

  BlockSchedule copyWith({
    String? label,
    Set<Weekday>? days,
    int? startMinuteOfDay,
    int? endMinuteOfDay,
    bool? enabled,
  }) =>
      BlockSchedule(
        id: id,
        label: label ?? this.label,
        days: days ?? this.days,
        startMinuteOfDay: startMinuteOfDay ?? this.startMinuteOfDay,
        endMinuteOfDay: endMinuteOfDay ?? this.endMinuteOfDay,
        enabled: enabled ?? this.enabled,
      );
}
