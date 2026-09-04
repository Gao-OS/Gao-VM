import 'package:gaovm_models/gaovm_models.dart';

enum HostLeasePhase { booting, running, cleanup }

final class HostSchedulerLimits {
  HostSchedulerLimits({
    required this.maxRunningVms,
    required this.maxConcurrentBoots,
    required this.maxDriverProcesses,
    required this.maxCpuCount,
    required this.maxMemoryBytes,
    required this.minFreeDiskBytes,
  }) {
    if (maxRunningVms <= 0 ||
        maxConcurrentBoots <= 0 ||
        maxDriverProcesses <= 0 ||
        maxCpuCount <= 0 ||
        maxMemoryBytes <= 0 ||
        minFreeDiskBytes < 0) {
      throw ArgumentError('host scheduler limits are outside valid ranges');
    }
  }

  final int maxRunningVms;
  final int maxConcurrentBoots;
  final int maxDriverProcesses;
  final int maxCpuCount;
  final int maxMemoryBytes;
  final int minFreeDiskBytes;
}

final class HostMetrics {
  const HostMetrics({
    required this.logicalCpuCount,
    required this.totalMemoryBytes,
    required this.availableMemoryBytes,
    required this.freeDiskBytes,
    required this.unmanagedDriverProcesses,
  }) : assert(logicalCpuCount > 0),
       assert(totalMemoryBytes > 0),
       assert(availableMemoryBytes >= 0),
       assert(freeDiskBytes >= 0),
       assert(unmanagedDriverProcesses >= 0);

  final int logicalCpuCount;
  final int totalMemoryBytes;
  final int availableMemoryBytes;
  final int freeDiskBytes;
  final int unmanagedDriverProcesses;

  HostMetrics copyWith({
    int? logicalCpuCount,
    int? totalMemoryBytes,
    int? availableMemoryBytes,
    int? freeDiskBytes,
    int? unmanagedDriverProcesses,
  }) => HostMetrics(
    logicalCpuCount: logicalCpuCount ?? this.logicalCpuCount,
    totalMemoryBytes: totalMemoryBytes ?? this.totalMemoryBytes,
    availableMemoryBytes: availableMemoryBytes ?? this.availableMemoryBytes,
    freeDiskBytes: freeDiskBytes ?? this.freeDiskBytes,
    unmanagedDriverProcesses:
        unmanagedDriverProcesses ?? this.unmanagedDriverProcesses,
  );
}

final class HostCapacityRequest {
  HostCapacityRequest({
    required this.vmId,
    required this.cpuCount,
    required this.memoryBytes,
    required this.diskBytes,
    required this.phase,
    required this.specGeneration,
    required this.operationId,
    this.driverProcesses = 1,
  }) {
    if (cpuCount <= 0 ||
        memoryBytes <= 0 ||
        diskBytes < 0 ||
        driverProcesses <= 0 ||
        specGeneration < 1) {
      throw ArgumentError('host capacity request is outside valid ranges');
    }
  }

  factory HostCapacityRequest.fromJson(Object? value) {
    final json = Map<String, Object?>.from(value! as Map);
    if (json['version'] != 1) {
      throw FormatException(
        'unsupported host lease version: ${json['version']}',
      );
    }
    return HostCapacityRequest(
      vmId: VmId(json['vm_id']! as String),
      cpuCount: json['cpu_count']! as int,
      memoryBytes: json['memory_bytes']! as int,
      diskBytes: json['disk_bytes']! as int,
      driverProcesses: json['driver_processes']! as int,
      specGeneration: json['spec_generation']! as int,
      operationId: json['operation_id'] == null
          ? null
          : OperationId(json['operation_id']! as String),
      phase: switch (json['phase']) {
        'booting' => HostLeasePhase.booting,
        'running' => HostLeasePhase.running,
        'cleanup' => HostLeasePhase.cleanup,
        final value => throw FormatException('unsupported lease phase: $value'),
      },
    );
  }

  final VmId vmId;
  final int cpuCount;
  final int memoryBytes;
  final int diskBytes;
  final int driverProcesses;
  final HostLeasePhase phase;
  final int specGeneration;
  final OperationId? operationId;

  HostCapacityRequest copyWith({
    HostLeasePhase? phase,
    int? specGeneration,
    OperationId? operationId,
    bool clearOperationId = false,
  }) => HostCapacityRequest(
    vmId: vmId,
    cpuCount: cpuCount,
    memoryBytes: memoryBytes,
    diskBytes: diskBytes,
    driverProcesses: driverProcesses,
    phase: phase ?? this.phase,
    specGeneration: specGeneration ?? this.specGeneration,
    operationId: clearOperationId ? null : operationId ?? this.operationId,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'vm_id': vmId.value,
    'cpu_count': cpuCount,
    'memory_bytes': memoryBytes,
    'disk_bytes': diskBytes,
    'driver_processes': driverProcesses,
    'phase': phase.name,
    'spec_generation': specGeneration,
    'operation_id': operationId?.value,
  };

  @override
  bool operator ==(Object other) =>
      other is HostCapacityRequest &&
      other.vmId == vmId &&
      other.cpuCount == cpuCount &&
      other.memoryBytes == memoryBytes &&
      other.diskBytes == diskBytes &&
      other.driverProcesses == driverProcesses &&
      other.phase == phase &&
      other.specGeneration == specGeneration &&
      other.operationId == operationId;

  @override
  int get hashCode => Object.hash(
    vmId,
    cpuCount,
    memoryBytes,
    diskBytes,
    driverProcesses,
    phase,
    specGeneration,
    operationId,
  );
}

final class HostLease {
  const HostLease({
    required this.request,
    required this.ownerId,
    required this.acquiredAt,
    required this.expiresAt,
  });

  final HostCapacityRequest request;
  final String ownerId;
  final DateTime acquiredAt;
  final DateTime expiresAt;

  @override
  bool operator ==(Object other) =>
      other is HostLease &&
      other.request == request &&
      other.ownerId == ownerId &&
      other.acquiredAt == acquiredAt &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(request, ownerId, acquiredAt, expiresAt);
}

final class HostLeaseDecision {
  const HostLeaseDecision._({
    required this.request,
    required this.lease,
    required this.error,
    required this.constraint,
  });

  factory HostLeaseDecision.admitted(HostLease lease) => HostLeaseDecision._(
    request: lease.request,
    lease: lease,
    error: null,
    constraint: null,
  );

  factory HostLeaseDecision.rejected({
    required HostCapacityRequest request,
    required String constraint,
    required OperationError error,
  }) => HostLeaseDecision._(
    request: request,
    lease: null,
    error: error,
    constraint: constraint,
  );

  final HostCapacityRequest request;
  final HostLease? lease;
  final OperationError? error;
  final String? constraint;

  bool get admitted => lease != null;
}
