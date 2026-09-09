import 'dart:io';
import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'stalled inventory sampling has a bounded admission failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovmd-metrics-',
      );
      final storage = await OwnedImageDirectory.open(directory);
      final stalled = Completer<int>();
      try {
        final source = MacOsHostMetricsSource(
          storage: storage,
          countUnmanagedDrivers: () => stalled.future,
        );
        await expectLater(
          source.sample().timeout(const Duration(seconds: 7)),
          throwsA(
            isA<VmEffectException>().having(
              (error) => error.cause,
              'timeout',
              isA<TimeoutException>(),
            ),
          ),
        );
      } finally {
        stalled.complete(0);
        storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'negative driver counts and closed storage never produce capacity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovmd-metrics-',
      );
      final storage = await OwnedImageDirectory.open(directory);
      try {
        final invalid = MacOsHostMetricsSource(
          storage: storage,
          countUnmanagedDrivers: () => -1,
        );
        await expectLater(
          invalid.sample(),
          throwsA(
            isA<VmEffectException>().having(
              (error) => error.cause,
              'production validation',
              isArgumentError,
            ),
          ),
        );
        storage.close();
        final closed = MacOsHostMetricsSource(
          storage: storage,
          countUnmanagedDrivers: () => 0,
        );
        await expectLater(closed.sample(), throwsA(isA<VmEffectException>()));
      } finally {
        storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'unavailable inventory fails admission with a typed retryable error',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovmd-metrics-',
      );
      final storage = await OwnedImageDirectory.open(directory);
      try {
        final source = MacOsHostMetricsSource(
          storage: storage,
          countUnmanagedDrivers: () =>
              throw StateError('inventory unavailable'),
        );
        await expectLater(
          source.sample(),
          throwsA(
            isA<VmEffectException>()
                .having(
                  (error) => error.operationError.code,
                  'code',
                  ErrorCode.hostResourceExhausted,
                )
                .having(
                  (error) => error.operationError.retryable,
                  'retryable',
                  isTrue,
                ),
          ),
        );
      } finally {
        storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'samples real macOS memory and the held storage filesystem',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovmd-metrics-',
      );
      final storage = await OwnedImageDirectory.open(directory);
      try {
        final source = MacOsHostMetricsSource(
          storage: storage,
          countUnmanagedDrivers: () async => 2,
        );
        final sample = await source.sample();
        final total = await Process.run('/usr/sbin/sysctl', [
          '-n',
          'hw.memsize',
        ]);
        expect(total.exitCode, 0);
        expect(sample.logicalCpuCount, Platform.numberOfProcessors);
        expect(
          sample.totalMemoryBytes,
          int.parse((total.stdout as String).trim()),
        );
        expect(
          sample.availableMemoryBytes,
          inInclusiveRange(0, sample.totalMemoryBytes),
        );
        expect(sample.freeDiskBytes, greaterThanOrEqualTo(0));
        expect(sample.unmanagedDriverProcesses, 2);
      } finally {
        storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
