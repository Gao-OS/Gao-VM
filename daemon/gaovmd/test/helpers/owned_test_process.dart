import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A test fixture may be removed only after [exitConfirmed], not a deadline.
final class OwnedTestProcess {
  /// Supply captures when the caller also consumes interactive process output.
  /// They must keep draining the streams until the owned child exits.
  OwnedTestProcess(
    this._process, {
    Future<String>? stdoutCapture,
    Future<String>? stderrCapture,
  }) : _stdout =
           stdoutCapture ?? _process.stdout.transform(utf8.decoder).join(),
       _stderr =
           stderrCapture ?? _process.stderr.transform(utf8.decoder).join() {
    _exitCode = _process.exitCode.then((code) {
      _exitConfirmed = true;
      return code;
    });
  }

  final Process _process;
  final Future<String> _stdout;
  final Future<String> _stderr;
  late final Future<int> _exitCode;
  bool _exitConfirmed = false;
  int get pid => _process.pid;
  bool get exitConfirmed => _exitConfirmed;

  Future<ProcessResult> result({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Future<ProcessResult> collect() async => ProcessResult(
      _process.pid,
      await _exitCode,
      await _stdout,
      await _stderr,
    );

    try {
      return await collect().timeout(timeout);
    } on TimeoutException {
      await terminate();
      throw TimeoutException(
        'owned fixture PID ${_process.pid} timed out; '
        'exit confirmed: $exitConfirmed',
        timeout,
      );
    }
  }

  Future<bool> terminate() async {
    if (exitConfirmed) return true;
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
      _process.kill(signal);
      try {
        await _exitCode.timeout(const Duration(seconds: 2));
        return true;
      } on TimeoutException {
        // A successful signal delivery is not an exit acknowledgement.
      }
    }
    return exitConfirmed;
  }
}
