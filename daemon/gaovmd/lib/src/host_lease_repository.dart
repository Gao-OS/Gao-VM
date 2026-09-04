import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'host_scheduler_models.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

const hostVmLeaseResourceType = 'host_vm';

abstract interface class HostLeaseRepository {
  Future<List<HostLease>> list({DateTime? activeAt});

  Future<HostLeaseDecision> acquire({
    required HostCapacityRequest request,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  });

  Future<List<HostLeaseDecision>> recover({
    required List<HostCapacityRequest> requests,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  });

  Future<bool> markRunning(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
    required DateTime now,
  });

  Future<HostLease?> retainForCleanup({
    required HostCapacityRequest request,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  });

  Future<bool> renew(
    VmId vmId, {
    required String ownerId,
    required OperationId? operationId,
    required DateTime now,
    required Duration ttl,
  });

  Future<bool> release(VmId vmId, {required String ownerId});

  Future<bool> releaseAcquisition(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
  });
}

final class SqliteHostLeaseRepository implements HostLeaseRepository {
  const SqliteHostLeaseRepository(this._database);

  final GaoVmDatabase _database;

  @override
  Future<List<HostLease>> list({DateTime? activeAt}) =>
      _database.read((connection) {
        final leases = connection
            .select(
              '''
                SELECT * FROM resource_leases
                WHERE resource_type = ?
                ORDER BY resource_id
              ''',
              [hostVmLeaseResourceType],
            )
            .map(_decodeLease);
        return List<HostLease>.unmodifiable(
          activeAt == null
              ? leases
              : leases.where(
                  (lease) =>
                      lease.request.phase == HostLeasePhase.cleanup ||
                      lease.expiresAt.isAfter(activeAt.toUtc()),
                ),
        );
      });

  @override
  Future<HostLeaseDecision> acquire({
    required HostCapacityRequest request,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) {
    _validateOwnerAndTtl(ownerId, ttl);
    final timestamp = now.toUtc();
    return _database.transaction((connection) {
      _deleteExpired(connection, timestamp);
      final existing = _find(connection, request.vmId);
      if (existing != null) {
        if (existing.ownerId == ownerId) {
          if (existing.request.phase == HostLeasePhase.cleanup &&
              request.phase != HostLeasePhase.cleanup) {
            return _rejected(request, 'cleanup_hold');
          }
          final candidate =
              existing.request.phase == HostLeasePhase.running &&
                  request.phase == HostLeasePhase.booting
              ? request.copyWith(phase: HostLeasePhase.running)
              : request;
          if (existing.request == candidate) {
            final refreshed = HostLease(
              request: existing.request,
              ownerId: existing.ownerId,
              acquiredAt: existing.acquiredAt,
              expiresAt: timestamp.add(ttl),
            );
            _replace(connection, refreshed);
            return HostLeaseDecision.admitted(refreshed);
          }
          if (_isStaleRequest(existing.request, candidate)) {
            return _rejected(candidate, 'lease_fence');
          }
          final active = _listActive(
            connection,
            timestamp,
          ).where((lease) => lease.request.vmId != request.vmId).toList();
          final rejection = _admissionError(candidate, active, limits, metrics);
          if (rejection != null) return rejection;
          final replacement = HostLease(
            request: candidate,
            ownerId: ownerId,
            acquiredAt: timestamp,
            expiresAt: timestamp.add(ttl),
          );
          _replace(connection, replacement);
          return HostLeaseDecision.admitted(replacement);
        }
        return _rejected(request, 'lease_owner');
      }
      final active = _listActive(connection, timestamp);
      final rejection = _admissionError(request, active, limits, metrics);
      if (rejection != null) return rejection;
      final lease = HostLease(
        request: request,
        ownerId: ownerId,
        acquiredAt: timestamp,
        expiresAt: timestamp.add(ttl),
      );
      _insert(connection, lease);
      return HostLeaseDecision.admitted(lease);
    });
  }

  @override
  Future<List<HostLeaseDecision>> recover({
    required List<HostCapacityRequest> requests,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) {
    _validateOwnerAndTtl(ownerId, ttl);
    final timestamp = now.toUtc();
    final ordered = List<HostCapacityRequest>.of(requests)
      ..sort((left, right) => left.vmId.value.compareTo(right.vmId.value));
    return _database.transaction((connection) {
      connection.execute(
        'DELETE FROM resource_leases WHERE resource_type = ?',
        [hostVmLeaseResourceType],
      );
      final admitted = <HostLease>[];
      final decisions = <HostLeaseDecision>[];
      for (final request in ordered) {
        final rejection = _admissionError(request, admitted, limits, metrics);
        if (rejection != null) {
          decisions.add(rejection);
          continue;
        }
        final lease = HostLease(
          request: request,
          ownerId: ownerId,
          acquiredAt: timestamp,
          expiresAt: timestamp.add(ttl),
        );
        _insert(connection, lease);
        admitted.add(lease);
        decisions.add(HostLeaseDecision.admitted(lease));
      }
      return List<HostLeaseDecision>.unmodifiable(decisions);
    });
  }

  @override
  Future<bool> markRunning(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
    required DateTime now,
  }) => _database.transaction((connection) {
    final lease = _find(connection, vmId);
    if (lease == null ||
        lease.ownerId != ownerId ||
        lease.request.operationId != operationId) {
      return false;
    }
    if (!lease.expiresAt.isAfter(now.toUtc())) {
      return false;
    }
    if (lease.request.phase == HostLeasePhase.running) return true;
    connection.execute(
      '''
            UPDATE resource_leases SET lease_json = ?
            WHERE resource_type = ? AND resource_id = ? AND owner_id = ?
          ''',
      [
        jsonEncode(
          lease.request.copyWith(phase: HostLeasePhase.running).toJson(),
        ),
        hostVmLeaseResourceType,
        vmId.value,
        ownerId,
      ],
    );
    return connection.updatedRows == 1;
  });

  @override
  Future<bool> renew(
    VmId vmId, {
    required String ownerId,
    required OperationId? operationId,
    required DateTime now,
    required Duration ttl,
  }) {
    _validateOwnerAndTtl(ownerId, ttl);
    return _database.transaction((connection) {
      final lease = _find(connection, vmId);
      if (lease == null ||
          lease.ownerId != ownerId ||
          lease.request.operationId != operationId) {
        return false;
      }
      if (!lease.expiresAt.isAfter(now.toUtc()) &&
          lease.request.phase != HostLeasePhase.cleanup) {
        return false;
      }
      connection.execute(
        '''
          UPDATE resource_leases SET expires_at = ?
          WHERE resource_type = ? AND resource_id = ? AND owner_id = ?
        ''',
        [
          formatPersistenceTimestamp(now.toUtc().add(ttl)),
          hostVmLeaseResourceType,
          vmId.value,
          ownerId,
        ],
      );
      return connection.updatedRows == 1;
    });
  }

  @override
  Future<bool> release(VmId vmId, {required String ownerId}) =>
      _database.transaction((connection) {
        final lease = _find(connection, vmId);
        if (lease == null) return true;
        if (lease.ownerId != ownerId) return false;
        connection.execute(
          '''
            DELETE FROM resource_leases
            WHERE resource_type = ? AND resource_id = ? AND owner_id = ?
          ''',
          [hostVmLeaseResourceType, vmId.value, ownerId],
        );
        return connection.updatedRows == 1;
      });

  @override
  Future<HostLease?> retainForCleanup({
    required HostCapacityRequest request,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) {
    _validateOwnerAndTtl(ownerId, ttl);
    final timestamp = now.toUtc();
    final cleanupRequest = request.copyWith(phase: HostLeasePhase.cleanup);
    return _database.transaction((connection) {
      final existing = _find(connection, request.vmId);
      if (existing != null &&
          (existing.ownerId != ownerId ||
              existing.request.specGeneration != request.specGeneration ||
              existing.request.operationId != request.operationId)) {
        return null;
      }
      final lease = HostLease(
        request: cleanupRequest,
        ownerId: ownerId,
        acquiredAt: existing?.acquiredAt ?? timestamp,
        expiresAt: timestamp.add(ttl),
      );
      if (existing == null) {
        _insert(connection, lease);
      } else {
        _replace(connection, lease);
      }
      return lease;
    });
  }

  @override
  Future<bool> releaseAcquisition(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
  }) => _database.transaction((connection) {
    final lease = _find(connection, vmId);
    if (lease == null) return true;
    if (lease.ownerId != ownerId || lease.request.operationId != operationId) {
      return false;
    }
    _delete(connection, vmId, ownerId);
    return true;
  });

  HostLeaseDecision? _admissionError(
    HostCapacityRequest request,
    List<HostLease> active,
    HostSchedulerLimits limits,
    HostMetrics metrics,
  ) {
    if (active.length + 1 > limits.maxRunningVms) {
      return _rejected(request, 'max_running_vms');
    }
    final booting = active
        .where((lease) => lease.request.phase == HostLeasePhase.booting)
        .length;
    if (request.phase == HostLeasePhase.booting &&
        booting + 1 > limits.maxConcurrentBoots) {
      return _rejected(request, 'max_concurrent_boots');
    }
    final drivers = active.fold<int>(
      metrics.unmanagedDriverProcesses,
      (sum, lease) => sum + lease.request.driverProcesses,
    );
    if (drivers + request.driverProcesses > limits.maxDriverProcesses) {
      return _rejected(request, 'max_driver_processes');
    }
    final cpu = active.fold<int>(
      0,
      (sum, lease) => sum + lease.request.cpuCount,
    );
    final cpuLimit = limits.maxCpuCount < metrics.logicalCpuCount
        ? limits.maxCpuCount
        : metrics.logicalCpuCount;
    if (cpu + request.cpuCount > cpuLimit) {
      return _rejected(request, 'cpu_budget');
    }
    final memory = active.fold<int>(
      0,
      (sum, lease) => sum + lease.request.memoryBytes,
    );
    final memoryLimit = limits.maxMemoryBytes < metrics.totalMemoryBytes
        ? limits.maxMemoryBytes
        : metrics.totalMemoryBytes;
    if (memory + request.memoryBytes > memoryLimit) {
      return _rejected(request, 'memory_budget');
    }
    final unconsumedMemory = active
        .where((lease) => lease.request.phase == HostLeasePhase.booting)
        .fold<int>(0, (sum, lease) => sum + lease.request.memoryBytes);
    if (request.phase == HostLeasePhase.booting &&
        unconsumedMemory + request.memoryBytes > metrics.availableMemoryBytes) {
      return _rejected(request, 'host_available_memory');
    }
    final reservedDisk = active.fold<int>(
      0,
      (sum, lease) => sum + lease.request.diskBytes,
    );
    if (metrics.freeDiskBytes - reservedDisk - request.diskBytes <
        limits.minFreeDiskBytes) {
      return _rejected(request, 'min_free_disk');
    }
    return null;
  }

  HostLeaseDecision _rejected(HostCapacityRequest request, String constraint) =>
      HostLeaseDecision.rejected(
        request: request,
        constraint: constraint,
        error: OperationError(
          code: ErrorCode.hostResourceExhausted,
          message: 'host capacity exhausted: $constraint',
          retryable: true,
          details: JsonObjectValue.fromJson({'constraint': constraint}),
        ),
      );

  List<HostLease> _listActive(Database connection, DateTime activeAt) =>
      connection
          .select(
            '''
              SELECT * FROM resource_leases
              WHERE resource_type = ?
              ORDER BY resource_id
            ''',
            [hostVmLeaseResourceType],
          )
          .map(_decodeLease)
          .where(
            (lease) =>
                lease.request.phase == HostLeasePhase.cleanup ||
                lease.expiresAt.isAfter(activeAt),
          )
          .toList();

  HostLease? _find(Database connection, VmId vmId) {
    final rows = connection.select(
      '''
        SELECT * FROM resource_leases
        WHERE resource_type = ? AND resource_id = ?
      ''',
      [hostVmLeaseResourceType, vmId.value],
    );
    return rows.isEmpty ? null : _decodeLease(rows.single);
  }

  void _insert(Database connection, HostLease lease) {
    connection.execute(
      '''
        INSERT INTO resource_leases(
          resource_type, resource_id, owner_id, lease_json,
          acquired_at, expires_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        hostVmLeaseResourceType,
        lease.request.vmId.value,
        lease.ownerId,
        jsonEncode(lease.request.toJson()),
        formatPersistenceTimestamp(lease.acquiredAt),
        formatPersistenceTimestamp(lease.expiresAt),
      ],
    );
  }

  void _replace(Database connection, HostLease lease) {
    connection.execute(
      '''
        UPDATE resource_leases
        SET owner_id = ?, lease_json = ?, acquired_at = ?, expires_at = ?
        WHERE resource_type = ? AND resource_id = ?
      ''',
      [
        lease.ownerId,
        jsonEncode(lease.request.toJson()),
        formatPersistenceTimestamp(lease.acquiredAt),
        formatPersistenceTimestamp(lease.expiresAt),
        hostVmLeaseResourceType,
        lease.request.vmId.value,
      ],
    );
  }

  void _delete(Database connection, VmId vmId, String ownerId) {
    connection.execute(
      '''
        DELETE FROM resource_leases
        WHERE resource_type = ? AND resource_id = ? AND owner_id = ?
      ''',
      [hostVmLeaseResourceType, vmId.value, ownerId],
    );
  }

  void _deleteExpired(Database connection, DateTime now) {
    final expired = connection
        .select(
          '''
            SELECT * FROM resource_leases
            WHERE resource_type = ? AND expires_at <= ?
          ''',
          [hostVmLeaseResourceType, formatPersistenceTimestamp(now)],
        )
        .map(_decodeLease)
        .where((lease) => lease.request.phase != HostLeasePhase.cleanup);
    for (final lease in expired) {
      _delete(connection, lease.request.vmId, lease.ownerId);
    }
  }
}

HostLease _decodeLease(Row row) => HostLease(
  request: HostCapacityRequest.fromJson(
    jsonDecode(row['lease_json']! as String),
  ),
  ownerId: row['owner_id']! as String,
  acquiredAt: DateTime.parse(row['acquired_at']! as String).toUtc(),
  expiresAt: DateTime.parse(row['expires_at']! as String).toUtc(),
);

void _validateOwnerAndTtl(String ownerId, Duration ttl) {
  if (ownerId.trim().isEmpty) throw ArgumentError('ownerId must not be empty');
  if (ttl <= Duration.zero) throw ArgumentError('ttl must be positive');
}

bool _isStaleRequest(
  HostCapacityRequest current,
  HostCapacityRequest candidate,
) {
  if (candidate.specGeneration != current.specGeneration) {
    return candidate.specGeneration < current.specGeneration;
  }
  final currentOperation = current.operationId;
  final candidateOperation = candidate.operationId;
  if (currentOperation == null) return false;
  if (candidateOperation == null) return true;
  return candidateOperation != currentOperation;
}
