import 'dart:async';

import 'artifact_application_service.dart';
import 'vm_controller.dart';

/// Starts only after startup recovery. Stop scheduling and drain the active
/// bounded pass before closing its catalog and owned filesystem roots.
final class ArtifactRetentionLoop {
  ArtifactRetentionLoop({
    required ArtifactApplicationService artifacts,
    required this.onError,
    Duration interval = const Duration(minutes: 1),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _artifacts = artifacts,
       _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'interval');
  }

  final ArtifactApplicationService _artifacts;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  final void Function(Object, StackTrace) onError;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('artifact retention loop is closed');
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
      await _artifacts.collectExpired();
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
    return _inFlight ?? Future<void>.value();
  }
}
