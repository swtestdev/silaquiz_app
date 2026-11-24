import 'package:flutter_test/flutter_test.dart';
import 'package:pwa_app/services/timer_store.dart';

void main() {
  group('TimerSession.displayRemainingSecondsAt', () {
    final started = DateTime.utc(2026, 9, 20, 3, 10, 36);
    final ends = DateTime.utc(2026, 9, 20, 3, 11, 16);
    const total = 40;

    TimerSession session() => TimerSession(
          eventId: 'e1',
          kind: TimerSessionKind.question,
          roundName: 'R',
          startedAtUtc: started,
          endsAtUtc: ends,
          totalSeconds: total,
          questionId: 1,
        );

    test('clamps slow clock before start (50 raw -> 40 display)', () {
      final now = started.subtract(const Duration(seconds: 10));
      expect(session().remainingSecondsAt(now), 50);
      expect(session().displayRemainingSecondsAt(now), 40);
    });

    test('at start shows full total', () {
      expect(session().displayRemainingSecondsAt(started), 40);
    });

    test('mid-window matches raw when within total', () {
      final now = started.add(const Duration(seconds: 10));
      expect(session().displayRemainingSecondsAt(now), 30);
    });
  });

  group('TimerStore.updateServerClockOffset', () {
    test('stores offset when server UTC is ahead of local', () {
      final store = TimerStore.instance;
      final local = DateTime.now().toUtc();
      final server = local.add(const Duration(seconds: 10));
      store.updateServerClockOffset(server.toIso8601String());
      expect(store.serverUtcOffsetForTest.inSeconds, inInclusiveRange(9, 11));
    });
  });
}
