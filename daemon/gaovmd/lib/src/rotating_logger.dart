import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

enum LogLevel { error, warn, info, debug }

/// Immutable correlation captured by a caller, never ambient mutable VM state.
final class LogContext {
  const LogContext({
    this.component = 'gaovmd',
    this.eventType = 'daemon.log',
    this.vmId,
    this.operationId,
    this.driverGeneration,
    this.requestId,
    this.testRunId,
    this.errorType,
  });

  final String component;
  final String eventType;
  final VmId? vmId;
  final OperationId? operationId;
  final int? driverGeneration;
  final RequestId? requestId;
  final TestRunId? testRunId;
  final String? errorType;
}

class RotatingLogger {
  RotatingLogger({
    required this.path,
    this.maxBytes = 10 * 1024 * 1024,
    this.maxRotations = 3,
    this.minLevel = LogLevel.info,
  });

  final String path;
  final int maxBytes;
  final int maxRotations;
  final LogLevel minLevel;
  Future<void> _writeQueue = Future<void>.value();
  int _queuedRecords = 0;
  int _queuedBytes = 0;
  int _droppedRecords = 0;
  static const _maxQueuedRecords = 256;
  static const _maxQueuedBytes = 1024 * 1024;
  static const _maxMessageBytes = 16 * 1024;

  Future<void> error(
    String message, {
    LogContext context = const LogContext(),
  }) => log(LogLevel.error, message, context: context);
  Future<void> warn(
    String message, {
    LogContext context = const LogContext(),
  }) => log(LogLevel.warn, message, context: context);
  Future<void> info(
    String message, {
    LogContext context = const LogContext(),
  }) => log(LogLevel.info, message, context: context);
  Future<void> debug(
    String message, {
    LogContext context = const LogContext(),
  }) => log(LogLevel.debug, message, context: context);

  /// Drains accepted writes before the daemon releases state ownership.
  Future<void> flush() => _writeQueue;

  Future<void> log(
    LogLevel level,
    String message, {
    LogContext context = const LogContext(),
  }) async {
    if (level.index > minLevel.index) {
      return;
    }
    // Bound encoding work as well as the bytes retained by deferred writes.
    if (_queuedRecords >= _maxQueuedRecords ||
        message.length > _maxMessageBytes ||
        context.component.length > 64 ||
        context.eventType.length > 64 ||
        (context.errorType?.length ?? 0) > 64) {
      _dropRecord();
      return;
    }
    final payload = utf8.encode(message);
    final reservedBytes = payload.length + 1024;
    if (payload.length > _maxMessageBytes ||
        reservedBytes > _maxQueuedBytes - _queuedBytes) {
      _dropRecord();
      return;
    }
    _queuedRecords++;
    _queuedBytes += reservedBytes;
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final op = _writeQueue.then((_) async {
      try {
        await _append(level, utf8.decode(payload), timestamp, context);
        final dropped = _droppedRecords;
        _droppedRecords = 0;
        if (dropped > 0) {
          await _append(
            LogLevel.warn,
            'dropped $dropped log records (queue or record limit)',
            DateTime.now().toUtc().toIso8601String(),
            const LogContext(eventType: 'daemon.log_dropped'),
          );
        }
      } finally {
        _queuedRecords--;
        _queuedBytes -= reservedBytes;
      }
    });
    _writeQueue = op.catchError((_) {});
    await op;
  }

  void _dropRecord() {
    if (_droppedRecords < 0x7FFFFFFFFFFFFFFF) _droppedRecords++;
  }

  Future<void> _append(
    LogLevel level,
    String message,
    String timestamp,
    LogContext context,
  ) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await _rotateIfNeeded(file);
    final record = <String, Object?>{
      'timestamp': timestamp,
      'level': level.name,
      'component': context.component,
      'vm_id': context.vmId?.value,
      'operation_id': context.operationId?.value,
      'driver_generation': context.driverGeneration,
      'request_id': context.requestId?.value,
      'event_type': context.eventType,
      'message': message,
      if (context.testRunId != null) 'test_run_id': context.testRunId!.value,
      if (context.errorType != null) 'error_type': context.errorType,
    };
    await file.writeAsString(
      '${jsonEncode(record)}\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) {
      return;
    }
    final stat = await file.stat();
    if (stat.size < maxBytes) {
      return;
    }

    final oldest = File('$path.$maxRotations');
    if (await oldest.exists()) {
      await oldest.delete();
    }
    for (var i = maxRotations - 1; i >= 1; i--) {
      final src = File('$path.$i');
      if (await src.exists()) {
        await src.rename('$path.${i + 1}');
      }
    }
    await file.rename('$path.1');
  }
}
