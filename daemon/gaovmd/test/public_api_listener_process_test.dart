import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  for (final (mode, description) in [
    ('close', 'API close'),
    ('error', 'an unexpected API listener error'),
    ('eof', 'unexpected API listener EOF'),
    ('cleanup-error', 'API listener failure with socket cleanup failure'),
  ]) {
    test(
      '$description permits natural process exit',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'gaovm-api-exit-',
        );
        imageFileMode(directory.path, 0x1c0);
        Process? process;
        StreamSubscription<String>? output;
        Future<int>? exited;
        Future<String>? errors;
        var exitConfirmed = false;
        try {
          process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/close_public_api.dart',
            '${directory.path}/api.sock',
            mode,
          ]);
          exited = process.exitCode.then((code) {
            exitConfirmed = true;
            return code;
          });
          errors = utf8.decoder.bind(process.stderr).join();
          final closed = Completer<void>();
          output = utf8.decoder
              .bind(process.stdout)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (line == 'closed' && !closed.isCompleted)
                    closed.complete();
                },
                onError: (Object error, StackTrace stack) {
                  if (!closed.isCompleted) closed.completeError(error, stack);
                },
                onDone: () {
                  if (!closed.isCompleted) {
                    closed.completeError(
                      StateError('API close did not complete'),
                    );
                  }
                },
              );
          await process.stdin.close();
          await closed.future.timeout(const Duration(seconds: 30));
          final code = await exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw TestFailure(
              'API close completed, but its process retained a live handle',
            ),
          );
          expect(code, 0, reason: await errors);
          expect(await errors, isEmpty);
          expect(
            await directory.list().toList(),
            mode == 'cleanup-error' ? isNotEmpty : isEmpty,
          );
        } finally {
          if (process != null && !exitConfirmed) {
            process.kill(ProcessSignal.sigkill);
            await exited!.timeout(const Duration(seconds: 5));
          }
          await output?.cancel();
          await errors;
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }
}
