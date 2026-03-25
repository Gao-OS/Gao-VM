import 'dart:io';

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
    test('creates log file and writes messages', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(path: logPath);

      await logger.info('hello world');
      await logger.error('something failed');

      final file = File(logPath);
      expect(await file.exists(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('[info] hello world'));
      expect(content, contains('[error] something failed'));
    });

    test('respects minimum log level', () async {
      final logPath = '${tempDir.path}/test.log';
      final logger = RotatingLogger(
        path: logPath,
        minLevel: LogLevel.warn,
      );

      await logger.info('should be skipped');
      await logger.debug('also skipped');
      await logger.warn('should appear');
      await logger.error('should also appear');

      final file = File(logPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        expect(content, isNot(contains('[info]')));
        expect(content, isNot(contains('[debug]')));
        expect(content, contains('[warn] should appear'));
        expect(content, contains('[error] should also appear'));
      }
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
      // Match ISO 8601 pattern: [2026-03-25T...]
      expect(content, matches(RegExp(r'\[\d{4}-\d{2}-\d{2}T')));
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
      expect(content, contains('msg-a'));
      expect(content, contains('msg-b'));
      expect(content, contains('msg-c'));
    });
  });
}
