import 'package:gaovm_models/gaovm_models.dart';

import 'vm_controller.dart';
import 'vm_registry.dart';

/// Drives the five-second reconciliation safety tick without overlapping scans.
/// VM execution is detached from each scan and drained by the registry.
///
/// Initiate close before registry shutdown, drain both concurrently, and keep
/// the database open until both finish. Neither error callback may throw.
final class VmReconcileLoop {
  VmReconcileLoop({
    required VmRegistry registry,
    required this.onVmError,
    required this.onError,
    Duration interval = const Duration(seconds: 5),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _registry = registry,
       _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  final VmRegistry _registry;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  final void Function(VmId, Object, StackTrace) onVmError;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('VM reconcile loop is closed');
    if (_started) return;
    _started = true;
    _launch();
  }

  void _launch() {
    if (_closed) return;
    _timer = null;
    _inFlight = _scan();
  }

  Future<void> _scan() async {
    try {
      await _registry.reconcileTick(onError: onVmError);
    } catch (error, stackTrace) {
      if (!_closed || error is! VmRegistryClosedException) {
        onError(error, stackTrace);
      }
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
