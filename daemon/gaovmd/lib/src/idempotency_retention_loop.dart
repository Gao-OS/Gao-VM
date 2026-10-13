import 'idempotency_repository.dart';
import 'vm_controller.dart';

/// Retires only completed, expired replay envelopes in bounded catalog passes.
/// Start after recovery and drain before closing SQLite. [onError] must not throw.
final class IdempotencyRetentionLoop {
  IdempotencyRetentionLoop({
    required SqliteIdempotencyRepository repository,
    required this.onError,
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _repository = repository,
       _scheduler = scheduler;

  final SqliteIdempotencyRepository _repository;
  final VmTimerScheduler _scheduler;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('idempotency retention loop is closed');
    if (_started) return;
    _started = true;
    _launch();
  }

  void _launch() {
    if (_closed) return;
    _timer = null;
    _inFlight = _collect();
  }

  Future<void> _collect() async {
    try {
      await _repository.cleanupExpired(limit: 100);
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      if (!_closed) {
        _timer = _scheduler.schedule(const Duration(minutes: 1), _launch);
      }
    }
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return _inFlight ?? Future<void>.value();
  }
}
