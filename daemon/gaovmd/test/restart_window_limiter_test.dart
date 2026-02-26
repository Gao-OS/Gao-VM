import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  group('RestartWindowLimiter', () {
    test('limits after N events within the sliding window', () {
      final limiter = RestartWindowLimiter(
        limit: 5,
        window: const Duration(minutes: 5),
      );
      final t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);

      for (var i = 0; i < 4; i++) {
        expect(
          limiter.recordAndIsLimited(t0.add(Duration(minutes: i))),
          isFalse,
        );
      }
      expect(
        limiter.recordAndIsLimited(
            t0.add(const Duration(minutes: 4, seconds: 59))),
        isTrue,
      );
    });

    test('expires old events outside the window', () {
      final limiter = RestartWindowLimiter(
        limit: 5,
        window: const Duration(minutes: 5),
      );
      final t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);

      for (var i = 0; i < 4; i++) {
        expect(
          limiter.recordAndIsLimited(t0.add(Duration(minutes: i))),
          isFalse,
        );
      }

      expect(
        limiter.recordAndIsLimited(t0.add(const Duration(minutes: 6))),
        isFalse,
      );
      expect(limiter.countInWindow(t0.add(const Duration(minutes: 6))), 4);
    });
  });
}
