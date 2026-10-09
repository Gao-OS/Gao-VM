import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('logger-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('RotatingLogger', () {
    test('bounds context metadata as well as message payloads', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath);
      final oversized = 'x' * 65;
      for (final context in [
        LogContext(component: oversized),
        LogContext(eventType: oversized),
        LogContext(errorType: oversized),
      ]) {
        await logger.info('rejected metadata', context: context);
      }
      await logger.info('later record');
      final records = _records(await File(logPath).readAsString());
      expect(
        records
            .where((record) => record['event_type'] == 'daemon.log')
            .map((record) => record['message']),
        ['later record'],
      );
      expect(
        records.singleWhere(
          (record) => record['event_type'] == 'daemon.log_dropped',
        )['message'],
        'dropped 3 log records (queue or record limit)',
      );
    });

    test(
      'rejects oversized UTF-8 messages whole and preserves later writes',
      () async {
        final logPath = '${tempDir.path}/test.log';
        final logger = RotatingLogger(path: logPath);
        final maximum = '🧪' * 4096;
        await logger.info('$maximum🧪');
        await logger.info('x' * (1024 * 1024));
        await logger.info(maximum);
        final records = _records(await File(logPath).readAsString());
        final messages = records
            .where((record) => record['event_type'] == 'daemon.log')
            .map((record) => record['message'])
            .toList();
        expect(messages, hasLength(1));
        expect(
          messages.single == maximum,
          isTrue,
          reason: 'accepted Unicode is unchanged',
        );
        expect(
          records.singleWhere(
            (record) => record['event_type'] == 'daemon.log_dropped',
          )['message'],
          'dropped 2 log records (queue or record limit)',
        );
      },
    );

    test('bounds pending bytes before the pending record limit', () async {
      final logPath = '${tempDir.path}/test.log';
      expect((await Process.run('mkfifo', [logPath])).exitCode, 0);
      final logger = RotatingLogger(path: logPath);
      final payload = 'x' * (16 * 1024);
      final errors = <int, Object>{};
      final writes = List.generate(
        101,
        (index) => logger.info(index == 0 ? 'held' : payload).catchError((
          Object error,
        ) {
          errors[index] = error;
        }),
      );
      try {
        await expectLater(
          logger.flush().timeout(const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
        await expectLater(
          writes.last.timeout(const Duration(milliseconds: 200)),
          completes,
        );
      } finally {
        await _releaseStalledLog(logPath, logger);
      }
      await Future.wait(writes);
      expect(errors.keys, everyElement(0), reason: errors.toString());
      final records = _records(await File(logPath).readAsString());
      final accepted = records.where((record) => record['message'] == payload);
      expect(accepted.length, inInclusiveRange(1, 60));
      expect(
        records.where((record) => record['event_type'] == 'daemon.log_dropped'),
        hasLength(1),
      );
      await logger.info('byte capacity recovered');
      expect(
        _records(await File(logPath).readAsString()).last['message'],
        'byte capacity recovered',
      );
    });

    test('bounds pending records without waiting for a stalled sink', () async {
      final logPath = '${tempDir.path}/test.log';
      expect((await Process.run('mkfifo', [logPath])).exitCode, 0);
      final logger = RotatingLogger(path: logPath);
      final errors = <int, Object>{};
      final writes = List.generate(
        300,
        (index) => logger.info('record-$index').catchError((Object error) {
          errors[index] = error;
        }),
      );
      try {
        await expectLater(
          logger.flush().timeout(const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
        await expectLater(
          writes.last.timeout(const Duration(milliseconds: 200)),
          completes,
        );
      } finally {
        await _releaseStalledLog(logPath, logger);
      }
      await Future.wait(writes);
      // Only the intentionally stalled FIFO write may fail (e.g. fsync/seek).
      expect(errors.keys, everyElement(0));
      final records = _records(await File(logPath).readAsString());
      final accepted = records.where(
        (record) => record['event_type'] == 'daemon.log',
      );
      expect(accepted.length, inInclusiveRange(255, 256));
      final loss = records.singleWhere(
        (record) => record['event_type'] == 'daemon.log_dropped',
      );
      expect(loss['level'], 'warn');
      expect(loss['message'], 'dropped 44 log records (queue or record limit)');
      expect(loss['operation_id'], isNull);
      expect(loss['request_id'], isNull);
      await logger.info('capacity recovered');
      expect(
        _records(await File(logPath).readAsString()).last['message'],
        'capacity recovered',
      );
    });

    test(
      'keeps concurrent VM request and background correlations isolated',
      () async {
        final logPath = '${tempDir.path}/test.log';
        final logger = RotatingLogger(path: logPath);
        final first = LogContext(
          component: 'api',
          eventType: 'api.request.completed',
          vmId: VmId.generate(),
          operationId: OperationId.generate(),
          driverGeneration: 7,
          requestId: RequestId.generate(),
        );
        final second = LogContext(
          component: 'test-run-worker',
          eventType: 'background.failed',
          vmId: VmId.generate(),
          operationId: OperationId.generate(),
          driverGeneration: 11,
          requestId: RequestId.generate(),
          testRunId: TestRunId.generate(),
          errorType: 'StateError',
        );
        await Future.wait([
          logger.info('request completed', context: first),
          logger.error('background work failed', context: second),
          logger.warn('unscoped'),
        ]);

        final records = _records(await File(logPath).readAsString());
        expect(records, hasLength(3));
        for (final (index, context) in [first, second].indexed) {
          expect(records[index]['component'], context.component);
          expect(records[index]['event_type'], context.eventType);
          expect(records[index]['vm_id'], context.vmId!.value);
          expect(records[index]['operation_id'], context.operationId!.value);
          expect(records[index]['driver_generation'], context.driverGeneration);
          expect(records[index]['request_id'], context.requestId!.value);
        }
        expect(records[1]['test_run_id'], second.testRunId!.value);
        expect(records[1]['error_type'], 'StateError');
        expect(records[0], isNot(contains('test_run_id')));
        expect(records[0], isNot(contains('error_type')));
        expect(records[2]['vm_id'], isNull);
        expect(records[2]['operation_id'], isNull);
        expect(records[2]['driver_generation'], isNull);
        expect(records[2]['request_id'], isNull);
      },
    );

    test(
      'writes one structured record without splitting message newlines',
      () async {
        final logPath = '${tempDir.path}/test.log';
        final logger = RotatingLogger(path: logPath);
        const message = 'line one\nline two\t"quoted" 🧪';

        await logger.info(message);

        final lines = await File(logPath).readAsLines();
        expect(lines, hasLength(1));
        final record = jsonDecode(lines.single) as Map<String, dynamic>;
        expect(record.keys.toSet(), {
          'timestamp',
          'level',
          'component',
          'vm_id',
          'operation_id',
          'driver_generation',
          'request_id',
          'event_type',
          'message',
        });
        expect(DateTime.parse(record['timestamp'] as String).isUtc, isTrue);
        expect(record['level'], 'info');
        expect(record['component'], 'gaovmd');
        expect(record['event_type'], 'daemon.log');
        expect(record['message'], message);
        for (final field in [
          'vm_id',
          'operation_id',
          'driver_generation',
          'request_id',
        ]) {
          expect(record[field], isNull, reason: field);
        }
      },
    );

    test(
      'flush drains all accepted writes before state ownership is released',
      () async {
        final logPath = '${tempDir.path}/test.log';
        final logger = RotatingLogger(path: logPath);
        final writes = [logger.info('first'), logger.warn('second')];
        await logger.flush();
        final records = _records(await File(logPath).readAsString());
        expect(records.map((record) => record['message']), ['first', 'second']);
        expect(records.map((record) => record['level']), ['info', 'warn']);
        await Future.wait(writes);
      },
    );

    test('creates log file and writes messages', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath);

      await logger.info('hello world');
      await logger.error('something failed');

      final file = File(logPath);
      expect(await file.exists(), isTrue);
      final records = _records(await file.readAsString());
      expect(records.map((record) => record['message']), [
        'hello world',
        'something failed',
      ]);
      expect(records.map((record) => record['level']), ['info', 'error']);
    });

    test('respects minimum log level', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath, minLevel: LogLevel.warn);

      await logger.info('should be skipped');
      await logger.debug('also skipped');
      await logger.warn('should appear');
      await logger.error('should also appear');

      final file = File(logPath);
      final records = _records(await file.readAsString());
      expect(records.map((record) => record['level']), ['warn', 'error']);
      expect(records.map((record) => record['message']), [
        'should appear',
        'should also appear',
      ]);
    });

    test('rotates when file exceeds maxBytes', () async {
      final logPath = '${tempDir.path}/test.log';
      // Set very small max to trigger rotation quickly.
      final logger = RotatingLogger(
        path: logPath,
        maxBytes: 100,
        maxRotations: 3,
      );

      // Write enough to exceed 100 bytes.
      for (var i = 0; i < 10; i++) {
        await logger.info('message $i - padding to exceed size limit easily');
      }

      // At least one rotation should have occurred.
      final rotated1 = File('$logPath.1');
      expect(await rotated1.exists(), isTrue);
    });

    test('limits rotation count', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(
        path: logPath,
        maxBytes: 50,
        maxRotations: 2,
      );

      // Write many messages to trigger multiple rotations.
      for (var i = 0; i < 30; i++) {
        await logger.info('message $i - padding padding padding padding');
      }

      // File .3 should NOT exist (maxRotations=2).
      final rotated3 = File('$logPath.3');
      expect(await rotated3.exists(), isFalse);
    });

    test('creates parent directories if needed', () async {
      final logPath = '${tempDir.path}/sub/dir/test.log';
      final logger = RotatingLogger(path: logPath);

      await logger.info('test');

      final file = File(logPath);
      expect(await file.exists(), isTrue);
    });

    test('includes ISO 8601 timestamp', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath);

      await logger.info('timestamp test');

      final content = await File(logPath).readAsString();
      final timestamp = _records(content).single['timestamp'] as String;
      expect(DateTime.parse(timestamp).isUtc, isTrue);
    });

    test('serializes concurrent writes', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath);

      // Fire multiple writes concurrently.
      await Future.wait([
        logger.info('msg-a'),
        logger.info('msg-b'),
        logger.info('msg-c'),
      ]);

      final content = await File(logPath).readAsString();
      expect(_records(content).map((record) => record['message']), [
        'msg-a',
        'msg-b',
        'msg-c',
      ]);
    });
  });
}

List<Map<String, dynamic>> _records(String contents) => const LineSplitter()
    .convert(contents)
    .map((line) => jsonDecode(line) as Map<String, dynamic>)
    .toList();

Future<void> _releaseStalledLog(String path, RotatingLogger logger) async {
  final reader = await File(
    path,
  ).open(mode: FileMode.read).timeout(const Duration(seconds: 3));
  try {
    await File(path).delete();
    await File(path).create();
    await logger.flush().timeout(const Duration(seconds: 3));
  } finally {
    await reader.close();
  }
}
