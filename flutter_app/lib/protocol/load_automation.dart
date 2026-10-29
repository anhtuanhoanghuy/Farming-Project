/// Pure helpers for the weekly schedule: the protocol stores UTC times and a
/// `days_mask` (Monday = bit 0), the screen edits phone-local times and days.
abstract final class LoadAutomation {
  /// Days of a `days_mask` as 1 = Monday ... 7 = Sunday.
  static List<int> daysFromMask(int mask) => [
    for (var bit = 0; bit < 7; bit++)
      if (mask & (1 << bit) != 0) bit + 1,
  ];

  static int maskFromDays(Iterable<int> days) {
    var mask = 0;
    for (final day in days) {
      if (day < 1 || day > 7) {
        throw ArgumentError.value(day, 'day', 'Expected 1..7');
      }
      mask |= 1 << (day - 1);
    }
    return mask;
  }

  static String _hhmm(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Converts the phone-local schedule to the UTC values the firmware needs.
  /// [localDays] uses 0 = Monday. Throws [FormatException] with a message for
  /// the user when the schedule cannot be expressed in UTC.
  static ({String onTime, String offTime, int daysMask}) localToUtc({
    required Set<int> localDays,
    required int onHour,
    required int onMinute,
    required int offHour,
    required int offMinute,
    DateTime? now,
  }) {
    if (localDays.isEmpty) {
      throw const FormatException('Chọn ít nhất một ngày cho lịch tuần.');
    }
    final today = now ?? DateTime.now();
    final onTimes = <String>{};
    final offTimes = <String>{};
    var utcDaysMask = 0;
    for (final localWeekday in localDays) {
      final daysAhead = (localWeekday + 1 - today.weekday + 7) % 7;
      final date = DateTime(today.year, today.month, today.day + daysAhead);
      final onUtc = DateTime(
        date.year,
        date.month,
        date.day,
        onHour,
        onMinute,
      ).toUtc();
      final offUtc = DateTime(
        date.year,
        date.month,
        date.day,
        offHour,
        offMinute,
      ).toUtc();
      onTimes.add(_hhmm(onUtc.hour, onUtc.minute));
      offTimes.add(_hhmm(offUtc.hour, offUtc.minute));
      utcDaysMask |= 1 << (onUtc.weekday - 1);
    }
    if (onTimes.length != 1 || offTimes.length != 1) {
      throw const FormatException(
        'Các ngày đã chọn có múi giờ UTC khác nhau; hãy chọn ngày khác.',
      );
    }
    return (
      onTime: onTimes.single,
      offTime: offTimes.single,
      daysMask: utcDaysMask,
    );
  }

  /// Inverse of [localToUtc] for showing a stored UTC schedule. [utcDays]
  /// uses 1 = Monday ... 7 = Sunday.
  static ({Set<int> localDays, int onHour, int onMinute, int offHour, int offMinute})
  utcToLocal({
    required List<int> utcDays,
    required String onTime,
    required String offTime,
    DateTime? now,
  }) {
    final utcNow = (now ?? DateTime.now()).toUtc();
    final monday = DateTime.utc(
      utcNow.year,
      utcNow.month,
      utcNow.day - (utcNow.weekday - 1),
    );
    int part(String time, int index) => int.parse(time.split(':')[index]);
    final days = <int>{};
    DateTime? firstOn;
    DateTime? firstOff;
    for (final day in utcDays.isEmpty ? const [1] : utcDays) {
      final date = DateTime.utc(monday.year, monday.month, monday.day + day - 1);
      final on = DateTime.utc(
        date.year,
        date.month,
        date.day,
        part(onTime, 0),
        part(onTime, 1),
      ).toLocal();
      final off = DateTime.utc(
        date.year,
        date.month,
        date.day,
        part(offTime, 0),
        part(offTime, 1),
      ).toLocal();
      if (utcDays.isNotEmpty) days.add(on.weekday - 1);
      firstOn ??= on;
      firstOff ??= off;
    }
    return (
      localDays: days,
      onHour: firstOn!.hour,
      onMinute: firstOn.minute,
      offHour: firstOff!.hour,
      offMinute: firstOff.minute,
    );
  }
}
