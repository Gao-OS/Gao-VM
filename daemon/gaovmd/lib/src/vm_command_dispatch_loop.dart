import 'dart:async';

import 'vm_command_dispatcher.dart';
import 'vm_controller.dart';

/// Drives bounded durable lifecycle delivery without overlapping claim passes.
///
/// Start only after the catalog and registry recovery dependencies are ready.
/// Initiate close before registry shutdown; drain both before closing the database.
/// A pending adoption may need controller shutdown to unblock, so do not await the
/// loop drain before starting registry shutdown. Delivery outcomes include
/// per-VM failures/deferred claims; infrastructure failures are sent to [onError].
/// Neither callback may throw. A failed pass is retried on the next interval.
final class VmCommandDispatchLoop {
  VmCommandDispatchLoop({
    required VmCommandDispatcher dispatcher,
    required this.onDispatch,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    int batchLimit = 100,
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _dispatcher = dispatcher,
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

  final VmCommandDispatcher _dispatcher;
  final Duration _interval;
  final int _batchLimit;
  final VmTimerScheduler _scheduler;
  final void Function(List<VmCommandDispatchOutcome>) onDispatch;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('VM command dispatch loop is closed');
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
      onDispatch(await _dispatcher.dispatchOnce(limit: _batchLimit));
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
