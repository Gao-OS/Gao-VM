import 'common.dart';
import 'json_value.dart';
import 'resource_id.dart';

final _operationTypePattern = RegExp(r'^[a-z][a-z0-9_.-]*$');

enum OperationState { pending, running, succeeded, failed, cancelled }

OperationState _parseOperationState(Object? value) => switch (value) {
  'pending' => OperationState.pending,
  'running' => OperationState.running,
  'succeeded' => OperationState.succeeded,
  'failed' => OperationState.failed,
  'cancelled' => OperationState.cancelled,
  _ => throw FormatException('unsupported operation state: $value'),
};

final class OperationProgress extends ValueObject {
  OperationProgress({this.percent, this.step}) {
    if (percent != null) requireRange(percent!, 0, 100, 'percent');
  }

  factory OperationProgress.fromJson(Object? value) {
    final json = readJsonObject(value, 'operation progress');
    expectJsonKeys(
      json,
      required: const {},
      optional: const {'percent', 'step'},
      name: 'operation progress',
    );
    return OperationProgress(
      percent: optionalJson<num>(json, 'percent'),
      step: nullableJson<String>(json, 'step'),
    );
  }

  final num? percent;
  final String? step;

  Map<String, Object?> toJson() => {
    if (percent != null) 'percent': percent,
    if (step != null) 'step': step,
  };

  @override
  List<Object?> get equalityFields => [percent, step];
}

final class OperationError extends ValueObject {
  OperationError({
    required this.code,
    required this.message,
    required this.retryable,
    required this.details,
  }) {
    requireNonEmpty(message, 'message');
  }

  factory OperationError.fromJson(Object? value) {
    final json = readJsonObject(value, 'operation error');
    expectJsonKeys(
      json,
      required: const {'code', 'message', 'retryable', 'details'},
      optional: const {},
      name: 'operation error',
    );
    return OperationError(
      code: parseErrorCode(json['code']),
      message: requireJson<String>(json, 'message'),
      retryable: requireJson<bool>(json, 'retryable'),
      details: JsonObjectValue.fromJson(json['details']),
    );
  }

  final ErrorCode code;
  final String message;
  final bool retryable;
  final JsonObjectValue details;

  Map<String, Object?> toJson() => {
    'code': errorCodeToJson(code),
    'message': message,
    'retryable': retryable,
    'details': details.toJson(),
  };

  @override
  List<Object?> get equalityFields => [code, message, retryable, details];
}

final class Operation extends ValueObject {
  Operation({
    required this.id,
    required this.type,
    required this.resourceType,
    required this.resourceId,
    required this.state,
    required this.requestId,
    this.idempotencyKey,
    required this.cancellable,
    OperationProgress? progress,
    required this.request,
    this.result,
    this.error,
    required DateTime createdAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? deadlineAt,
  }) : progress = progress ?? OperationProgress(),
       createdAt = createdAt.toUtc(),
       startedAt = startedAt?.toUtc(),
       completedAt = completedAt?.toUtc(),
       deadlineAt = deadlineAt?.toUtc() {
    requirePattern(type, _operationTypePattern, 'type');
    if (!resourceId.matchesResourceType(resourceType)) {
      throw ArgumentError('resourceType does not match resourceId');
    }
  }

  factory Operation.fromJson(Object? value) {
    final json = readJsonObject(value, 'Operation');
    expectJsonKeys(
      json,
      required: const {
        'id',
        'type',
        'resource_type',
        'resource_id',
        'state',
        'request_id',
        'idempotency_key',
        'cancellable',
        'progress',
        'request',
        'result',
        'error',
        'created_at',
        'started_at',
        'completed_at',
        'deadline_at',
      },
      optional: const {},
      name: 'Operation',
    );
    return Operation(
      id: OperationId(requireJson<String>(json, 'id')),
      type: requireJson<String>(json, 'type'),
      resourceType: parseResourceType(json['resource_type']),
      resourceId: ResourceId.parse(requireJson<String>(json, 'resource_id')),
      state: _parseOperationState(json['state']),
      requestId: RequestId(requireJson<String>(json, 'request_id')),
      idempotencyKey: nullableJson<String>(json, 'idempotency_key'),
      cancellable: requireJson<bool>(json, 'cancellable'),
      progress: OperationProgress.fromJson(json['progress']),
      request: JsonObjectValue.fromJson(json['request']),
      result: json['result'] == null
          ? null
          : JsonObjectValue.fromJson(json['result']),
      error: json['error'] == null
          ? null
          : OperationError.fromJson(json['error']),
      createdAt: requireDateTime(json, 'created_at'),
      startedAt: nullableDateTime(json, 'started_at'),
      completedAt: nullableDateTime(json, 'completed_at'),
      deadlineAt: nullableDateTime(json, 'deadline_at'),
    );
  }

  final OperationId id;
  final String type;
  final ResourceType resourceType;
  final ResourceId resourceId;
  final OperationState state;
  final RequestId requestId;
  final String? idempotencyKey;
  final bool cancellable;
  final OperationProgress progress;
  final JsonObjectValue request;
  final JsonObjectValue? result;
  final OperationError? error;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? deadlineAt;

  Map<String, Object?> toJson() => {
    'id': id.value,
    'type': type,
    'resource_type': resourceTypeToJson(resourceType),
    'resource_id': resourceId.value,
    'state': state.name,
    'request_id': requestId.value,
    'idempotency_key': idempotencyKey,
    'cancellable': cancellable,
    'progress': progress.toJson(),
    'request': request.toJson(),
    'result': result?.toJson(),
    'error': error?.toJson(),
    'created_at': formatDateTime(createdAt),
    'started_at': startedAt == null ? null : formatDateTime(startedAt!),
    'completed_at': completedAt == null ? null : formatDateTime(completedAt!),
    'deadline_at': deadlineAt == null ? null : formatDateTime(deadlineAt!),
  };

  @override
  List<Object?> get equalityFields => [
    id,
    type,
    resourceType,
    resourceId,
    state,
    requestId,
    idempotencyKey,
    cancellable,
    progress,
    request,
    result,
    error,
    createdAt,
    startedAt,
    completedAt,
    deadlineAt,
  ];
}
