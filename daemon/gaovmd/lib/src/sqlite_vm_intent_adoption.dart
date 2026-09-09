import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'sqlite_vm_state_effect_adapter.dart';
import 'vm_command_repository.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_repository.dart';

/// Database-only adoption, invoked by [VmController.adopt] in its FIFO lane.
/// [effectRunner] must use this same catalog for its durable repositories.
/// The returned effects are deliberately not executed until after commit.
final class SqliteVmIntentAdoption implements VmIntentAdoptionAction {
  const SqliteVmIntentAdoption({
    required GaoVmDatabase database,
    required this.record,
    required TransactionalVmEffectRunner effectRunner,
  }) : _database = database,
       _effectRunner = effectRunner;

  final GaoVmDatabase _database;
  final VmCommandRecord record;
  final TransactionalVmEffectRunner _effectRunner;

  /// Proves a redelivery was checkpointed even after VM deletion. Owns a
  /// read-only transaction so command, operation and checkpoint cannot drift.
  static Future<bool> isDurablyAdopted({
    required GaoVmDatabase database,
    required VmCommandRecord record,
  }) {
    if (database.hasActiveCallerTransaction) {
      throw StateError('adoption proof must own its transaction boundary');
    }
    return database.transaction((_) async {
      final validated = await _readDurableIntent(database, record);
      return validated.revision <= validated.applied;
    });
  }

  @override
  Future<VmIntentAdoption> commit(VmControllerState executionState) {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('intent adoption must own its commit boundary');
    }
    if (executionState.vmId != record.vmId) {
      throw ArgumentError('intent does not belong to this controller');
    }
    return _database.transaction((db) async {
      final validated = await _readDurableIntent(_database, record);
      final revision = validated.revision;
      final generation = validated.generation;
      final applied = validated.applied;
      final source = validated.source;
      final operation = validated.operation;
      final operations = SqliteOperationRepository(_database);
      if (applied != executionState.appliedIntentRevision) {
        throw StateError(
          'controller execution disagrees with durable checkpoint',
        );
      }
      if (revision <= applied) {
        return _unchanged(
          executionState,
          VmIntentAdoptionDisposition.duplicate,
        );
      }
      if (revision != applied + 1 || revision > validated.accepted) {
        throw StateError('intent adoption must follow consecutive revisions');
      }
      if (validated.deleted) throw VmNotFoundException(record.vmId);

      final current = executionState.currentOperation;
      final terminal = _isTerminal(operation.state);
      if (current != null &&
          !current.isTerminal &&
          (terminal ||
              record.action == VmCommandAction.start ||
              record.action == VmCommandAction.restart ||
              record.action == VmCommandAction.patch)) {
        return _unchanged(executionState, VmIntentAdoptionDisposition.deferred);
      }
      final persistence = SqliteVmStateEffectAdapter(_database);
      VmControllerState next;
      final remaining = <VmEffect>[];
      final prefix = <VmEffect>[];
      if (record.action == VmCommandAction.patch) {
        // Patches do not replace the lifecycle operation. The accepted spec is
        // adopted after any in-progress lifecycle settles, without driver IO.
        final patch = source as SpecUpdated;
        next = executionState.copyWith(appliedIntentRevision: revision);
        if (!terminal) {
          next = next.copyWith(
            specGeneration: patch.specGeneration,
            restartPolicy: patch.restartPolicy,
            restartRequired:
                next.restartRequired ||
                next.activeDriverGeneration != null && patch.restartRequired,
          );
          if (operation.state == OperationState.pending)
            await operations.start(operation.id);
          await operations.succeed(operation.id);
        }
      } else if (terminal) {
        // A cancelled/failed queued command consumes its revision without
        // applying its desired state or spec. Preserve the actual execution.
        next = executionState.copyWith(
          appliedIntentRevision: revision,
          currentOperation: VmControllerOperation(
            id: operation.id,
            kind: VmOperationKind.values.byName(record.action.name),
            state: operation.state,
          ),
        );
      } else {
        final specs = db.select(
          'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
          [record.vmId.value, generation],
        );
        if (specs.isEmpty) throw StateError('pinned intent spec is missing');
        final spec = VmSpec.fromJson(
          jsonDecode(specs.single['spec_json'] as String),
        );
        final prepared = executionState.copyWith(
          appliedIntentRevision: revision,
          specGeneration: generation,
          restartPolicy: spec.restartPolicy,
          restartRequired:
              executionState.restartRequired ||
              executionState.activeDriverGeneration != null &&
                  generation != executionState.observedGeneration,
        );
        final transition = reduce(prepared, source);
        next = transition.state;
        if (next.currentOperation case final active?
            when active.id != operation.id && !active.isTerminal) {
          return _unchanged(
            executionState,
            VmIntentAdoptionDisposition.deferred,
          );
        }
        var externalBoundary = false;
        for (final effect in transition.effects) {
          final timer =
              effect is CancelRetry ||
              effect is ScheduleRetry ||
              effect is ScheduleStableReset;
          if (!externalBoundary && _effectRunner.isDurable(effect)) {
            prefix.add(effect);
          } else {
            remaining.add(effect);
            if (!timer) externalBoundary = true;
          }
        }
        // No-op and rejected actions do not replace currentOperation in the
        // reducer. Their delivered operation still needs an exact checkpoint.
        for (final effect in prefix) {
          if (effect.operationId != operation.id) continue;
          final state = switch (effect) {
            CompleteOperation(:final cancelled) =>
              cancelled ? OperationState.cancelled : OperationState.succeeded,
            FailOperation() => OperationState.failed,
            _ => null,
          };
          if (state != null) {
            next = next.copyWith(
              currentOperation: VmControllerOperation(
                id: operation.id,
                kind: VmOperationKind.values.byName(record.action.name),
                state: state,
              ),
            );
          }
        }
        if (operation.state == OperationState.pending)
          await operations.start(operation.id);
        if (prefix.isNotEmpty) {
          final results = await _effectRunner.runDurableBatch(prefix, next);
          if (results.any((result) => result != null)) {
            throw StateError(
              'lifecycle adoption prefix returned an asynchronous command',
            );
          }
        }
      }
      // Always checkpoint, even when the ordinary reducer only completed an
      // operation or began its effect list with a timer cancellation.
      await persistence.persistVm(next);
      await persistence.persistRuntime(next);
      await SqliteEventRepository(_database).append(
        type: terminal ? 'vm.command_skipped' : 'vm.command_adopted',
        resourceType: ResourceType.virtualMachine,
        resourceId: record.vmId,
        vmId: record.vmId,
        operationId: operation.id,
        payload: JsonObjectValue.fromJson({'intent_revision': revision}),
      );
      return VmIntentAdoption(
        disposition: VmIntentAdoptionDisposition.adopted,
        state: next,
        remainingEffects: remaining,
        sourceCommand: source,
      );
    });
  }
}

Future<
  ({
    int revision,
    int generation,
    int applied,
    int accepted,
    bool deleted,
    Operation operation,
    VmCommand source,
  })
>
_readDurableIntent(
  GaoVmDatabase database,
  VmCommandRecord record,
) => database.read((db) async {
  final commandRows = db.select(
    'SELECT key, payload_json FROM outbox WHERE topic = ? AND id = ?',
    [vmCommandOutboxTopic, record.id],
  );
  if (commandRows.isEmpty) throw StateError('durable command is missing');
  final envelope = jsonDecode(commandRows.single['payload_json'] as String);
  if (envelope is! Map<String, dynamic> ||
      envelope['version'] is! int ||
      envelope['version'] != 1 ||
      envelope['vm_id'] != record.vmId.value ||
      commandRows.single['key'] != record.vmId.value ||
      envelope['operation_id'] != record.operationId.value ||
      envelope['action'] != record.action.name ||
      envelope['payload'] is! Map<String, dynamic>) {
    throw StateError('durable command correlation is invalid');
  }
  final payload = envelope['payload'] as Map<String, dynamic>;
  final revision = _positiveInt(payload['intent_revision']);
  final generation = _positiveInt(payload['spec_generation']);
  if (JsonObjectValue.fromJson(payload) != record.payload) {
    throw StateError('delivered command payload differs from durable intent');
  }
  final source = _sourceCommand(record);
  final desired = switch (record.action) {
    VmCommandAction.start || VmCommandAction.restart => 'running',
    VmCommandAction.patch => payload['desired_state'],
    _ => 'stopped',
  };
  if (payload['desired_state'] != desired ||
      !const ['running', 'stopped'].contains(desired)) {
    throw StateError('durable command desired state contradicts its action');
  }
  final vmRows = db.select(
    '''SELECT v.intent_revision, v.deleted_at, r.applied_intent_revision
      FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ?''',
    [record.vmId.value],
  );
  if (vmRows.isEmpty) throw VmNotFoundException(record.vmId);
  final vm = vmRows.single;
  final applied = vm['applied_intent_revision'] as int;
  if (applied < 0 ||
      applied > (vm['intent_revision'] as int) ||
      revision > (vm['intent_revision'] as int)) {
    throw StateError('durable checkpoint exceeds accepted intent');
  }
  final operations = SqliteOperationRepository(database);
  final operation = await operations.get(record.operationId);
  if (operation == null ||
      operation.resourceType != ResourceType.virtualMachine ||
      operation.resourceId != record.vmId ||
      operation.type != 'vm.${record.action.name}' ||
      operation.request.toJson()['intent_revision'] != revision ||
      operation.request.toJson()['spec_generation'] != generation) {
    throw StateError('durable command operation correlation is invalid');
  }
  if (record.action == VmCommandAction.patch &&
      operation.request != record.payload) {
    throw StateError('patch command differs from its durable operation');
  }

  final specs = db.select(
    'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
    [record.vmId.value, generation],
  );
  if (specs.isEmpty) throw StateError('pinned intent spec is missing');
  final spec = VmSpec.fromJson(jsonDecode(specs.single['spec_json'] as String));
  if (record.action == VmCommandAction.patch &&
      payload['restart_policy'] != spec.restartPolicy.name) {
    throw StateError('patch restart policy contradicts pinned spec');
  }
  return (
    revision: revision,
    generation: generation,
    applied: applied,
    accepted: vm['intent_revision'] as int,
    deleted: vm['deleted_at'] != null,
    operation: operation,
    source: source,
  );
});

VmIntentAdoption _unchanged(
  VmControllerState state,
  VmIntentAdoptionDisposition disposition,
) => VmIntentAdoption(
  disposition: disposition,
  state: state,
  remainingEffects: const [],
);

int _positiveInt(Object? value) {
  if (value is! int || value < 1)
    throw const FormatException('invalid intent revision or spec generation');
  return value;
}

bool _isTerminal(OperationState state) =>
    state != OperationState.pending && state != OperationState.running;

VmCommand _sourceCommand(VmCommandRecord record) => switch (record.action) {
  VmCommandAction.start => StartRequested(record.operationId),
  VmCommandAction.stop => StopRequested(record.operationId),
  VmCommandAction.restart => RestartRequested(record.operationId),
  VmCommandAction.kill => KillRequested(record.operationId),
  VmCommandAction.delete => DeleteRequested(record.operationId),
  VmCommandAction.patch => SpecUpdated(
    specGeneration: _positiveInt(record.payload.toJson()['spec_generation']),
    restartPolicy: RestartPolicy.values.byName(
      record.payload.toJson()['restart_policy'] as String,
    ),
    restartRequired: record.payload.toJson()['restart_required'] as bool,
  ),
  _ => throw ArgumentError('not a lifecycle intent'),
};
