import 'dart:async';

import 'image_application_service.dart';
import 'vm_controller.dart';

/// Start only after daemon ownership/recovery. Await close before disposing
/// SQLite or the image root: a pass includes publication and its terminal commit.
final class ImageWorkDispatchLoop {
  ImageWorkDispatchLoop({
    required this.images,
    required this.onError,
    Duration interval = const Duration(milliseconds: 250),
    VmTimerScheduler scheduler = const DartVmTimerScheduler(),
  }) : _interval = interval,
       _scheduler = scheduler {
    if (interval <= Duration.zero)
      throw ArgumentError.value(interval, 'interval');
  }
  final ImageApplicationService images;
  final void Function(Object, StackTrace) onError;
  final Duration _interval;
  final VmTimerScheduler _scheduler;
  VmTimerHandle? _timer;
  Future<void>? _inFlight;
  bool _started = false;
  bool _closed = false;

  void start() {
    if (_closed) throw StateError('image work loop is closed');
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
      await images.dispatchOnce();
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
