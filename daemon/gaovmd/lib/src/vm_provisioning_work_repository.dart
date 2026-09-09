import 'dart:async';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'operation_repository.dart';
import 'event_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_bundle_manifest.dart';

/// An immutable delivery handle. Releasing or renewing invalidates this handle.
final class VmProvisioningClaim {
  const VmProvisioningClaim._({
    required this.job,
    required this.outboxId,
    required this.owner,
    required this.attempt,
    required this.leaseExpiresAt,
    required String token,
  }) : _token = token;

  final VmProvisioningJob job;
  final int outboxId;
  final String owner;
  final int attempt;
  final DateTime leaseExpiresAt;
  final String _token;
  VmProvisioningPlan get plan => job.plan;
}

/// Committed work delivery and terminal outcome transactions, without IO.
/// Only a completion transaction may acknowledge work.
final class SqliteVmProvisioningWorkRepository {
  SqliteVmProvisioningWorkRepository(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final DateTime Function() _now;

  Future<T> _transaction<T>(FutureOr<T> Function(Database) action) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('provisioning work must own its commit boundary');
    }
    return _database.transaction(action);
  }

  Future<List<VmProvisioningClaim>> claim({
    required String owner,
    required Duration lease,
    int limit = 100,
  }) => _transaction((db) async {
    if (owner.isEmpty || owner.length > 255) {
      throw ArgumentError.value(
        owner,
        'owner',
        'must contain 1 to 255 characters',
      );
    }
    _validateLease(lease);
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 1000');
    }
    final now = _now().toUtc();
    final expiry = now.add(lease);
    final rows = db.select(
      '''
      SELECT candidate.* FROM outbox candidate
      WHERE candidate.topic = ? AND candidate.published_at IS NULL
        AND (candidate.claimed_by IS NULL OR candidate.claim_expires_at <= ?)
        AND NOT EXISTS (
          SELECT 1 FROM outbox earlier
          WHERE earlier.topic = candidate.topic AND earlier.key = candidate.key
            AND earlier.published_at IS NULL AND earlier.id < candidate.id
        )
      ORDER BY candidate.id LIMIT ?
    ''',
      [vmProvisioningOutboxTopic, formatPersistenceTimestamp(now), limit],
    );
    final claims = <VmProvisioningClaim>[];
    for (final row in rows) {
      final job = await _job(row);
      final token = '$owner/${RequestId.generate().value}';
      db.execute(
        '''
        UPDATE outbox SET claimed_by = ?, claim_expires_at = ?, attempts = attempts + 1
        WHERE id = ? AND topic = ?
      ''',
        [
          token,
          formatPersistenceTimestamp(expiry),
          row['id'],
          vmProvisioningOutboxTopic,
        ],
      );
      claims.add(
        VmProvisioningClaim._(
          job: job,
          outboxId: row['id'] as int,
          owner: owner,
          attempt: (row['attempts'] as int) + 1,
          leaseExpiresAt: expiry,
          token: token,
        ),
      );
    }
    return List.unmodifiable(claims);
  });

  Future<bool> isCurrent(VmProvisioningClaim claim) => _transaction((db) async {
    return await _current(db, claim) != null;
  });

  /// Returns a fresh handle; even a renewal at the same clock instant fences
  /// the previous handle by replacing its token. Delivery attempt stays fixed.
  Future<VmProvisioningClaim?> renew(
    VmProvisioningClaim claim, {
    required Duration lease,
  }) => _transaction((db) async {
    _validateLease(lease);
    final job = await _current(db, claim);
    if (job == null) return null;
    final now = _now().toUtc();
    final expiry = now.add(lease);
    final token = '${claim.owner}/${RequestId.generate().value}';
    db.execute(
      '''UPDATE outbox SET claimed_by = ?, claim_expires_at = ?
        WHERE topic = ? AND id = ? AND published_at IS NULL AND claimed_by = ?
          AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?''',
      [
        token,
        formatPersistenceTimestamp(expiry),
        vmProvisioningOutboxTopic,
        claim.outboxId,
        claim._token,
        claim.attempt,
        formatPersistenceTimestamp(claim.leaseExpiresAt),
        formatPersistenceTimestamp(now),
      ],
    );
    if (db.updatedRows != 1) return null;
    return VmProvisioningClaim._(
      job: job,
      outboxId: claim.outboxId,
      owner: claim.owner,
      attempt: claim.attempt,
      leaseExpiresAt: expiry,
      token: token,
    );
  });

  Future<bool> release(VmProvisioningClaim claim) => _transaction((db) async {
    if (await _current(db, claim) == null) return false;
    db.execute(
      '''UPDATE outbox SET claimed_by = NULL, claim_expires_at = NULL
        WHERE topic = ? AND id = ? AND published_at IS NULL AND claimed_by = ?
          AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?''',
      [
        vmProvisioningOutboxTopic,
        claim.outboxId,
        claim._token,
        claim.attempt,
        formatPersistenceTimestamp(claim.leaseExpiresAt),
        formatPersistenceTimestamp(_now().toUtc()),
      ],
    );
    return db.updatedRows == 1;
  });

  /// Caller holds the per-VM filesystem lock through this commit and has
  /// durably published the complete bundle described by [manifestDigest].
  Future<bool> completePublished(
    VmProvisioningClaim claim, {
    required String manifestDigest,
  }) => _complete(
    claim,
    VmProvisioningCompletionKind.succeeded,
    manifestDigest: manifestDigest,
  );

  /// Caller has removed this job's owned files and holds the per-VM filesystem
  /// lock through this commit. External files must never be removed.
  Future<bool> completeFailed(
    VmProvisioningClaim claim, {
    required OperationError error,
  }) => _complete(claim, VmProvisioningCompletionKind.failed, error: error);

  /// Same cleanup/lock precondition as [completeFailed]. Requires durable
  /// cancellation intent; requesting cancellation alone is not cleanup proof.
  Future<bool> completeCancelled(VmProvisioningClaim claim) =>
      _complete(claim, VmProvisioningCompletionKind.cancelled);

  Future<bool> _complete(
    VmProvisioningClaim claim,
    VmProvisioningCompletionKind kind, {
    String? manifestDigest,
    OperationError? error,
  }) async {
    try {
      return await _transaction((db) async {
        final job = await _current(db, claim);
        if (job == null) return false;
        if (job.completion != null)
          throw StateError('provisioning is already complete');
        final success = kind == VmProvisioningCompletionKind.succeeded;
        if (success &&
            manifestDigest != VmBundleManifest.create(job.plan).digest) {
          throw ArgumentError.value(
            manifestDigest,
            'manifestDigest',
            'does not match pinned bundle',
          );
        }
        if (kind == VmProvisioningCompletionKind.cancelled &&
            !job.cancellationRequested) {
          throw StateError('provisioning cancellation has not been requested');
        }
        if (kind != VmProvisioningCompletionKind.cancelled &&
            job.cancellationRequested) {
          throw StateError(
            'provisioning cancellation must complete before another outcome',
          );
        }
        final eligible = db.select(
          '''
      SELECT 1 FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
      WHERE v.id = ? AND v.deleted_at IS NULL AND v.deleting_at IS NULL
        AND v.spec_generation = ? AND r.desired_state = 'stopped'
        AND r.phase = 'provisioning' AND r.driver_generation = 0
        AND r.observed_generation = 0 AND v.intent_revision = 0
        AND r.applied_intent_revision = 0 AND r.active_operation_id IS NULL
        AND r.execution_desired_state IS NULL AND r.execution_spec_generation IS NULL
    ''',
          [job.plan.vmId.value, job.plan.specGeneration],
        );
        if (eligible.isEmpty)
          throw StateError('VM is not eligible for provisioning completion');
        final timestamp = _now().toUtc();
        final operations = SqliteOperationRepository(
          _database,
          now: () => timestamp,
        );
        final operation = (await operations.get(job.plan.operationId))!;
        if (operation.state != OperationState.pending &&
            operation.state != OperationState.running) {
          throw StateError('provisioning operation is not active');
        }
        if (kind != VmProvisioningCompletionKind.cancelled &&
            operation.state == OperationState.pending) {
          await operations.start(operation.id);
        }
        switch (kind) {
          case VmProvisioningCompletionKind.succeeded:
            await operations.succeed(
              operation.id,
              result: JsonObjectValue.fromJson({
                'vm_id': job.plan.vmId.value,
                'spec_generation': job.plan.specGeneration,
                'manifest_digest': manifestDigest,
              }),
            );
          case VmProvisioningCompletionKind.failed:
            await operations.fail(operation.id, error: error!);
          case VmProvisioningCompletionKind.cancelled:
            await operations.cancel(operation.id);
            final actions = db.select(
              'SELECT action_id FROM vm_provisioning_cancellations WHERE target_id = ? ORDER BY action_id',
              [operation.id.value],
            );
            for (final row in actions) {
              final action = await operations.get(
                OperationId(row['action_id'] as String),
              );
              final request = action?.request.toJson();
              if (action == null ||
                  action.type != 'operation.cancel' ||
                  action.resourceType != ResourceType.operation ||
                  action.resourceId != operation.id ||
                  action.cancellable ||
                  (action.state != OperationState.pending &&
                      action.state != OperationState.running) ||
                  request!.length != 2 ||
                  request['vm_id'] != job.plan.vmId.value ||
                  request['spec_generation'] is! int ||
                  request['spec_generation'] != job.plan.specGeneration) {
                throw FormatException(
                  'cancellation action disagrees with provisioning job',
                );
              }
              if (action.state == OperationState.pending)
                await operations.start(action.id);
              await operations.succeed(
                action.id,
                result: JsonObjectValue.fromJson({
                  'operation_id': operation.id.value,
                  'state': OperationState.cancelled.name,
                }),
              );
            }
        }
        final encodedTime = formatPersistenceTimestamp(timestamp);
        db.execute(
          '''
      UPDATE vm_runtime SET phase = ?, desired_state = 'stopped', last_transition_at = ? WHERE vm_id = ?
    ''',
          [success ? 'stopped' : 'deleted', encodedTime, job.plan.vmId.value],
        );
        if (!success) {
          db.execute(
            '''UPDATE vms SET revision = revision + 1,
              deleting_at = COALESCE(deleting_at, ?), deleted_at = ?, updated_at = ?
              WHERE id = ?''',
            [encodedTime, encodedTime, encodedTime, job.plan.vmId.value],
          );
        }
        db.execute(
          '''
      UPDATE vm_provisioning SET completion_kind = ?, manifest_digest = ?, completed_at = ? WHERE vm_id = ?
    ''',
          [kind.name, manifestDigest, encodedTime, job.plan.vmId.value],
        );
        await SqliteEventRepository(_database, now: () => timestamp).append(
          type: 'vm.provisioning.${kind.name}',
          resourceType: ResourceType.virtualMachine,
          resourceId: job.plan.vmId,
          vmId: job.plan.vmId,
          operationId: operation.id,
          payload: JsonObjectValue.fromJson({
            'spec_generation': job.plan.specGeneration,
            if (success) 'manifest_digest': manifestDigest,
            if (error != null) 'error': error.toJson(),
          }),
        );
        db.execute(
          '''
      UPDATE outbox SET published_at = ?, claimed_by = NULL, claim_expires_at = NULL
      WHERE topic = ? AND id = ? AND published_at IS NULL AND claimed_by = ?
        AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?
    ''',
          [
            encodedTime,
            vmProvisioningOutboxTopic,
            claim.outboxId,
            claim._token,
            claim.attempt,
            formatPersistenceTimestamp(claim.leaseExpiresAt),
            formatPersistenceTimestamp(_now().toUtc()),
          ],
        );
        if (db.updatedRows != 1) throw const _ExpiredCompletionClaim();
        return true;
      });
    } on _ExpiredCompletionClaim {
      return false;
    }
  }

  Future<VmProvisioningJob?> _current(
    Database db,
    VmProvisioningClaim claim,
  ) async {
    final rows = db.select(
      '''
      SELECT * FROM outbox WHERE topic = ? AND id = ? AND published_at IS NULL
        AND claimed_by = ? AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?
    ''',
      [
        vmProvisioningOutboxTopic,
        claim.outboxId,
        claim._token,
        claim.attempt,
        formatPersistenceTimestamp(claim.leaseExpiresAt),
        formatPersistenceTimestamp(_now().toUtc()),
      ],
    );
    if (rows.isEmpty) return null;
    final job = await _job(rows.single);
    if (job.plan.vmId != claim.plan.vmId ||
        job.plan.operationId != claim.plan.operationId ||
        job.plan.specGeneration != claim.plan.specGeneration) {
      throw FormatException('provisioning claim identity changed');
    }
    return job;
  }

  Future<VmProvisioningJob> _job(Row row) async {
    final envelope = jsonDecode(row['payload_json'] as String);
    const keys = {'vm_id', 'operation_id', 'spec_generation'};
    if (row['topic'] != vmProvisioningOutboxTopic ||
        envelope is! Map<String, dynamic> ||
        envelope.length != keys.length ||
        envelope.keys.any((key) => !keys.contains(key)) ||
        envelope['vm_id'] is! String ||
        envelope['operation_id'] is! String ||
        envelope['spec_generation'] is! int ||
        row['key'] != envelope['operation_id']) {
      throw FormatException('invalid provisioning work envelope');
    }
    final job = await SqliteVmProvisioningRepository(
      _database,
    ).get(VmId(envelope['vm_id'] as String));
    if (job == null ||
        job.plan.operationId.value != envelope['operation_id'] ||
        job.plan.specGeneration != envelope['spec_generation']) {
      throw FormatException('provisioning work disagrees with durable job');
    }
    final operation = await SqliteOperationRepository(
      _database,
    ).get(job.plan.operationId);
    final request = operation?.request.toJson();
    if (operation == null ||
        operation.type != 'vm.create' ||
        operation.resourceType != ResourceType.virtualMachine ||
        operation.resourceId != job.plan.vmId ||
        (request!.containsKey('spec_generation') &&
            (request['spec_generation'] is! int ||
                request['spec_generation'] != job.plan.specGeneration))) {
      throw FormatException(
        'provisioning operation identity disagrees with durable job',
      );
    }
    return job;
  }
}

void _validateLease(Duration lease) {
  if (lease <= Duration.zero)
    throw ArgumentError.value(lease, 'lease', 'must be positive');
}

final class _ExpiredCompletionClaim implements Exception {
  const _ExpiredCompletionClaim();
}
