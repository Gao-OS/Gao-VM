import 'common.dart';
import 'resource_id.dart';
import 'operation.dart';

enum VmDisplayState { unknown, closed, opening, open, closing, error }

/// Last committed display observation, not VM or guest readiness.
final class VmDisplayStatus extends ValueObject {
  VmDisplayStatus({
    required this.vmId,
    required this.state,
    this.driverGeneration,
    this.observedAt,
  }) {
    if (driverGeneration != null && driverGeneration! < 1) {
      throw ArgumentError.value(
        driverGeneration,
        'driverGeneration',
        'must be positive or null',
      );
    }
  }

  factory VmDisplayStatus.fromJson(Object? value) {
    final json = readJsonObject(value, 'VM display status');
    expectJsonKeys(
      json,
      required: const {'vm_id', 'driver_generation', 'state', 'observed_at'},
      optional: const {},
      name: 'VM display status',
    );
    final generation = json['driver_generation'];
    if (generation != null && (generation is! int || generation < 1)) {
      throw const FormatException(
        'display driver_generation must be positive or null',
      );
    }
    final state = VmDisplayState.values
        .where((state) => state.name == json['state'])
        .firstOrNull;
    if (state == null) throw const FormatException('invalid display state');
    return VmDisplayStatus(
      vmId: VmId(requireJson<String>(json, 'vm_id')),
      state: state,
      driverGeneration: generation as int?,
      observedAt: nullableDateTime(json, 'observed_at'),
    );
  }
  final VmId vmId;
  final VmDisplayState state;
  final int? driverGeneration;
  final DateTime? observedAt;
  Map<String, Object?> toJson() => {
    'vm_id': vmId.value,
    'driver_generation': driverGeneration,
    'state': state.name,
    'observed_at': observedAt == null ? null : formatDateTime(observedAt!),
  };
  @override
  List<Object?> get equalityFields => [
    vmId,
    state,
    driverGeneration,
    observedAt,
  ];
}

/// Acceptance is not completion; read or wait for the durable Operation.
final class VmDisplayActionAcceptance extends ValueObject {
  VmDisplayActionAcceptance({
    required this.operationId,
    required this.vmId,
    required this.state,
  }) {
    if (!const {
      OperationState.pending,
      OperationState.running,
      OperationState.succeeded,
    }.contains(state)) {
      throw ArgumentError.value(
        state,
        'state',
        'invalid OperationAccepted state',
      );
    }
  }

  factory VmDisplayActionAcceptance.fromJson(Object? value) {
    final json = readJsonObject(value, 'display action acceptance');
    expectJsonKeys(
      json,
      required: const {'operation_id', 'state', 'resource_type', 'resource_id'},
      optional: const {},
      name: 'display action acceptance',
    );
    if (json['resource_type'] != 'virtual_machine') {
      throw const FormatException('display action acceptance must target a VM');
    }
    final state = OperationState.values
        .where((state) => state.name == json['state'])
        .firstOrNull;
    if (!const {
      OperationState.pending,
      OperationState.running,
      OperationState.succeeded,
    }.contains(state)) {
      throw const FormatException('invalid display action acceptance state');
    }
    return VmDisplayActionAcceptance(
      operationId: OperationId(requireJson<String>(json, 'operation_id')),
      vmId: VmId(requireJson<String>(json, 'resource_id')),
      state: state!,
    );
  }

  final OperationId operationId;
  final VmId vmId;
  final OperationState state;
  Map<String, Object?> toJson() => {
    'operation_id': operationId.value,
    'state': state.name,
    'resource_type': 'virtual_machine',
    'resource_id': vmId.value,
  };
  @override
  List<Object?> get equalityFields => [operationId, vmId, state];
}
