import 'package:flutter_app/protocol/load_automation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('days mask converts to and from days (1 = Monday)', () {
    expect(LoadAutomation.daysFromMask(31), [1, 2, 3, 4, 5]);
    expect(LoadAutomation.daysFromMask(0), isEmpty);
    expect(LoadAutomation.daysFromMask(127), [1, 2, 3, 4, 5, 6, 7]);
    expect(LoadAutomation.maskFromDays([1, 2, 3, 4, 5]), 31);
    expect(LoadAutomation.maskFromDays([6, 7]), 96);
    expect(() => LoadAutomation.maskFromDays([0]), throwsArgumentError);
    expect(() => LoadAutomation.maskFromDays([8]), throwsArgumentError);
  });

  test('local schedule survives a round trip through UTC', () {
    final now = DateTime(2026, 1, 14);
    final utc = LoadAutomation.localToUtc(
      localDays: {0, 1, 2, 3, 4},
      onHour: 6,
      onMinute: 30,
      offHour: 18,
      offMinute: 0,
      now: now,
    );
    final local = LoadAutomation.utcToLocal(
      utcDays: LoadAutomation.daysFromMask(utc.daysMask),
      onTime: utc.onTime,
      offTime: utc.offTime,
      now: now,
    );
    expect(local.localDays, {0, 1, 2, 3, 4});
    expect((local.onHour, local.onMinute), (6, 30));
    expect((local.offHour, local.offMinute), (18, 0));
  });

  test('an empty schedule is rejected with a user message', () {
    expect(
      () => LoadAutomation.localToUtc(
        localDays: {},
        onHour: 6,
        onMinute: 0,
        offHour: 18,
        offMinute: 0,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('ít nhất một ngày'),
        ),
      ),
    );
  });
}
