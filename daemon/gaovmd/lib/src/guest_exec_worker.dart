import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_application_service.dart';
import 'guest_bridge_client.dart';
import 'guest_exec_application_service.dart';
import 'guest_exec_repository.dart';
import 'guest_exec_request.dart';
import 'host_guest_artifacts.dart';
import 'host_guest_session.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

typedef GuestExecConnectionResolver =
    GuestControlConnection? Function(VmId vmId, int generation);

/// One counted original attempt per job. Public handlers accept durable intent;
/// this worker owns guest IO outside the controller's short database gate.
final class GuestExecWorker {
  GuestExecWorker({
    required this.database,
    required this.acceptance,
    required this.artifacts,
    required this.budget,
    required this.resolveConnection,
    required this.maxInFlight,
    Duration pollInterval = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : _pollInterval = pollInterval,
       _now = now ?? DateTime.now {
    if (maxInFlight < 1 || pollInterval <= Duration.zero)
      throw ArgumentError('invalid guest worker policy');
    if (!identical(database, artifacts.database))
      throw ArgumentError('guest worker catalog differs');
  }
  final GaoVmDatabase database;
  final GuestExecApplicationService acceptance;
  final ArtifactApplicationService artifacts;
  final GuestArtifactBudget budget;
  final GuestExecConnectionResolver resolveConnection;
  final int maxInFlight;
  final Duration _pollInterval;
  final DateTime Function() _now;
  final Map<OperationId, _ExecOwner> _owners = {};
  bool _closed = false;
  Future<void>? _closeFuture;
  ArtifactPublicationFailure? _cleanupFailure;
  Future<void>? _recovery;
  bool _recovered = false;
  bool _hasRun = false;
  String _dispatchCursor = '';
  Future<int>? _dispatchFuture;

  /// Scans committed intent, reserving bounded local owners without awaiting
  /// guest IO. Reporting callbacks must not throw. Started foreign jobs are
  /// never adopted: only the startup retirement barrier may settle them.
  Future<int> dispatchOnce({
    required void Function(Operation, VmId, int) onComplete,
    required void Function(OperationId, Object, StackTrace) onError,
    int limit = 100,
  }) {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (_closed) return Future.value(0);
    return _dispatchFuture ??= _dispatch(limit, onComplete, onError)
        .whenComplete(() {
          _dispatchFuture = null;
        });
  }

  Future<int> _dispatch(
    int limit,
    void Function(Operation, VmId, int) onComplete,
    void Function(OperationId, Object, StackTrace) onError,
  ) async {
    if (_recovery != null && !_recovered)
      throw StateError('guest startup recovery has not succeeded');
    _hasRun = true;
    await _ackTerminalWork(limit);
    if (_closed || _owners.length >= maxInFlight) return 0;
    final jobs = await database.read(
      (db) => [
        for (final row in db.select(
          '''
        SELECT operation_id, vm_id, driver_generation FROM guest_exec_jobs
        WHERE started_at IS NULL AND completed_at IS NULL AND operation_id > ?
        ORDER BY operation_id LIMIT ?
      ''',
          [_dispatchCursor, limit],
        ))
          (
            id: OperationId(row['operation_id'] as String),
            vmId: VmId(row['vm_id'] as String),
            generation: row['driver_generation'] as int,
          ),
      ],
    );
    if (jobs.isEmpty) {
      _dispatchCursor = '';
      return 0;
    }
    var launched = 0;
    for (final job in jobs) {
      final id = job.id;
      if (_closed || _owners.length >= maxInFlight) break;
      _dispatchCursor = id.value;
      if (_owners.containsKey(id)) continue;
      unawaited(
        run(id).then<void>(
          (operation) {
            if (operation != null)
              onComplete(operation, job.vmId, job.generation);
          },
          onError: (Object error, StackTrace stack) =>
              onError(id, error, stack),
        ),
      );
      launched++;
    }
    return launched;
  }

  Future<void> _ackTerminalWork(int limit) => database.transaction((db) {
    final rows = db.select(
      r'''
      SELECT w.id FROM outbox w JOIN guest_exec_jobs j
        ON json_extract(w.payload_json, '$.operation_id') = j.operation_id
      WHERE w.topic = 'guest.exec' AND w.published_at IS NULL AND j.completed_at IS NOT NULL
        AND w.key = j.vm_id AND json_extract(w.payload_json, '$.version') = 1
        AND json_extract(w.payload_json, '$.vm_id') = j.vm_id
        AND json_extract(w.payload_json, '$.driver_generation') = j.driver_generation
        AND json_extract(w.payload_json, '$.spec_generation') = j.spec_generation
        AND json_extract(w.payload_json, '$.applied_intent_revision') = j.applied_intent_revision
      ORDER BY w.id LIMIT ?
    ''',
      [limit],
    );
    for (final row in rows)
      db.execute(
        'UPDATE outbox SET published_at = ? WHERE id = ? AND published_at IS NULL',
        [formatPersistenceTimestamp(_now().toUtc()), row['id']],
      );
  });

  /// Startup-only. The daemon supplies its real ownership/driver-census barrier
  /// before any current runtime or public listener activates. Missing a local
  /// worker is never sufficient evidence that a previous execution retired.
  Future<void> recoverInterrupted({
    required Future<void> Function() retireOriginalOwners,
  }) {
    if (_closed || _hasRun)
      throw StateError('guest recovery must precede worker activation');
    return _recovery ??= _recoverInterrupted(retireOriginalOwners).then((_) {
      _recovered = true;
    });
  }

  Future<void> _recoverInterrupted(
    Future<void> Function() retireOriginalOwners,
  ) async {
    await retireOriginalOwners();
    final jobs = SqliteGuestExecRepository(database);
    String cursor = '';
    while (true) {
      final ids = await database.read(
        (db) => [
          for (final row in db.select(
            'SELECT operation_id FROM guest_exec_jobs WHERE completed_at IS NULL AND operation_id > ? ORDER BY operation_id LIMIT 100',
            [cursor],
          ))
            OperationId(row['operation_id'] as String),
        ],
      );
      if (ids.isEmpty) return;
      for (final id in ids) {
        cursor = id.value;
        final job = (await jobs.get(id))!;
        if (job.completedAt != null) continue;
        if (job.startedAt == null) {
          if (!await jobs.cancelBeforeStart(id))
            await jobs.failBeforeStart(
              id,
              error: OperationError(
                code: ErrorCode.guestExecFailed,
                message: 'Daemon stopped before guest execution.',
                retryable: false,
                details: JsonObjectValue.fromJson({'outcome': 'not_started'}),
              ),
            );
          continue;
        }
        final attempt = job.attemptId;
        if (attempt == null)
          throw StateError('guest recovery has an invalid started marker');
        final epoch = job.controlEpochId;
        final result = await jobs.readTerminalResult(id, attempt);
        if (epoch != null &&
            result != null &&
            await _verifiedRecoveryResult(job, result) &&
            await jobs.completeAttempt(
              id,
              attemptId: attempt,
              controlEpochId: epoch,
            ))
          continue;
        final snapshot = await jobs.readTerminalSnapshot(id, attempt);
        await jobs.failAttempt(
          id,
          attemptId: attempt,
          error: OperationError(
            code: ErrorCode.guestExecFailed,
            message: snapshot == null
                ? 'Daemon stopped after guest execution was authorized; outcome is unknown.'
                : 'Guest execution diagnostics could not be recovered.',
            retryable: false,
            details: JsonObjectValue.fromJson({
              'outcome': snapshot == null
                  ? 'unknown'
                  : 'known_result_incomplete',
              'driver_generation': job.driverGeneration,
            }),
          ),
        );
      }
    }
  }

  Future<bool> _verifiedRecoveryResult(
    GuestExecJob job,
    JsonObjectValue result,
  ) async {
    for (final name in ['stdout', 'stderr']) {
      final output = result.toJson()[name] as Map;
      if (output['mode'] != 'artifact') continue;
      try {
        // download validates the held manifest/inode/size/hash before returning
        // and leaves no descriptor open in this unconsumed response stream.
        final download = await artifacts.download(
          ArtifactId(output['artifact_id'] as String),
        );
        final artifact = download.artifact;
        if (artifact.vmId != job.vmId ||
            artifact.operationId != job.operationId ||
            artifact.kind.name != name ||
            artifact.sizeBytes != output['size_bytes'])
          return false;
      } on ArtifactNotFoundException {
        return false;
      } on ArtifactContentUnavailable {
        return false;
      }
    }
    return true;
  }

  Future<Operation?> run(OperationId id) {
    if (_closed) return Future.error(StateError('guest exec worker is closed'));
    if (_recovery != null && !_recovered)
      return Future.error(
        StateError('guest startup recovery has not succeeded'),
      );
    _hasRun = true;
    final previous = _owners[id];
    if (previous != null) return previous.future;
    if (_owners.length >= maxInFlight)
      return Future.error(StateError('guest exec worker admission is full'));
    final owner = _ExecOwner();
    _owners[id] = owner;
    owner.future = _execute(id, owner).whenComplete(() {
      if (identical(_owners[id], owner)) _owners.remove(id);
    });
    return owner.future;
  }

  Future<Operation?> _execute(OperationId id, _ExecOwner owner) async {
    final jobs = SqliteGuestExecRepository(database);
    final operations = SqliteOperationRepository(database);
    final job = await jobs.get(id);
    if (job == null || job.completedAt != null) return operations.get(id);
    // A missing local owner is not evidence that an authorized attempt retired.
    if (job.startedAt != null) return null;
    if (job.cancellationRequested) {
      await jobs.cancelBeforeStart(id);
      return operations.get(id);
    }
    final connection = resolveConnection(job.vmId, job.driverGeneration);
    if (_closed ||
        connection == null ||
        !connection.isReady ||
        connection.correlation.vmId != job.vmId ||
        connection.correlation.driverGeneration != job.driverGeneration) {
      if (!await jobs.cancelBeforeStart(id))
        await jobs.failBeforeStart(
          id,
          error: OperationError(
            code: ErrorCode.guestAgentUnavailable,
            message: 'The original guest connection is unavailable.',
            retryable: false,
            details: JsonObjectValue.fromJson({'outcome': 'not_started'}),
          ),
        );
      return operations.get(id);
    }
    owner.connection = connection;
    final operation = (await operations.get(id))!;
    final request = GuestExecRequest.fromJson(operation.request.toJson());
    // Guest execution retains its requested budget. Separate bounded output
    // phases share a single additional 5/30/30-second completion allowance.
    final now = _now().toUtc();
    var duration = request.timeout + const Duration(seconds: 65);
    var deadlineAt = now.add(duration);
    if (operation.deadlineAt case final cap? when cap.isBefore(deadlineAt)) {
      deadlineAt = cap;
      duration = cap.difference(now);
    }
    if (duration <= Duration.zero) {
      if (!await jobs.cancelBeforeStart(id))
        await jobs.failBeforeStart(
          id,
          error: OperationError(
            code: ErrorCode.waitTimeout,
            message:
                'The original execution deadline expired before guest authorization.',
            retryable: false,
            details: JsonObjectValue.fromJson({
              'outcome': 'not_started',
              'timeout_scope': 'overall',
            }),
          ),
        );
      return operations.get(id);
    }
    final deadline = GuestBridgeDeadline.after(duration);
    final attemptId = RequestId.generate();
    final claimed = await acceptance.beginAttempt(
      id,
      attemptId: attemptId,
      controlEpochId: connection.epochId,
      stillCurrent: () =>
          !_closed && connection.isReady && deadline.remaining > Duration.zero,
      deadlineAt: deadlineAt,
    );
    if (claimed == null) {
      if (!await jobs.cancelBeforeStart(id))
        await jobs.failBeforeStart(
          id,
          error: OperationError(
            code: ErrorCode.vmOperationConflict,
            message:
                'The original VM execution checkpoint changed before guest execution.',
            retryable: false,
            details: JsonObjectValue.fromJson({'outcome': 'not_started'}),
          ),
        );
      return operations.get(id);
    }
    final testRunId = await database.read((db) {
      final rows = db.select(
        'SELECT test_run_id FROM test_run_step_execs WHERE operation_id = ?',
        [id.value],
      );
      return rows.isEmpty
          ? null
          : TestRunId(rows.single['test_run_id'] as String);
    });
    final service = owner.service = HostGuestArtifactService(
      database: database,
      artifacts: artifacts,
      budget: budget,
    );
    owner.monitor = _monitorCancellation(
      id,
      owner,
      connection,
      request,
      deadline,
    );
    Object? failure;
    try {
      await connection.execStart(
        operationId: id,
        request: request,
        deadline: deadline.capped(const Duration(seconds: 5)),
      );
      GuestExecArtifactReceipt? receipt;
      while (!_closed) {
        try {
          receipt = await service.captureExecStatus(
            connection: connection,
            operationId: id,
            attemptId: attemptId,
            request: request,
            deadline: deadline,
            responseTimeout: const Duration(seconds: 5),
          );
          break;
        } on GuestArtifactException catch (error) {
          if (error.code != GuestArtifactFailure.notTerminal) rethrow;
          await Future<void>.delayed(_pollInterval);
        }
      }
      if (receipt != null) {
        final outputs = receipt.result.toJson();
        var size = 0;
        for (final name in ['stdout', 'stderr']) {
          size += (outputs[name] as Map)['size_bytes'] as int;
        }
        if (size > 16 * 1024 * 1024)
          throw const GuestArtifactException(
            GuestArtifactFailure.limitExceeded,
          );
        final terminal = receipt;
        await Future.wait([
          for (final name in ['stdout', 'stderr'])
            if ((outputs[name] as Map)['mode'] == 'artifact')
              Future.sync(
                () => service.receiveOutput(
                  terminal,
                  output: name,
                  maxBytes: (outputs[name] as Map)['size_bytes'] as int,
                  testRunId: testRunId,
                ),
              ),
        ]);
      }
    } catch (error) {
      failure = error;
    } finally {
      owner.stopMonitor();
      await owner.monitor;
      try {
        await service.close();
      } on ArtifactPublicationFailure catch (error) {
        _cleanupFailure ??= error;
        failure = error;
      }
    }
    if (failure is! ArtifactPublicationFailure &&
        await jobs.completeAttempt(
          id,
          attemptId: attemptId,
          controlEpochId: connection.epochId,
        ))
      return operations.get(id);
    // Retire this original control owner before allowing another explicit job.
    // EOF/timeout is not a successful cancellation or proof of guest execution.
    await connection.close();
    final snapshot = await service.readExecSnapshot(id, attemptId);
    await jobs.failAttempt(
      id,
      attemptId: attemptId,
      error: OperationError(
        code: ErrorCode.guestExecFailed,
        message: snapshot == null
            ? 'Guest execution outcome is unknown.'
            : 'Guest execution diagnostics could not be published.',
        retryable: false,
        details: JsonObjectValue.fromJson({
          'outcome': snapshot == null ? 'unknown' : 'known_result_incomplete',
          'driver_generation': job.driverGeneration,
        }),
      ),
    );
    if (failure is ArtifactPublicationFailure) throw failure;
    return operations.get(id);
  }

  Future<void> _monitorCancellation(
    OperationId id,
    _ExecOwner owner,
    GuestControlConnection connection,
    GuestExecRequest request,
    GuestBridgeDeadline deadline,
  ) async {
    var sent = false;
    try {
      while (!owner.monitorStopped && !_closed) {
        final wake = owner.monitorWake = Completer<void>();
        owner.monitorTimer = Timer(_pollInterval, wake.complete);
        await wake.future;
        owner.monitorTimer = null;
        owner.monitorWake = null;
        if (owner.monitorStopped || _closed) return;
        final job = await SqliteGuestExecRepository(database).get(id);
        if (owner.monitorStopped || _closed) return;
        if (job == null || job.completedAt != null) {
          await connection.close();
          return;
        }
        if (job.cancellationRequested && !sent) {
          sent = true;
          await connection.execCancel(
            operationId: id,
            request: request,
            deadline: deadline.capped(const Duration(seconds: 5)),
          );
        }
      }
    } catch (_) {
      // Cancellation IO failure cannot confirm cleanup. Fence the original
      // owner so the status path settles as unknown unless already durable.
      await connection.close();
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    final dispatch = _dispatchFuture;
    final recovery = _recovery;
    final owners = List<_ExecOwner>.of(_owners.values);
    for (final owner in owners) {
      owner.stopMonitor();
    }
    await Future.wait([
      if (recovery != null) recovery,
      if (dispatch != null) dispatch.then<void>((_) {}),
      for (final owner in owners)
        if (owner.connection case final connection?) connection.close(),
      for (final owner in owners)
        if (owner.service case final service?) service.close(),
      for (final owner in owners) owner.future.then<void>((_) {}),
    ]);
    if (_cleanupFailure case final failure?) throw failure;
  }
}

final class _ExecOwner {
  late Future<Operation?> future;
  GuestControlConnection? connection;
  HostGuestArtifactService? service;
  Future<void>? monitor;
  Timer? monitorTimer;
  Completer<void>? monitorWake;
  bool monitorStopped = false;
  void stopMonitor() {
    monitorStopped = true;
    monitorTimer?.cancel();
    if (monitorWake case final wake? when !wake.isCompleted) wake.complete();
  }
}
