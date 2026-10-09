import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
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
