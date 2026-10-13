import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'guest_exec_worker.dart';
import 'vm_controller.dart';

/// Non-overlapping scans; the worker separately owns bounded concurrent IO.
/// Start after native startup recovery. Reporting callbacks must not throw.
final class GuestExecDispatchLoop {
  GuestExecDispatchLoop({
    required GuestExecWorker worker,
    required this.onComplete,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _worker = worker,
       _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'interval');
  }
  final GuestExecWorker _worker;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  final void Function(Operation, VmId, int) onComplete;
  final void Function(OperationId?, Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  Future<void>? _closing;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('guest exec loop is closed');
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
      await _worker.dispatchOnce(onComplete: onComplete, onError: onError);
    } catch (error, stack) {
      onError(null, error, stack);
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
