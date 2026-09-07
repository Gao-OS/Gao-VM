import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'vm_repository.dart';
import 'operation_application_service.dart';

enum VmSort {
  createdAt,
  createdAtDescending,
  name,
  nameDescending,
  id,
  idDescending,
}

VmSort parseVmSort(String? value) => switch (value) {
  null || 'created_at' => VmSort.createdAt,
  '-created_at' => VmSort.createdAtDescending,
  'name' => VmSort.name,
  '-name' => VmSort.nameDescending,
  'id' => VmSort.id,
  '-id' => VmSort.idDescending,
  _ => throw FormatException('unsupported VM sort: $value'),
};

String vmSortToJson(VmSort value) => switch (value) {
  VmSort.createdAt => 'created_at',
  VmSort.createdAtDescending => '-created_at',
  VmSort.name => 'name',
  VmSort.nameDescending => '-name',
  VmSort.id => 'id',
  VmSort.idDescending => '-id',
};

final class VmListQuery {
  VmListQuery({
    this.cursor,
    this.limit = 50,
    this.selector,
    this.sort = VmSort.createdAt,
  }) {
    if (limit < 1 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 200');
    }
    if (cursor != null && (cursor!.isEmpty || cursor!.length > 512)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'must contain 1 to 512 bytes',
      );
    }
  }

  final String? cursor;
  final int limit;
  final LabelSelector? selector;
  final VmSort sort;
}

final class VmPage {
  const VmPage({required this.items, required this.nextCursor});

  final List<VirtualMachine> items;
  final String? nextCursor;
}

enum VmLifecycleAction { start, stop, restart, kill, delete }

final class VmAcceptanceConflict implements Exception {
  const VmAcceptanceConflict(this.vmId);
  final VmId vmId;
  @override
  String toString() => 'VM deletion has already been accepted: $vmId';
}

final class VmCreateCommand {
  VmCreateCommand({
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.name,
    Map<String, String> labels = const {},
    required this.spec,
  }) : requestBody = List<int>.unmodifiable(requestBody),
       labels = Map<String, String>.unmodifiable(labels) {
    _validateIdempotencyKey(idempotencyKey);
    _validateMetadata(name, this.labels);
  }

  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final String name;
  final Map<String, String> labels;
  final VmSpec spec;
}

final class VmPatchCommand {
  VmPatchCommand({
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.vmId,
    required this.expectedRevision,
    this.name,
    Map<String, String>? labels,
    this.spec,
  }) : requestBody = List<int>.unmodifiable(requestBody),
       labels = labels == null
           ? null
           : Map<String, String>.unmodifiable(labels) {
    _validateIdempotencyKey(idempotencyKey);
    _validateMetadata(name, this.labels);
    if (expectedRevision < 1) {
      throw ArgumentError.value(expectedRevision, 'expectedRevision');
    }
    if (name == null && this.labels == null && spec == null) {
      throw ArgumentError('VM patch must contain metadata or spec changes');
    }
  }

  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final VmId vmId;
  final int expectedRevision;
  final String? name;
  final Map<String, String>? labels;
  final VmSpecPatch? spec;
}

final class VmLifecycleCommand {
  VmLifecycleCommand({
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.vmId,
    required this.action,
    this.reason,
    this.deadlineAt,
  }) : requestBody = List<int>.unmodifiable(requestBody) {
    _validateIdempotencyKey(idempotencyKey);
    if (reason != null && reason!.length > 1024) {
      throw ArgumentError.value(reason, 'reason', 'must be at most 1024 chars');
    }
  }

  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final VmId vmId;
  final VmLifecycleAction action;
  final String? reason;
  final DateTime? deadlineAt;
}

enum VmWaitCondition { runtimeRunning, guestAgentReady, guestServiceReady }

VmWaitCondition parseVmWaitCondition(String value) => switch (value) {
  'runtime_running' => VmWaitCondition.runtimeRunning,
  'guest_agent_ready' => VmWaitCondition.guestAgentReady,
  'guest_service_ready' => VmWaitCondition.guestServiceReady,
  _ => throw FormatException('unsupported VM wait condition: $value'),
};

String vmWaitConditionToJson(VmWaitCondition value) => switch (value) {
  VmWaitCondition.runtimeRunning => 'runtime_running',
  VmWaitCondition.guestAgentReady => 'guest_agent_ready',
  VmWaitCondition.guestServiceReady => 'guest_service_ready',
};

final class VmWaitCommand {
  VmWaitCommand({
    required this.vmId,
    required this.condition,
    required this.timeout,
    this.serviceName,
  }) {
    if (timeout <= Duration.zero || timeout > const Duration(days: 1)) {
      throw ArgumentError.value(timeout, 'timeout', 'must be in (0, 24h]');
    }
    if (condition == VmWaitCondition.guestServiceReady) {
      if (serviceName == null || serviceName!.isEmpty) {
        throw ArgumentError('guest service wait requires serviceName');
      }
    } else if (serviceName != null) {
      throw ArgumentError('serviceName is only valid for guest service wait');
    }
  }

  final VmId vmId;
  final VmWaitCondition condition;
  final Duration timeout;
  final String? serviceName;
}

final class VmWaitResult {
  const VmWaitResult({
    required this.vmId,
    required this.condition,
    required this.observedAt,
  });

  final VmId vmId;
  final VmWaitCondition condition;
  final DateTime observedAt;

  Map<String, Object?> toJson() => {
    'vm_id': vmId.value,
    'condition': vmWaitConditionToJson(condition),
    'reached': true,
    'observed_at': observedAt.toUtc().toIso8601String(),
  };
}

abstract interface class VmMutationAcceptor {
  /// Atomically persists the resource, operation, idempotency response, and a
  /// recoverable post-commit provisioning command.
  Future<OperationAcceptance> create(VmCreateCommand command);

  /// Atomically persists OCC changes, the operation/idempotency response, and
  /// any controller notification required after commit.
  Future<OperationAcceptance> patch(VmPatchCommand command);

  /// Atomically persists desired state, the operation/idempotency response,
  /// and a recoverable serialized controller command.
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand command);
}

abstract interface class VmProvisioningService {
  Future<void> provision(VirtualMachine virtualMachine, Operation operation);
}

abstract interface class VmConditionWaiter {
  Future<DateTime> wait(VmWaitCommand command);
}

final class VmApplicationService {
  const VmApplicationService({
    required VmRepository repository,
    required VmMutationAcceptor mutations,
    required VmConditionWaiter waiter,
  }) : _repository = repository,
       _mutations = mutations,
       _waiter = waiter;

  final VmRepository _repository;
  final VmMutationAcceptor _mutations;
  final VmConditionWaiter _waiter;

  Future<VmPage> list([VmListQuery? query]) async {
    final effective = query ?? VmListQuery();
    final values = List<VirtualMachine>.of(
      await _repository.list(labelSelector: effective.selector),
    )..sort(_vmComparator(effective.sort));
    var start = 0;
    final cursor = effective.cursor;
    if (cursor != null) {
      final anchor = _decodeVmCursor(
        cursor,
        effective.sort,
        effective.selector,
      );
      start = values.indexWhere(
        (vm) =>
            _compareVmKey(
              _vmKey(vm, effective.sort),
              vm.metadata.id,
              anchor.key,
              anchor.id,
              effective.sort,
            ) >
            0,
      );
      if (start < 0) start = values.length;
    }
    final end = (start + effective.limit).clamp(0, values.length);
    final items = List<VirtualMachine>.unmodifiable(values.sublist(start, end));
    return VmPage(
      items: items,
      nextCursor: end < values.length
          ? _encodeVmCursor(effective.sort, effective.selector, items.last)
          : null,
    );
  }

  Future<VirtualMachine> get(VmId vmId) async {
    final virtualMachine = await _repository.get(vmId);
    if (virtualMachine == null) throw VmNotFoundException(vmId);
    return virtualMachine;
  }

  Future<OperationAcceptance> create(VmCreateCommand command) =>
      _mutations.create(command);

  Future<OperationAcceptance> patch(VmPatchCommand command) =>
      _mutations.patch(command);

  Future<OperationAcceptance> lifecycle(VmLifecycleCommand command) =>
      _mutations.lifecycle(command);

  Future<VmWaitResult> wait(VmWaitCommand command) async {
    await get(command.vmId);
    final observedAt = await _waiter.wait(command);
    return VmWaitResult(
      vmId: command.vmId,
      condition: command.condition,
      observedAt: observedAt,
    );
  }
}

Comparator<VirtualMachine> _vmComparator(VmSort sort) {
  int ascending(VirtualMachine left, VirtualMachine right) {
    final comparison = switch (sort) {
      VmSort.createdAt || VmSort.createdAtDescending =>
        left.metadata.createdAt.compareTo(right.metadata.createdAt),
      VmSort.name || VmSort.nameDescending => left.metadata.name.compareTo(
        right.metadata.name,
      ),
      VmSort.id || VmSort.idDescending => left.metadata.id.value.compareTo(
        right.metadata.id.value,
      ),
    };
    return comparison != 0
        ? comparison
        : left.metadata.id.value.compareTo(right.metadata.id.value);
  }

  final descending = switch (sort) {
    VmSort.createdAtDescending ||
    VmSort.nameDescending ||
    VmSort.idDescending => true,
    _ => false,
  };
  return descending ? (left, right) => -ascending(left, right) : ascending;
}

String _encodeVmCursor(
  VmSort sort,
  LabelSelector? selector,
  VirtualMachine vm,
) {
  final selectorHash = _selectorHash(selector);
  // Fixed header + UTF-16 key stays below the public 512-character cursor limit
  // even for a maximal non-ASCII VM name. Cursor names use Dart's code-unit sort.
  return base64Url
      .encode([
        2,
        sort.index,
        selectorHash == null ? 0 : 1,
        if (selectorHash != null) ...ascii.encode(selectorHash),
        ...ascii.encode(vm.metadata.id.value),
        for (final unit in _vmKey(vm, sort).codeUnits) ...[
          unit >> 8,
          unit & 255,
        ],
      ])
      .replaceAll('=', '');
}

({VmId id, String key}) _decodeVmCursor(
  String cursor,
  VmSort sort,
  LabelSelector? selector,
) {
  try {
    final normalized = cursor.padRight((cursor.length + 3) ~/ 4 * 4, '=');
    final value = base64Url.decode(normalized);
    final hash = _selectorHash(selector);
    if (value.length < 34 ||
        value[0] != 2 ||
        value[1] != sort.index ||
        value[2] != (hash == null ? 0 : 1))
      throw const FormatException('invalid VM cursor');
    final offset = hash == null ? 3 : 67;
    if (value.length < offset + 31 ||
        (value.length - offset - 29).isOdd ||
        hash != null && ascii.decode(value.sublist(3, 67)) != hash) {
      throw const FormatException('invalid VM cursor');
    }
    final id = VmId(ascii.decode(value.sublist(offset, offset + 29)));
    final key = String.fromCharCodes([
      for (var index = offset + 29; index < value.length; index += 2)
        value[index] * 256 + value[index + 1],
    ]);
    if (sort == VmSort.createdAt || sort == VmSort.createdAtDescending)
      DateTime.parse(key);
    return (id: id, key: key);
  } catch (_) {
    throw const FormatException('invalid VM cursor');
  }
}

String? _selectorHash(LabelSelector? selector) => selector == null
    ? null
    : sha256.convert(utf8.encode(selector.toString())).toString();

void _validateIdempotencyKey(String? value) {
  if (value != null && (value.isEmpty || value.length > 255)) {
    throw ArgumentError.value(value, 'idempotencyKey', 'must be 1-255 chars');
  }
}

void _validateMetadata(String? name, Map<String, String>? labels) {
  if (name != null && (name.isEmpty || name.length > 128)) {
    throw ArgumentError('name must contain 1 to 128 characters');
  }
  if (labels != null) {
    if (labels.length > 64 ||
        labels.entries.any(
          (entry) =>
              !RegExp(
                r'^[A-Za-z0-9](?:[A-Za-z0-9._/-]*[A-Za-z0-9])?$',
              ).hasMatch(entry.key) ||
              entry.value.length > 253,
        ))
      throw ArgumentError('invalid labels');
  }
}

String _vmKey(VirtualMachine vm, VmSort sort) => switch (sort) {
  VmSort.createdAt ||
  VmSort.createdAtDescending => vm.metadata.createdAt.toUtc().toIso8601String(),
  VmSort.name || VmSort.nameDescending => vm.metadata.name,
  VmSort.id || VmSort.idDescending => vm.metadata.id.value,
};
int _compareVmKey(
  String left,
  VmId leftId,
  String right,
  VmId rightId,
  VmSort sort,
) {
  var comparison =
      sort == VmSort.createdAt || sort == VmSort.createdAtDescending
      ? DateTime.parse(left).compareTo(DateTime.parse(right))
      : left.compareTo(right);
  if (comparison == 0) comparison = leftId.value.compareTo(rightId.value);
  return const {
        VmSort.createdAtDescending,
        VmSort.nameDescending,
        VmSort.idDescending,
      }.contains(sort)
      ? -comparison
      : comparison;
}
