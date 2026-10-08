import 'dart:async';

import 'test_run_provisioning_worker.dart';
import 'vm_controller.dart';

/// A bounded, non-overlapping pass. Start only after native startup recovery;
/// drain close before closing the catalog. Reporting callbacks must not throw.
final class TestRunProvisioningDispatchLoop {
  TestRunProvisioningDispatchLoop({
    required TestRunProvisioningWorker worker,
    required this.onDispatch,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    int batchLimit = 100,
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _worker = worker,
       _interval = interval,
       _batchLimit = batchLimit,
       _scheduler = scheduler {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'interval');
    if (batchLimit < 1 || batchLimit > 200)
      throw RangeError.range(batchLimit, 1, 200, 'batchLimit');
  }

  final TestRunProvisioningWorker _worker;
  final Duration _interval;
  final int _batchLimit;
  final VmTimerScheduler _scheduler;
  final void Function(List<TestRunProvisioningOutcome>) onDispatch;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('TestRun provisioning loop is closed');
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
      onDispatch(await _worker.dispatchOnce(limit: _batchLimit));
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    } finally {
      if (!_closed) _timer = _scheduler.schedule(_interval, _launch);
    }
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return _inFlight ?? Future<void>.value();
  }
}
