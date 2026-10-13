import 'runtime_driver_effect_adapter.dart';
import 'vm_controller.dart';

/// Independent of catalog scans and guest IO. The driver adapter owns and drains
/// per-generation probes/publications; this loop owns only its safety timer.
/// Fence this producer before driver/controller shutdown. [onError] must not throw.
final class GuestSessionReconcileLoop {
  GuestSessionReconcileLoop({
    required RuntimeDriverEffectAdapter drivers,
    required this.onError,
    Duration interval = const Duration(seconds: 5),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _drivers = drivers,
       _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  final RuntimeDriverEffectAdapter _drivers;
  final RuntimeGuestSessionErrorObserver onError;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  VmTimerHandle? _timer;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('guest reconcile loop is closed');
    if (_started) return;
    _started = true;
    _tick();
  }

  void _tick() {
    if (_closed) return;
    _timer = null;
    _drivers.reconcileGuestSessions(onError: onError);
    if (!_closed) _timer = _scheduler.schedule(_interval, _tick);
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return Future<void>.value();
  }
}
