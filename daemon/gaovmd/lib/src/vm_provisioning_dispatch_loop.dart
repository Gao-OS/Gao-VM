import 'dart:async';

import 'vm_controller.dart';
import 'vm_provisioning_worker.dart';

/// Drives bounded durable provisioning without overlapping worker passes.
///
/// Start after recovery and owned filesystem roots are ready. Await [close]
/// before closing the roots or database: a pass includes filesystem publication
/// and its terminal database commit. Per-job outcomes go to [onDispatch]; claim
/// infrastructure failures go to [onError] and retry on the next interval.
/// Neither callback may throw.
final class VmProvisioningDispatchLoop {
  VmProvisioningDispatchLoop({
    required VmProvisioningWorker worker,
    required this.onDispatch,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    int batchLimit = 100,
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _worker = worker,
       _interval = interval,
       _batchLimit = batchLimit,
       _scheduler = scheduler {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    if (batchLimit < 1 || batchLimit > 1000) {
      throw ArgumentError.value(batchLimit, 'batchLimit', 'must be 1 to 1000');
    }
  }

  final VmProvisioningWorker _worker;
  final Duration _interval;
  final int _batchLimit;
  final VmTimerScheduler _scheduler;
  final void Function(List<VmProvisioningOutcome>) onDispatch;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('VM provisioning dispatch loop is closed');
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
