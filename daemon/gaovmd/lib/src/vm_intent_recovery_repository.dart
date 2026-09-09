import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_command_repository.dart';
import 'vm_controller_reducer.dart';
import 'vm_repository.dart';

final class VmIntentRecoverySnapshot {
  const VmIntentRecoverySnapshot({
    required this.executionState,
    required this.acceptedIntentRevision,
    required this.hasUnpublishedCommands,
  });
  final VmControllerState executionState;
  final int acceptedIntentRevision;
  final bool hasUnpublishedCommands;
}

abstract interface class VmIntentRecoveryRepository {
  /// Returns null only for a legacy VM without accepted-command history.
  Future<VmIntentRecoverySnapshot?> restore(VmId vmId);

  Future<bool> hasUnpublishedCommands(VmId vmId);

  /// Allows the applied operation to finish when the next FIFO intent cannot
  /// be adopted until it is terminal. Superseding heads retain precedence.
  Future<bool> shouldDeferReconciliation(VmControllerState executionState);
}

/// Restores execution independently of the newer accepted catalog intent.
/// Reads one SQLite snapshot and never starts/fails operations or consumes work.
final class SqliteVmIntentRecoveryRepository
    implements VmIntentRecoveryRepository {
  const SqliteVmIntentRecoveryRepository(this._database);
  final GaoVmDatabase _database;

  @override
  Future<bool> shouldDeferReconciliation(
    VmControllerState executionState,
  ) => _database.transaction((db) async {
    final vmId = executionState.vmId;
    if (!await hasUnpublishedCommands(vmId)) return false;
    final current = executionState.currentOperation;
    if (current == null || current.isTerminal) return true;
    final restored = await restore(vmId);
    final checkpoint = restored?.executionState;
    if (checkpoint == null ||
        checkpoint.appliedIntentRevision !=
            executionState.appliedIntentRevision ||
        checkpoint.currentOperation?.id != current.id ||
        checkpoint.currentOperation?.state != current.state ||
        checkpoint.currentOperation?.kind != current.kind ||
        checkpoint.desiredState != executionState.desiredState ||
        checkpoint.specGeneration != executionState.specGeneration) {
      throw StateError(
        'controller execution disagrees with durable recovery checkpoint',
      );
    }
    final rows = db.select(
      '''SELECT id, key, payload_json, published_at FROM outbox
      WHERE topic = ? AND key = ?
        AND json_extract(payload_json, '\$.payload.intent_revision') > ?
      ORDER BY id LIMIT 1''',
      [vmCommandOutboxTopic, vmId.value, checkpoint.appliedIntentRevision],
    );
    if (rows.isEmpty) return true;
    final row = rows.single;
    final head = _IntentCommand.decode(
      row['id'] as int,
      row['key'] as String,
      row['payload_json'] as String,
      row['published_at'] == null,
    );
    if (!head.unpublished ||
        head.revision != checkpoint.appliedIntentRevision + 1) {
      throw StateError('recovery requires the next unapplied FIFO intent');
    }
    final operation = (await SqliteOperationRepository(
      _database,
    ).get(head.operationId))!;
    final terminal =
        operation.state != OperationState.pending &&
        operation.state != OperationState.running;
    // These are exactly the heads adoption defers behind a nonterminal
    // current operation. A later stop does not bypass an earlier FIFO start.
    return !(terminal ||
        head.action == VmCommandAction.start ||
        head.action == VmCommandAction.restart ||
        head.action == VmCommandAction.patch);
  });

  @override
  Future<bool> hasUnpublishedCommands(VmId vmId) => _database.read((db) {
    final checkpoint = db.select(
      'SELECT applied_intent_revision FROM vm_runtime WHERE vm_id = ?',
      [vmId.value],
    );
    if (checkpoint.isEmpty) throw VmNotFoundException(vmId);
    final premature = db.select(
      '''SELECT id FROM outbox WHERE topic = ? AND key = ? AND published_at IS NOT NULL
      AND json_extract(payload_json, '\$.payload.intent_revision') > ? LIMIT 1''',
      [
        vmCommandOutboxTopic,
        vmId.value,
        checkpoint.single['applied_intent_revision'],
      ],
    );
    if (premature.isNotEmpty)
      throw StateError('VM command was acknowledged before durable adoption');
    return db.select(
      'SELECT id FROM outbox WHERE topic = ? AND key = ? AND published_at IS NULL LIMIT 1',
      [vmCommandOutboxTopic, vmId.value],
    ).isNotEmpty;
  });

  @override
  Future<VmIntentRecoverySnapshot?> restore(
    VmId vmId,
  ) => _database.transaction((db) async {
    final rows = db.select(
      'SELECT v.intent_revision, r.* FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ? AND v.deleted_at IS NULL',
      [vmId.value],
    );
    if (rows.isEmpty) throw VmNotFoundException(vmId);
    final row = rows.single;
    final accepted = row['intent_revision'] as int;
    final applied = row['applied_intent_revision'] as int;
    final executionDesired = row['execution_desired_state'];
    final executionGeneration = row['execution_spec_generation'];
    if ((executionDesired == null) != (executionGeneration == null))
      throw StateError('execution checkpoint fields must be paired');
    final hasExecutionSnapshot = executionDesired != null;
    final commands = [
      for (final command in db.select(
        'SELECT id, key, payload_json, published_at FROM outbox WHERE topic = ? AND key = ? ORDER BY id',
        [vmCommandOutboxTopic, vmId.value],
      ))
        _IntentCommand.decode(
          command['id'] as int,
          command['key'] as String,
          command['payload_json'] as String,
          command['published_at'] == null,
        ),
    ];
    if (commands.isEmpty && accepted == 0 && applied == 0) return null;
    if (applied > accepted ||
        commands.isEmpty ||
        commands.last.revision != accepted)
      throw StateError(
        'VM accepted intent history does not match its checkpoint',
      );
    final revisions = <int>{};
    final operationIds = <OperationId>{};
    var previous = 0;
    for (final command in commands) {
      if (!command.unpublished && command.revision > applied)
        throw StateError('VM command was acknowledged before durable adoption');
      if (command.revision != previous + 1 || !revisions.add(command.revision))
        throw FormatException(
          'VM command revision history must be complete and ordered',
        );
      if (!operationIds.add(command.operationId))
        throw FormatException(
          'VM accepted commands must have distinct operation IDs',
        );
      previous = command.revision;
      final operation = await SqliteOperationRepository(
        _database,
      ).get(command.operationId);
      if (operation == null ||
          operation.resourceType != ResourceType.virtualMachine ||
          operation.resourceId != vmId ||
          operation.type != 'vm.${command.action.name}')
        throw StateError('VM command operation correlation is invalid');
    }
    final vm = await SqliteVmRepository(_database).get(vmId);
    if (vm == null) throw VmNotFoundException(vmId);
    final activeCommand = commands
        .where((command) => command.revision == applied)
        .firstOrNull;
    final baseline = commands.first.payload;
    if (applied > 0 && activeCommand == null)
      throw StateError('applied command intent is missing');
    if (!hasExecutionSnapshot &&
        applied == 0 &&
        baseline['execution_intent_revision'] != 0)
      throw StateError('initial execution snapshot is missing');
    final hasUnpublished = commands.any((command) => command.unpublished);
    // v3 compatibility: until the first v4 runtime write, retain the old
    // command/baseline inference. Never substitute the latest accepted spec.
    // Exact snapshots also cover cancelled/skipped commands and autonomous
    // failure, whose execution state differs from the command's target.
    final desired = hasExecutionSnapshot
        ? _desired(executionDesired)
        : applied == accepted
        ? vm.status.desiredState
        : activeCommand?.desired ??
              _desired(baseline['execution_desired_state']);
    final generation = hasExecutionSnapshot
        ? _positiveInt(executionGeneration, 'execution_spec_generation')
        : activeCommand?.specGeneration ??
              _positiveInt(
                baseline['execution_spec_generation'],
                'execution_spec_generation',
              );
    final specs = db.select(
      'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
      [vmId.value, generation],
    );
    if (specs.isEmpty) throw StateError('pinned execution spec is missing');
    final spec = VmSpec.fromJson(
      jsonDecode(specs.single['spec_json'] as String),
    );
    if (!hasExecutionSnapshot &&
        applied == 0 &&
        baseline['execution_restart_policy'] != spec.restartPolicy.name)
      throw FormatException(
        'execution restart policy does not match pinned spec',
      );
    VmControllerOperation? currentOperation;
    // A patch consumes an intent revision without replacing the lifecycle
    // operation. Validate that operation against the last applied lifecycle.
    final lifecycleCommand = commands
        .where(
          (command) =>
              command.revision <= applied &&
              command.action != VmCommandAction.patch,
        )
        .lastOrNull;
    final activeId = row['active_operation_id'];
    if (activeId != null) {
      final operation = await SqliteOperationRepository(
        _database,
      ).get(OperationId(activeId as String));
      if (operation == null ||
          operation.resourceType != ResourceType.virtualMachine ||
          operation.resourceId != vmId)
        throw StateError(
          'active operation does not belong to the recovering VM',
        );
      final kind = _operationKind(operation.type);
      if (kind == null)
        throw StateError('active operation is not a VM lifecycle operation');
      if (lifecycleCommand != null &&
          operation.id != lifecycleCommand.operationId &&
          !(kind == VmOperationKind.recovery &&
              (lifecycleCommand.action == VmCommandAction.start ||
                  lifecycleCommand.action == VmCommandAction.restart)) &&
          !(operation.type == 'vm.delete.recovery' &&
              lifecycleCommand.action == VmCommandAction.delete))
        throw StateError('active operation disagrees with the applied intent');
      if (lifecycleCommand == null &&
          commands.any((command) => command.operationId == operation.id))
        throw StateError(
          'unapplied queued operation cannot be an active checkpoint',
        );
      currentOperation = VmControllerOperation(
        id: operation.id,
        kind: kind,
        state: operation.state,
      );
    }
    final status = vm.status;
    return VmIntentRecoverySnapshot(
      acceptedIntentRevision: accepted,
      hasUnpublishedCommands: hasUnpublished,
      executionState:
          VmControllerState.initial(
            vmId: vmId,
            specGeneration: generation,
            restartPolicy: spec.restartPolicy,
            appliedIntentRevision: applied,
          ).copyWith(
            desiredState: desired,
            phase: status.phase,
            observedGeneration: status.observedGeneration,
            restartRequired: status.restartRequired,
            driverGeneration: status.driverGeneration,
            lastError: status.lastError,
            currentOperation: currentOperation,
            driverOperationId: currentOperation?.id,
            deletionState:
                activeCommand?.action == VmCommandAction.delete ||
                    status.phase == VmPhase.deleting
                ? VmDeletionState.deleting
                : status.phase == VmPhase.deleted
                ? VmDeletionState.deleted
                : VmDeletionState.active,
          ),
    );
  });
}

final class _IntentCommand {
  const _IntentCommand(
    this.id,
    this.revision,
    this.specGeneration,
    this.desired,
    this.operationId,
    this.action,
    this.payload,
    this.unpublished,
  );
  factory _IntentCommand.decode(
    int id,
    String key,
    String encoded,
    bool unpublished,
  ) {
    final json = jsonDecode(encoded);
    const keys = {'version', 'vm_id', 'operation_id', 'action', 'payload'};
    if (json is! Map<String, dynamic> ||
        json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['vm_id'] != key ||
        json['operation_id'] is! String)
      throw FormatException('invalid persisted VM command envelope');
    VmId(key);
    final action = VmCommandAction.values
        .where((action) => action.name == json['action'])
        .firstOrNull;
    final payload = json['payload'];
    if (action == null || payload is! Map<String, dynamic>)
      throw FormatException('invalid persisted VM command action/payload');
    final desired = _desired(payload['desired_state']);
    final requiredDesired = switch (action) {
      VmCommandAction.start || VmCommandAction.restart => DesiredState.running,
      VmCommandAction.stop ||
      VmCommandAction.kill ||
      VmCommandAction.delete => DesiredState.stopped,
      _ => null,
    };
    if (requiredDesired != null && desired != requiredDesired)
      throw FormatException('VM command desired state contradicts its action');
    return _IntentCommand(
      id,
      _positiveInt(payload['intent_revision'], 'intent_revision'),
      _positiveInt(payload['spec_generation'], 'spec_generation'),
      desired,
      OperationId(json['operation_id'] as String),
      action,
      Map<String, Object?>.unmodifiable(payload),
      unpublished,
    );
  }
  final int id;
  final int revision;
  final int specGeneration;
  final DesiredState desired;
  final OperationId operationId;
  final VmCommandAction action;
  final Map<String, Object?> payload;
  final bool unpublished;
}

int _positiveInt(Object? value, String field) {
  if (value is! int || value < 1) throw FormatException('invalid $field');
  return value;
}

DesiredState _desired(Object? value) => switch (value) {
  'running' => DesiredState.running,
  'stopped' => DesiredState.stopped,
  _ => throw FormatException('invalid execution desired state'),
};

VmOperationKind? _operationKind(String type) => switch (type) {
  'vm.start' => VmOperationKind.start,
  'vm.stop' => VmOperationKind.stop,
  'vm.restart' => VmOperationKind.restart,
  'vm.kill' => VmOperationKind.kill,
  'vm.delete' || 'vm.delete.recovery' => VmOperationKind.delete,
  'vm.recovery' => VmOperationKind.recovery,
  _ => null,
};
