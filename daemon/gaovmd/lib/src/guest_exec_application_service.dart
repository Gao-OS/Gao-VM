import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'guest_exec_request.dart';
import 'guest_exec_repository.dart';
import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';

final class GuestExecCommand {
  GuestExecCommand({
    required this.vmId,
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.request,
  }) : requestBody = List<int>.unmodifiable(requestBody) {
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255)) {
      throw ArgumentError('invalid idempotency key');
    }
    if (this.requestBody.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('request body must contain bytes');
    }
  }

  final VmId vmId;
  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final GuestExecRequest request;
}

final class GuestExecAdmissionException implements Exception {
  const GuestExecAdmissionException(this.code, this.vmId);

  final ErrorCode code;
  final VmId vmId;

  @override
  String toString() => 'guest execution is not admissible: ${code.name}';
}

typedef GuestExecControllerResolver = Future<VmController?> Function(VmId vmId);

/// Accepts durable intent only. Guest IO is dispatched after this transaction,
/// never by a public handler or while the controller's write gate is held.
final class GuestExecApplicationService implements OperationMutationAcceptor {
  GuestExecApplicationService({
    required GaoVmDatabase database,
    required GuestExecControllerResolver resolveController,
    Duration idempotencyRetention = const Duration(days: 1),
    DateTime Function()? now,
  }) : _database = database,
       _resolveController = resolveController,
       _now = now ?? DateTime.now,
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
         now: now,
       );

  final GaoVmDatabase _database;
  final GuestExecControllerResolver _resolveController;
  final DateTime Function() _now;
  final SqliteIdempotencyRepository _idempotency;

  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('guest exec cancellation must own its commit boundary');
    }
    return _database.transaction((connection) async {
      Future<IdempotencyResponse> accept() async {
        final operations = SqliteOperationRepository(_database, now: _now);
        final target = await operations.get(command.operationId);
        if (target == null)
          throw OperationNotFoundException(command.operationId);
        final job = await SqliteGuestExecRepository(_database).get(target.id);
        if (target.type != 'guest.exec' ||
            target.resourceType != ResourceType.virtualMachine ||
            !target.cancellable ||
            (target.state != OperationState.pending &&
                target.state != OperationState.running) ||
            job == null ||
            job.completedAt != null ||
            job.vmId != target.resourceId) {
          throw OperationNotCancellableException(target.id);
        }
        connection.execute(
          'UPDATE guest_exec_jobs SET cancellation_requested = 1 WHERE operation_id = ?',
          [target.id.value],
        );
        final action = await operations.create(
          type: 'operation.cancel',
          resourceType: ResourceType.operation,
          resourceId: target.id,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: false,
          request: JsonObjectValue.fromJson({
            'vm_id': job.vmId.value,
            'driver_generation': job.driverGeneration,
          }),
        );
        connection.execute(
          'INSERT INTO guest_exec_cancellations(action_id, target_id) VALUES (?, ?)',
          [action.id.value, target.id.value],
        );
        connection.execute(
          "INSERT INTO outbox(topic, key, payload_json, created_at) VALUES ('guest.exec', ?, ?, ?)",
          [
            job.vmId.value,
            jsonEncode({
              'version': 1,
              'vm_id': job.vmId.value,
              'operation_id': target.id.value,
              'driver_generation': job.driverGeneration,
              'spec_generation': job.specGeneration,
              'applied_intent_revision': job.appliedIntentRevision,
            }),
            formatPersistenceTimestamp(action.createdAt),
          ],
        );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(action).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: 'POST /v1/operations/${command.operationId.value}/cancel',
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      final acceptance = OperationAcceptance.fromJson(response.toJson());
      if (acceptance.resourceType != ResourceType.operation ||
          acceptance.resourceId != command.operationId) {
        throw const FormatException('guest exec cancellation target mismatch');
      }
      return acceptance;
    });
  }

  Future<OperationAcceptance> execute(GuestExecCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('guest exec acceptance must own its commit boundary');
    }
    final replay = await _replay(command);
    if (replay != null) return replay;
    try {
      final controller = await _resolveController(command.vmId);
      if (controller == null) throw VmNotFoundException(command.vmId);
      return await controller.accept(_GuestExecAcceptance(this, command));
    } catch (error) {
      if (error is VmNotFoundException ||
          error is VmControllerClosedException ||
          error is VmRegistryClosedException) {
        final replay = await _replay(command);
        if (replay != null) return replay;
      }
      rethrow;
    }
  }

  /// Internal TestRun application path. The request and original VM checkpoint
  /// come from the catalog, never a caller-supplied replacement or driver RPC.
  Future<OperationAcceptance> executeStep(
    TestRunId id, {
    required int index,
  }) async {
    if (_database.hasActiveCallerTransaction)
      throw StateError('step acceptance must own its commit');
    final replay = await _stepReplay(id, index);
    if (replay != null) return replay;
    final run = await SqliteTestRunRepository(_database).get(id);
    if (run == null) throw TestRunNotFoundException(id);
    if (index < 0 || index >= run.steps.length)
      throw RangeError.index(index, run.steps);
    if (run.vmId == null)
      throw TestRunConflictException(id, 'step has no original VM');
    final parent = (await SqliteOperationRepository(
      _database,
    ).get(run.operationId))!;
    final step = run.steps[index].request;
    final request = GuestExecRequest.fromJson({
      'argv': step.argv,
      'cwd': step.cwd,
      'env': step.env,
      'timeout_seconds': step.timeoutSeconds,
      'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 65536},
    });
    final controller = await _resolveController(run.vmId!);
    if (controller == null) throw VmNotFoundException(run.vmId!);
    return controller.accept(
      _GuestExecAcceptance(
        this,
        GuestExecCommand(
          vmId: run.vmId!,
          requestId: parent.requestId,
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(request.toJson())),
          request: request,
        ),
        step: (id, index),
      ),
    );
  }

  Future<OperationAcceptance?> _stepReplay(TestRunId id, int index) async {
    final ids = await _database.read(
      (db) => db
          .select(
            'SELECT operation_id FROM test_run_step_execs WHERE test_run_id = ? AND step_index = ?',
            [id.value, index],
          )
          .map((row) => OperationId(row['operation_id'] as String))
          .toList(),
    );
    if (ids.isEmpty) return null;
    return OperationAcceptance.fromOperation(
      (await SqliteOperationRepository(_database).get(ids.single))!,
    );
  }

  /// The worker commits this marker while owning the original connection. Only
  /// its first successful claim may send exec.start; no retry renews the attempt.
  Future<GuestExecJob?> beginAttempt(
    OperationId operationId, {
    required RequestId attemptId,
    required RequestId controlEpochId,
    required bool Function() stillCurrent,
    DateTime? deadlineAt,
  }) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('guest exec attempt must own its commit boundary');
    }
    final job = await SqliteGuestExecRepository(_database).get(operationId);
    if (job == null ||
        job.startedAt != null ||
        job.completedAt != null ||
        !stillCurrent())
      return null;
    final controller = await _resolveController(job.vmId);
    if (controller == null) return null;
    try {
      return await controller.accept(
        _GuestExecAttempt(
          this,
          job,
          attemptId,
          controlEpochId,
          stillCurrent,
          deadlineAt,
        ),
      );
    } on GuestExecAttemptSuperseded {
      return null;
    }
  }

  static String _scope(GuestExecCommand command) =>
      'POST /v1/vms/${command.vmId.value}/guest/exec';

  static OperationAcceptance _decode(
    GuestExecCommand command,
    JsonObjectValue response,
  ) {
    final acceptance = OperationAcceptance.fromJson(response.toJson());
    if (acceptance.resourceType != ResourceType.virtualMachine ||
        acceptance.resourceId != command.vmId) {
      throw const FormatException('guest exec acceptance target mismatch');
    }
    return acceptance;
  }

  Future<OperationAcceptance?> _replay(GuestExecCommand command) async {
    final key = command.idempotencyKey;
    if (key == null) return null;
    final stored = await _idempotency.lookup(
      scope: _scope(command),
      key: key,
      requestBody: command.requestBody,
    );
    return stored == null ? null : _decode(command, stored.response);
  }
}

final class _GuestExecAttempt implements VmAcceptanceAction<GuestExecJob?> {
  const _GuestExecAttempt(
    this.service,
    this.job,
    this.attemptId,
    this.controlEpochId,
    this.stillCurrent,
    this.deadlineAt,
  );
  final GuestExecApplicationService service;
  final GuestExecJob job;
  final RequestId attemptId;
  final RequestId controlEpochId;
  final bool Function() stillCurrent;
  final DateTime? deadlineAt;

  @override
  Future<VmAcceptedIntent<GuestExecJob?>> commit(
    VmControllerState state,
  ) async {
    if (state.vmId != job.vmId)
      throw ArgumentError('guest exec attempt controller mismatch');
    final started =
        await SqliteGuestExecRepository(
          service._database,
          now: service._now,
        ).beginAttempt(
          job.operationId,
          attemptId: attemptId,
          controlEpochId: controlEpochId,
          executionState: state,
          stillCurrent: stillCurrent,
          deadlineAt: deadlineAt,
        );
    return VmAcceptedIntent(
      intentRevision: state.appliedIntentRevision,
      result: started,
    );
  }
}

final class _GuestExecAcceptance
    implements VmAcceptanceAction<OperationAcceptance> {
  const _GuestExecAcceptance(this.service, this.command, {this.step});

  final GuestExecApplicationService service;
  final GuestExecCommand command;
  final (TestRunId, int)? step;

  @override
  Future<VmAcceptedIntent<OperationAcceptance>> commit(
    VmControllerState state,
  ) async {
    if (state.vmId != command.vmId) {
      throw ArgumentError('guest exec target does not match its controller');
    }
    if (service._database.hasActiveCallerTransaction) {
      throw StateError('controller acceptance must own its commit boundary');
    }
    return service._database.transaction((connection) async {
      Future<IdempotencyResponse> accept() async {
        DateTime? parentDeadline;
        if (step case (final id, final index)) {
          final replay = await service._stepReplay(id, index);
          if (replay != null)
            return IdempotencyResponse(
              JsonObjectValue.fromJson(replay.toJson()),
            );
          final run = (await SqliteTestRunRepository(
            service._database,
          ).get(id))!;
          final parent = (await SqliteOperationRepository(
            service._database,
          ).get(run.operationId))!;
          final bindings = connection.select(
            '''
            SELECT b.driver_generation, b.intent_revision, o.state, o.type, o.resource_id, o.request_json
            FROM test_run_vm_start b JOIN operations o ON o.id = b.operation_id
            WHERE b.test_run_id = ? AND b.vm_id = ?
          ''',
            [id.value, command.vmId.value],
          );
          if (run.state != TestRunState.runningSteps ||
              run.vmId != command.vmId ||
              parent.state != OperationState.running ||
              (parent.deadlineAt != null &&
                  !service._now().toUtc().isBefore(parent.deadlineAt!)) ||
              bindings.isEmpty) {
            throw TestRunConflictException(
              id,
              'step original execution context is unavailable',
            );
          }
          final binding = bindings.single;
          final startRequest =
              jsonDecode(binding['request_json'] as String) as Map;
          final catalog = connection.select(
            'SELECT intent_revision, spec_generation FROM vms WHERE id = ?',
            [command.vmId.value],
          ).single;
          if (binding['state'] != 'succeeded' ||
              binding['type'] != 'vm.start' ||
              binding['resource_id'] != command.vmId.value ||
              binding['driver_generation'] != state.activeDriverGeneration ||
              binding['intent_revision'] != state.appliedIntentRevision ||
              catalog['intent_revision'] != binding['intent_revision'] ||
              catalog['spec_generation'] != startRequest['spec_generation'] ||
              startRequest['intent_revision'] != state.appliedIntentRevision ||
              startRequest['spec_generation'] != state.activeSpecGeneration) {
            throw TestRunConflictException(
              id,
              'step original VM generation or checkpoint changed',
            );
          }
          parentDeadline = parent.deadlineAt;
          await SqliteTestRunRepository(
            service._database,
            now: service._now,
          ).startStep(id, index: index);
        }
        Never reject(ErrorCode code) =>
            throw GuestExecAdmissionException(code, command.vmId);
        final rows = connection.select(
          '''
          SELECT v.deleted_at, v.deleting_at, r.desired_state, r.phase,
            r.driver_generation, r.observed_generation, r.applied_intent_revision,
            r.guest_agent, s.spec_json
          FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
          LEFT JOIN vm_specs s ON s.vm_id = v.id AND s.generation = r.observed_generation
          WHERE v.id = ?
        ''',
          [command.vmId.value],
        );
        if (rows.isEmpty || rows.single['deleted_at'] != null) {
          throw VmNotFoundException(command.vmId);
        }
        final row = rows.single;
        if (row['deleting_at'] != null ||
            state.deletionState != VmDeletionState.active) {
          reject(ErrorCode.vmOperationConflict);
        }
        if (row['desired_state'] != 'running' ||
            row['phase'] != 'running' ||
            state.desiredState != DesiredState.running ||
            state.phase != VmPhase.running) {
          reject(ErrorCode.vmNotRunning);
        }
        final generation = state.activeDriverGeneration;
        final specGeneration = state.activeSpecGeneration;
        if (generation == null ||
            generation != state.driverGeneration ||
            row['driver_generation'] != generation ||
            specGeneration == null ||
            row['observed_generation'] != specGeneration ||
            row['applied_intent_revision'] != state.appliedIntentRevision ||
            (state.currentOperation != null &&
                !state.currentOperation!.isTerminal)) {
          reject(ErrorCode.vmOperationConflict);
        }
        final specJson = row['spec_json'] as String?;
        if (specJson == null ||
            !VmSpec.fromJson(
              Map<String, Object?>.from(jsonDecode(specJson) as Map),
            ).guestAgent.enabled ||
            row['guest_agent'] != GuestAgentState.ready.name) {
          reject(ErrorCode.guestAgentUnavailable);
        }
        if (connection
            .select(
              '''
          SELECT 1 FROM guest_exec_jobs WHERE vm_id = ? AND completed_at IS NULL
        ''',
              [command.vmId.value],
            )
            .isNotEmpty) {
          reject(ErrorCode.vmOperationConflict);
        }
        final operation =
            await SqliteOperationRepository(
              service._database,
              now: service._now,
            ).create(
              type: 'guest.exec',
              resourceType: ResourceType.virtualMachine,
              resourceId: command.vmId,
              requestId: command.requestId,
              idempotencyKey: command.idempotencyKey,
              cancellable: true,
              request: JsonObjectValue.fromJson(command.request.toJson()),
              deadlineAt: parentDeadline,
            );
        final timestamp = formatPersistenceTimestamp(operation.createdAt);
        connection.execute(
          '''
          INSERT INTO guest_exec_jobs(
            operation_id, vm_id, driver_generation, spec_generation,
            applied_intent_revision, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
          [
            operation.id.value,
            command.vmId.value,
            generation,
            specGeneration,
            state.appliedIntentRevision,
            timestamp,
          ],
        );
        connection.execute(
          '''
          INSERT INTO outbox(topic, key, payload_json, created_at) VALUES ('guest.exec', ?, ?, ?)
        ''',
          [
            command.vmId.value,
            jsonEncode({
              'version': 1,
              'vm_id': command.vmId.value,
              'operation_id': operation.id.value,
              'driver_generation': generation,
              'spec_generation': specGeneration,
              'applied_intent_revision': state.appliedIntentRevision,
            }),
            timestamp,
          ],
        );
        if (step case (final id, final index))
          connection.execute(
            'INSERT INTO test_run_step_execs(test_run_id, step_index, operation_id) VALUES (?, ?, ?)',
            [id.value, index, operation.id.value],
          );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(operation).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await service._idempotency.execute(
              scope: GuestExecApplicationService._scope(command),
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      return VmAcceptedIntent(
        intentRevision: state.appliedIntentRevision,
        result: GuestExecApplicationService._decode(command, response),
      );
    });
  }
}
