import 'dart:async';

import 'test_run_step_worker.dart';
import 'vm_controller.dart';

/// Non-overlapping committed step scans. Guest IO remains in GuestExecWorker.
/// Start only after original-owner and step recovery have succeeded.
final class TestRunStepDispatchLoop {
  TestRunStepDispatchLoop({
    required TestRunStepWorker worker,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _worker = worker,
       _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'interval');
  }

  final TestRunStepWorker _worker;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  Future<void>? _closing;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('TestRun step loop is closed');
    if (_started) return;
    _started = true;
    _launch();
  }

  void _launch() {
    if (_closed) return;
    _timer = null;
    _inFlight = _dispatch();
  }

  Future<void> _dispatch() async {
    try {
      await _worker.dispatchOnce();
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      if (!_closed) _timer = _scheduler.schedule(_interval, _launch);
    }
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return _closing ??= Future.wait([
      if (_inFlight case final pass?) pass,
      _worker.close(),
    ]).then<void>((_) {});
  }
}
