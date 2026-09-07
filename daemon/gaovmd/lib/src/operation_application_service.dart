import 'dart:async';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'operation_repository.dart';

/// Acceptance-time snapshot, stored verbatim by idempotency acceptance. It is
/// not reconstructed from the operation's later running or terminal state.
final class OperationAcceptance {
  OperationAcceptance({
    required this.operationId,
    required this.state,
    required this.resourceType,
    required this.resourceId,
  }) {
    if (!const {
      OperationState.pending,
      OperationState.running,
      OperationState.succeeded,
    }.contains(state)) {
      throw ArgumentError('invalid acceptance state');
    }
    if (!resourceId.matchesResourceType(resourceType)) {
      throw ArgumentError('acceptance resource type does not match its ID');
    }
  }
  factory OperationAcceptance.fromOperation(Operation operation) =>
      OperationAcceptance(
        operationId: operation.id,
        state: operation.state,
        resourceType: operation.resourceType,
        resourceId: operation.resourceId,
      );
  factory OperationAcceptance.fromJson(Map<String, Object?> json) {
    if (json.length != 4)
      throw const FormatException('invalid acceptance fields');
    final type = ResourceType.values.firstWhere(
      (type) => _resourceTypeName(type) == json['resource_type'],
      orElse: () =>
          throw const FormatException('invalid acceptance resource type'),
    );
    final state = OperationState.values.firstWhere(
      (state) => state.name == json['state'],
      orElse: () => throw const FormatException('invalid acceptance state'),
    );
    if (json['operation_id'] is! String || json['resource_id'] is! String) {
      throw const FormatException('invalid acceptance identifiers');
    }
    return OperationAcceptance(
      operationId: OperationId(json['operation_id'] as String),
      state: state,
      resourceType: type,
      resourceId: ResourceId.parse(json['resource_id'] as String),
    );
  }
  final OperationId operationId;
  final OperationState state;
  final ResourceType resourceType;
  final ResourceId resourceId;
  Map<String, Object?> toJson() => {
    'operation_id': operationId.value,
    'state': state.name,
    'resource_type': _resourceTypeName(resourceType),
    'resource_id': resourceId.value,
  };
}

final class OperationListQuery {
  OperationListQuery({
    this.cursor,
    this.limit = 50,
    this.resourceType,
    this.resourceId,
    this.state,
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
    if (resourceType != null &&
        resourceId != null &&
        !resourceId!.matchesResourceType(resourceType!)) {
      throw ArgumentError('resourceType does not match resourceId');
    }
  }

  final String? cursor;
  final int limit;
  final ResourceType? resourceType;
  final ResourceId? resourceId;
  final OperationState? state;
}

final class OperationPage {
  const OperationPage({required this.items, required this.nextCursor});

  final List<Operation> items;
  final String? nextCursor;
}

final class OperationCancelCommand {
  OperationCancelCommand({
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.operationId,
  }) : requestBody = List<int>.unmodifiable(requestBody) {
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255)) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'must be 1-255 chars',
      );
    }
  }

  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final OperationId operationId;
}

final class OperationWaitCommand {
  OperationWaitCommand({required this.operationId, required this.timeout}) {
    if (timeout <= Duration.zero || timeout > const Duration(days: 1)) {
      throw ArgumentError.value(timeout, 'timeout', 'must be in (0, 24h]');
    }
  }

  final OperationId operationId;
  final Duration timeout;
}

abstract interface class OperationMutationAcceptor {
  /// Atomically cancels the target operation and creates an `operation.cancel`
  /// action operation targeting it. Runtime cleanup dispatches after commit.
  Future<OperationAcceptance> cancel(OperationCancelCommand command);
}

abstract interface class OperationWaiter {
  Future<Operation> wait(OperationWaitCommand command);
}

final class OperationApplicationService {
  const OperationApplicationService({
    required OperationRepository repository,
    required OperationMutationAcceptor mutations,
    required OperationWaiter waiter,
  }) : _repository = repository,
       _mutations = mutations,
       _waiter = waiter;

  final OperationRepository _repository;
  final OperationMutationAcceptor _mutations;
  final OperationWaiter _waiter;

  Future<OperationPage> list([OperationListQuery? query]) async {
    final effective = query ?? OperationListQuery();
    final values = await _repository.list(
      resourceType: effective.resourceType,
      resourceId: effective.resourceId,
      state: effective.state,
    );
    var start = 0;
    final cursor = effective.cursor;
    if (cursor != null) {
      final anchor = _decodeCursor(cursor, effective);
      start = values.indexWhere((operation) {
        final comparison = operation.createdAt.compareTo(anchor.createdAt);
        return comparison > 0 ||
            comparison == 0 &&
                operation.id.value.compareTo(anchor.id.value) > 0;
      });
      if (start < 0) start = values.length;
    }
    final end = (start + effective.limit).clamp(0, values.length);
    final items = List<Operation>.unmodifiable(values.sublist(start, end));
    return OperationPage(
      items: items,
      nextCursor: end < values.length
          ? _encodeCursor(effective, items.last)
          : null,
    );
  }

  Future<Operation> get(OperationId operationId) async {
    final operation = await _repository.get(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    return operation;
  }

  Future<OperationAcceptance> cancel(OperationCancelCommand command) =>
      _mutations.cancel(command);

  Future<Operation> wait(OperationWaitCommand command) async {
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final budget = command.timeout - elapsed.elapsed;
      if (budget <= Duration.zero) {
        throw TimeoutException('operation wait timed out', command.timeout);
      }
      return budget;
    }

    try {
      final current = await get(command.operationId).timeout(remaining());
      remaining();
      if (_isTerminal(current.state)) return current;
      final completed = await _waiter
          .wait(
            OperationWaitCommand(
              operationId: command.operationId,
              timeout: remaining(),
            ),
          )
          .timeout(remaining());
      remaining();
      if (completed.id != command.operationId ||
          !_isTerminal(completed.state)) {
        throw StateError('operation waiter returned a non-terminal result');
      }
      return completed;
    } finally {
      elapsed.stop();
    }
  }
}

String _encodeCursor(OperationListQuery query, Operation operation) => base64Url
    .encode(
      utf8.encode(
        jsonEncode({
          'version': 2,
          'operation_id': operation.id.value,
          'created_at': operation.createdAt.toUtc().toIso8601String(),
          'resource_type': query.resourceType == null
              ? null
              : _resourceTypeName(query.resourceType!),
          'resource_id': query.resourceId?.value,
          'state': query.state?.name,
        }),
      ),
    )
    .replaceAll('=', '');

({OperationId id, DateTime createdAt}) _decodeCursor(
  String cursor,
  OperationListQuery query,
) {
  try {
    final normalized = cursor.padRight((cursor.length + 3) ~/ 4 * 4, '=');
    final value = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (value is! Map ||
        value['version'] != 2 ||
        value['operation_id'] is! String ||
        value['created_at'] is! String ||
        value['resource_type'] !=
            (query.resourceType == null
                ? null
                : _resourceTypeName(query.resourceType!)) ||
        value['resource_id'] != query.resourceId?.value ||
        value['state'] != query.state?.name) {
      throw const FormatException('invalid operation cursor');
    }
    return (
      id: OperationId(value['operation_id'] as String),
      createdAt: DateTime.parse(value['created_at'] as String).toUtc(),
    );
  } catch (_) {
    throw const FormatException('invalid operation cursor');
  }
}

bool _isTerminal(OperationState state) => switch (state) {
  OperationState.pending || OperationState.running => false,
  OperationState.succeeded ||
  OperationState.failed ||
  OperationState.cancelled => true,
};

String _resourceTypeName(ResourceType value) => switch (value) {
  ResourceType.virtualMachine => 'virtual_machine',
  ResourceType.image => 'image',
  ResourceType.operation => 'operation',
  ResourceType.testRun => 'test_run',
  ResourceType.artifact => 'artifact',
  ResourceType.system => 'system',
};
