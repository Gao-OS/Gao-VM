import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  test(
    'interactive output capture preserves readiness and the exit receipt',
    () async {
      final process = await Process.start('/bin/cat', []);
      final stream = process.stdout.transform(utf8.decoder).asBroadcastStream();
      final stdoutCapture = stream.join();
      final stderrCapture = process.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(stream.transform(const LineSplitter()));
      OwnedTestProcess? owned;
      try {
        owned = OwnedTestProcess(
          process,
          stdoutCapture: stdoutCapture,
          stderrCapture: stderrCapture,
        );
        process.stdin.writeln('ready');
        expect(
          await output.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(output.current, 'ready');
        await process.stdin.close();
        final result = await owned.result();
        expect(result.exitCode, 0);
        expect(result.stdout, 'ready\n');
        expect(result.stderr, isEmpty);
        expect(owned.exitConfirmed, isTrue);
      } finally {
        await process.stdin.close();
        if (owned != null) {
          expect(await owned.terminate(), isTrue);
        } else {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 2));
        }
        await output.cancel();
        await Future.wait([stdoutCapture, stderrCapture]);
      }
    },
  );
  test('collects native output only after a confirmed exit', () async {
    final owned = OwnedTestProcess(await Process.start('/bin/echo', ['ready']));
    addTearDown(owned.terminate);
    final result = await owned.result();
    expect(result.exitCode, 0);
    expect(result.stdout, 'ready\n');
    expect(result.stderr, isEmpty);
    expect(owned.exitConfirmed, isTrue);
  });

  test(
    'a deadline confirms child exit before allowing fixture cleanup',
    () async {
      final process = await Process.start('/bin/sleep', ['60']);
      final owned = OwnedTestProcess(process);
      addTearDown(() async {
        expect(await owned.terminate(), isTrue);
      });
      await expectLater(
        owned.result(timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      expect(owned.exitConfirmed, isTrue);
      expect(await process.exitCode, isNot(0));
    },
  );
}
