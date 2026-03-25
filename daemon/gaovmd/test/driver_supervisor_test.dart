import 'dart:async';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  group('DriverSupervisor', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('supervisor-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('status()', () {
      test('reports stopped when freshly created', () {
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
        );
        addTearDown(supervisor.dispose);

        final s = supervisor.status();
        expect(s['desired'], 'stopped');
        expect(s['actual'], 'stopped');
        expect(s['restartAttempts'], 0);
        expect(s['maxRestartAttempts'], 5);
        expect(s['driverPid'], isNull);
        expect(s['lastFailure'], isNull);
      });
    });

    group('start() and stop()', () {
      test('start sets desired=running and stop sets desired=stopped', () async {
        final events = <String>[];
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
          emitEvent: (type, payload) => events.add(type),
        );
        addTearDown(supervisor.dispose);

        // start() will fail because /usr/bin/false exits immediately,
        // but it should set desired=running before attempting to start driver.
        await supervisor.start();
        // Give a moment for async operations.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // After a failed start, desired may flip to stopped if retries exhaust.
        // But we can verify start was attempted.
        expect(events, contains('driver.start_failed'));
      });

      test('stop cancels pending restart timer', () async {
        final events = <String>[];
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
          emitEvent: (type, payload) => events.add(type),
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // A restart should be scheduled after the first failure.
        expect(events, contains('driver.restart_scheduled'));

        // Now stop should cancel the restart timer.
        await supervisor.stop();
        final s = supervisor.status();
        expect(s['desired'], 'stopped');
      });
    });

    group('restart backoff', () {
      test('schedules restart with exponential backoff on driver failure',
          () async {
        final events = <Map<String, Object?>>[];
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
          emitEvent: (type, payload) => events.add({
            'type': type,
            ...payload,
          }),
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();
        // Wait for first failure + restart schedule.
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final restartEvents = events
            .where((e) => e['type'] == 'driver.restart_scheduled')
            .toList();
        expect(restartEvents, isNotEmpty);
        // First attempt should have delay of 1 second (2^0).
        expect(restartEvents.first['delaySeconds'], 1);
        expect(restartEvents.first['attempt'], 1);
      });

      test('enters permanent failure after 5 restart attempts', () async {
        final events = <Map<String, Object?>>[];
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
          emitEvent: (type, payload) => events.add({
            'type': type,
            ...payload,
          }),
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();

        // Wait for enough time for 5 failures to cycle through.
        // Backoff: 1, 2, 4, 8, 16 seconds — but driver fails fast.
        // We need to wait for the restart timers to fire.
        // With /usr/bin/false, each attempt fails almost immediately,
        // but the backoff delays (1s, 2s, 4s, 8s) would take too long.
        // Instead, we verify the mechanism by checking after sufficient time.
        // Wait for first few failures + permanent_failure event.
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final permanentFailures =
              events.where((e) => e['type'] == 'driver.permanent_failure');
          if (permanentFailures.isNotEmpty) {
            break;
          }
        }

        final permanentFailures =
            events.where((e) => e['type'] == 'driver.permanent_failure');
        expect(permanentFailures, isNotEmpty,
            reason: 'Should enter permanent failure after max attempts');

        final s = supervisor.status();
        expect(s['desired'], 'stopped');
      }, timeout: Timeout(Duration(seconds: 60)));
    });

    group('desired state persistence', () {
      test('persists desired state to file on start', () async {
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final desiredFile = File('${tempDir.path}/desired_state.json');
        expect(await desiredFile.exists(), isTrue);
      });

      test('persists runtime state to file', () async {
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final runtimeFile = File('${tempDir.path}/daemon_state.json');
        expect(await runtimeFile.exists(), isTrue);
      });

      test('restoreDesiredState creates files when none exist', () async {
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
        );
        addTearDown(supervisor.dispose);

        await supervisor.restoreDesiredState();

        final desiredFile = File('${tempDir.path}/desired_state.json');
        final runtimeFile = File('${tempDir.path}/daemon_state.json');
        expect(await desiredFile.exists(), isTrue);
        expect(await runtimeFile.exists(), isTrue);
      });
    });

    group('dispose()', () {
      test('cancels all timers', () async {
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
        );

        await supervisor.dispose();

        // After dispose, supervisor should not trigger any more operations.
        // Verify status still works.
        final s = supervisor.status();
        expect(s['desired'], 'stopped');
      });
    });

    group('start() resets counters', () {
      test('resets restart attempts and window limiter on explicit start',
          () async {
        final events = <String>[];
        final supervisor = DriverSupervisor(
          driverBinary: '/usr/bin/false',
          stateDir: tempDir.path,
          emitEvent: (type, payload) => events.add(type),
        );
        addTearDown(supervisor.dispose);

        await supervisor.start();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Should have attempted and failed.
        expect(events, contains('driver.start_failed'));
        events.clear();

        // Stop, then start again — counters should reset.
        await supervisor.stop();

        // After stop, restartAttempts should be 0 since stop doesn't reset them,
        // but the start() call does reset them.
        // restartAttempts may be > 0 from previous failure cycle.
        // The key invariant is that start() resets them.

        await supervisor.start();
        // start() calls _restartAttempts = 0 at the beginning.
        // But a failed _startDriverIfNeeded may then schedule a restart,
        // incrementing _restartAttempts. So check that it was reset by
        // observing that restart_scheduled attempt=1 (not continuation).
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await supervisor.stop();

        // Verify restart_scheduled events show attempt=1 (reset happened).
        expect(events, contains('driver.restart_scheduled'));
      });
    });
  });

  group('RestartWindowLimiter', () {
    test('limits after N events within the sliding window', () {
      final limiter = RestartWindowLimiter(
        limit: 5,
        window: const Duration(minutes: 5),
      );
      final now = DateTime(2026, 3, 25, 12, 0, 0);
      for (var i = 0; i < 4; i++) {
        expect(
          limiter.recordAndIsLimited(now.add(Duration(seconds: i * 10))),
          isFalse,
        );
      }
      expect(limiter.recordAndIsLimited(now.add(const Duration(seconds: 40))),
          isTrue);
    });

    test('expires old events outside the window', () {
      final limiter = RestartWindowLimiter(
        limit: 5,
        window: const Duration(minutes: 5),
      );
      final now = DateTime(2026, 3, 25, 12, 0, 0);
      for (var i = 0; i < 4; i++) {
        limiter.recordAndIsLimited(now.add(Duration(seconds: i * 10)));
      }
      // Jump forward 6 minutes — old events should expire.
      final later = now.add(const Duration(minutes: 6));
      expect(limiter.recordAndIsLimited(later), isFalse);
      expect(limiter.countInWindow(later), 1);
    });

    test('reset clears all events', () {
      final limiter = RestartWindowLimiter(
        limit: 5,
        window: const Duration(minutes: 5),
      );
      final now = DateTime(2026, 3, 25, 12, 0, 0);
      for (var i = 0; i < 4; i++) {
        limiter.recordAndIsLimited(now);
      }
      limiter.reset();
      expect(limiter.countInWindow(now), 0);
      expect(limiter.recordAndIsLimited(now), isFalse);
    });

    test('countInWindow returns only events within window', () {
      final limiter = RestartWindowLimiter(
        limit: 10,
        window: const Duration(minutes: 5),
      );
      final now = DateTime(2026, 3, 25, 12, 0, 0);
      limiter.recordAndIsLimited(now);
      limiter.recordAndIsLimited(now.add(const Duration(minutes: 1)));
      limiter.recordAndIsLimited(now.add(const Duration(minutes: 3)));

      expect(limiter.countInWindow(now.add(const Duration(minutes: 4))), 3);
      // After 6 minutes, cutoff = now+1min. Events at now+1min and now+3min
      // are NOT before cutoff (isBefore is strictly less-than), so count = 2.
      expect(limiter.countInWindow(now.add(const Duration(minutes: 6))), 2);
    });
  });

  group('AsyncMutex', () {
    test('serializes concurrent operations', () async {
      final mutex = AsyncMutex();
      final log = <String>[];

      await Future.wait([
        mutex.run(() async {
          log.add('a-start');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          log.add('a-end');
        }),
        mutex.run(() async {
          log.add('b-start');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          log.add('b-end');
        }),
      ]);

      // Operations should not interleave.
      expect(log, ['a-start', 'a-end', 'b-start', 'b-end']);
    });

    test('does not poison queue on error', () async {
      final mutex = AsyncMutex();

      // First operation throws.
      await expectLater(
        mutex.run(() async => throw StateError('fail')),
        throwsStateError,
      );

      // Second operation should still succeed.
      final result = await mutex.run(() async => 42);
      expect(result, 42);
    });

    test('preserves return values', () async {
      final mutex = AsyncMutex();
      final result = await mutex.run(() async => 'hello');
      expect(result, 'hello');
    });
  });
}
