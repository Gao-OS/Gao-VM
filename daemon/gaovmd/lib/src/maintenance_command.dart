import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

final class MaintenanceCommandFailure implements Exception {
  const MaintenanceCommandFailure(
    this.reason,
    this.pid, {
    required this.exitConfirmed,
  });
  final String reason;
  final int pid;
  final bool exitConfirmed;
  @override
  String toString() =>
      '$reason (owned child $pid; exit confirmed: $exitConfirmed)';
}

Future<ProcessResult> runMaintenanceCommand(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 5),
  int maxOutputBytes = 16384,
}) async {
  if (timeout <= Duration.zero || maxOutputBytes < 1) {
    throw ArgumentError('maintenance command requires positive bounds');
  }
  final child = await Process.start(
    executable,
    arguments,
    includeParentEnvironment: false,
    environment: const {'PATH': '/usr/bin:/bin'},
  );
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  final output = BytesBuilder(copy: false), error = BytesBuilder(copy: false);
  final outputDone = Completer<void>(), errorDone = Completer<void>();
  final exceeded = Completer<Never>();
  void append(BytesBuilder buffer, List<int> bytes) {
    if (buffer.length + bytes.length > maxOutputBytes) {
      if (!exceeded.isCompleted) {
        exceeded.completeError(
          MaintenanceCommandFailure(
            'maintenance output limit exceeded',
            child.pid,
            exitConfirmed: false,
          ),
        );
      }
      return;
    }
    buffer.add(bytes);
  }

  final outputSubscription = child.stdout.listen(
    (bytes) => append(output, bytes),
    onDone: outputDone.complete,
    onError: outputDone.completeError,
  );
  final errorSubscription = child.stderr.listen(
    (bytes) => append(error, bytes),
    onDone: errorDone.complete,
    onError: errorDone.completeError,
  );
  ProcessResult? result;
  Object? failure;
  StackTrace? stack;
  try {
    Future<ProcessResult> collect() async {
      await child.stdin.close();
      final code = await exit;
      await Future.wait([outputDone.future, errorDone.future]);
      return ProcessResult(
        child.pid,
        code,
        utf8.decode(output.takeBytes()),
        utf8.decode(error.takeBytes()),
      );
    }

    result = await Future.any<ProcessResult>([collect(), exceeded.future])
        .timeout(
          timeout,
          onTimeout: () => throw MaintenanceCommandFailure(
            'maintenance command deadline exceeded',
            child.pid,
            exitConfirmed: false,
          ),
        );
  } catch (error, trace) {
    failure = error;
    stack = trace;
  } finally {
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
      if (exited) break;
      child.kill(signal);
      try {
        await exit.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        /* retain input */
      }
    }
    await outputSubscription.cancel();
    await errorSubscription.cancel();
  }
  if (!exited) {
    throw MaintenanceCommandFailure(
      'maintenance child exit is unconfirmed; retain all inputs',
      child.pid,
      exitConfirmed: false,
    );
  }
  if (failure is MaintenanceCommandFailure) {
    throw MaintenanceCommandFailure(
      failure.reason,
      child.pid,
      exitConfirmed: true,
    );
  }
  if (failure != null) Error.throwWithStackTrace(failure, stack!);
  return result!;
}
