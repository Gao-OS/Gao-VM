import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'image_manifest.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_provisioning_plan.dart';
import 'vm_bundle_manifest.dart';

const vmProvisioningOutboxTopic = 'vm.provisioning';

enum VmProvisioningCompletionKind { succeeded, failed, cancelled }

/// Durable publication/cleanup outcome, independent of mutable guest disks.
final class VmProvisioningCompletion {
  const VmProvisioningCompletion._({
    required this.kind,
    required this.manifestDigest,
    required this.completedAt,
  });
  final VmProvisioningCompletionKind kind;
  final String? manifestDigest;
  final DateTime completedAt;
}

/// Durable provisioning input, independent of lifecycle command adoption.
final class VmProvisioningJob {
  const VmProvisioningJob._({
    required this.plan,
    required this.cancellationRequested,
    required this.createdAt,
    required this.completion,
  });

  final VmProvisioningPlan plan;
  final bool cancellationRequested;
  final DateTime createdAt;
  final VmProvisioningCompletion? completion;
}

final class SqliteVmProvisioningRepository {
  SqliteVmProvisioningRepository(
    this._database, {
    DateTime Function()? now,
    EventId Function()? newEventId,
  }) : _now = now ?? DateTime.now,
       _events = SqliteEventRepository(
         _database,
         now: now,
         newEventId: newEventId,
       );

  final GaoVmDatabase _database;
  final DateTime Function() _now;
  final SqliteEventRepository _events;

  Future<VmProvisioningJob?> get(VmId vmId) => _database.read((db) {
    final rows = db.select('SELECT * FROM vm_provisioning WHERE vm_id = ?', [
      vmId.value,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final plan = VmProvisioningPlan.fromJson(
      jsonDecode(row['plan_json'] as String),
    );
    if (plan.vmId.value != row['vm_id'] ||
        plan.operationId.value != row['operation_id'] ||
        plan.specGeneration != row['spec_generation']) {
      throw FormatException(
        'provisioning plan disagrees with relational identity',
      );
    }
    VmProvisioningCompletion? completion;
    if (row['completion_kind'] == null) {
      if (row['manifest_digest'] != null || row['completed_at'] != null) {
        throw FormatException('incomplete provisioning completion proof');
      }
    } else {
      final kind = VmProvisioningCompletionKind.values
          .where((kind) => kind.name == row['completion_kind'])
          .firstOrNull;
      if (kind == null ||
          row['completed_at'] is! String ||
          (kind == VmProvisioningCompletionKind.succeeded
              ? row['manifest_digest'] != VmBundleManifest.create(plan).digest
              : row['manifest_digest'] != null)) {
        throw FormatException('invalid provisioning completion proof');
      }
      final completedAt = DateTime.parse(row['completed_at'] as String).toUtc();
      final operation = db.select('SELECT * FROM operations WHERE id = ?', [
        plan.operationId.value,
      ]).firstOrNull;
      final request = operation == null
          ? null
          : jsonDecode(operation['request_json'] as String);
      if (operation == null ||
          operation['type'] != 'vm.create' ||
          operation['resource_type'] != 'virtual_machine' ||
          operation['resource_id'] != plan.vmId.value ||
          operation['state'] != kind.name ||
          operation['completed_at'] != row['completed_at'] ||
          request is! Map<String, dynamic> ||
          (request.containsKey('spec_generation') &&
              (request['spec_generation'] is! int ||
                  request['spec_generation'] != plan.specGeneration)) ||
          (kind == VmProvisioningCompletionKind.succeeded &&
              row['cancellation_requested'] != 0) ||
          (kind == VmProvisioningCompletionKind.cancelled &&
              row['cancellation_requested'] != 1)) {
        throw FormatException(
          'provisioning completion disagrees with operation',
        );
      }
      completion = VmProvisioningCompletion._(
        kind: kind,
        manifestDigest: row['manifest_digest'] as String?,
        completedAt: completedAt,
      );
    }
    return VmProvisioningJob._(
      plan: plan,
      cancellationRequested: row['cancellation_requested'] == 1,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      completion: completion,
    );
  });

  /// Joins create acceptance's transaction. Only pending operations may be
  /// accepted or retried here; recovery reads the stored job through [get].
  Future<VmProvisioningJob> accept(
    VmProvisioningPlan plan,
  ) => _database.transaction((db) async {
    final operation = await SqliteOperationRepository(
      _database,
    ).get(plan.operationId);
    if (operation == null) throw OperationNotFoundException(plan.operationId);
    if (operation.state != OperationState.pending) {
      throw StateError(
        'provisioning acceptance requires a pending create operation',
      );
    }
    final existing = await get(plan.vmId);
    if (existing != null) {
      if (canonicalImageJson(existing.plan.toJson()) !=
          canonicalImageJson(plan.toJson())) {
        throw StateError('VM already has a different provisioning job');
      }
      return existing;
    }
    final rows = db.select(
      '''
      SELECT 1 FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
      WHERE v.id = ? AND v.deleted_at IS NULL AND v.deleting_at IS NULL
        AND v.spec_generation = ? AND r.desired_state = 'stopped'
        AND r.phase IN ('defined', 'provisioning')
        AND r.driver_generation = 0 AND r.observed_generation = 0
        AND v.intent_revision = 0 AND r.applied_intent_revision = 0
        AND r.active_operation_id IS NULL
    ''',
      [plan.vmId.value, plan.specGeneration],
    );
    if (rows.isEmpty)
      throw StateError('VM is not eligible for provisioning acceptance');
    final authoritative = await SqliteVmProvisioningPlanner(_database).plan(
      vmId: plan.vmId,
      operationId: plan.operationId,
      specGeneration: plan.specGeneration,
    );
    if (canonicalImageJson(authoritative.toJson()) !=
        canonicalImageJson(plan.toJson())) {
      throw StateError('provisioning plan disagrees with catalog');
    }
    final timestamp = _now().toUtc();
    db.execute(
      '''
      INSERT INTO vm_provisioning(vm_id, operation_id, spec_generation, plan_json, created_at)
      VALUES (?, ?, ?, ?, ?)
    ''',
      [
        plan.vmId.value,
        plan.operationId.value,
        plan.specGeneration,
        canonicalImageJson(plan.toJson()),
        formatPersistenceTimestamp(timestamp),
      ],
    );
    db.execute(
      "UPDATE vm_runtime SET phase = 'provisioning', last_transition_at = ? WHERE vm_id = ?",
      [formatPersistenceTimestamp(timestamp), plan.vmId.value],
    );
    db.execute(
      '''
      INSERT INTO outbox(topic, key, payload_json, created_at) VALUES (?, ?, ?, ?)
    ''',
      [
        vmProvisioningOutboxTopic,
        plan.operationId.value,
        canonicalImageJson({
          'vm_id': plan.vmId.value,
          'operation_id': plan.operationId.value,
          'spec_generation': plan.specGeneration,
        }),
        formatPersistenceTimestamp(timestamp),
      ],
    );
    await _events.append(
      type: 'vm.provisioning.accepted',
      resourceType: ResourceType.virtualMachine,
      resourceId: plan.vmId,
      vmId: plan.vmId,
      operationId: plan.operationId,
      payload: JsonObjectValue.fromJson({
        'spec_generation': plan.specGeneration,
      }),
      occurredAt: timestamp,
    );
    return (await get(plan.vmId))!;
  });

  /// Records worker intent only. Owned-file cleanup and terminal operation
  /// transitions belong to provisioning orchestration.
  Future<VmProvisioningJob> requestCancellation(
    VmId vmId, {
    required OperationId operationId,
  }) => _database.transaction((db) async {
    final job = await get(vmId);
    if (job == null) throw StateError('VM has no provisioning job');
    if (job.plan.operationId != operationId)
      throw StateError('operation does not match provisioning job');
    final operation = await SqliteOperationRepository(
      _database,
    ).get(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    if (operation.type != 'vm.create' ||
        operation.resourceId != vmId ||
        operation.resourceType != ResourceType.virtualMachine) {
      throw StateError('operation does not match provisioning job');
    }
    if (!operation.cancellable ||
        (operation.state != OperationState.pending &&
            operation.state != OperationState.running)) {
      throw OperationNotCancellableException(operationId);
    }
    if (job.cancellationRequested) return job;
    db.execute(
      'UPDATE vm_provisioning SET cancellation_requested = 1 WHERE vm_id = ?',
      [vmId.value],
    );
    await _events.append(
      type: 'vm.provisioning.cancellation_requested',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      vmId: vmId,
      operationId: operationId,
      payload: JsonObjectValue.fromJson({
        'spec_generation': job.plan.specGeneration,
      }),
    );
    return (await get(vmId))!;
  });
}
