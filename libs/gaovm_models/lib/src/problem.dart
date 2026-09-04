import 'common.dart';
import 'json_value.dart';
import 'resource_id.dart';

final _problemTypePattern = RegExp(r'^https://gaovm\.dev/problems/[a-z0-9-]+$');

final class Problem extends ValueObject {
  Problem({
    required this.type,
    required this.title,
    required this.status,
    required this.code,
    required this.detail,
    required this.requestId,
    required this.retryable,
    this.operationId,
    required this.details,
  }) {
    requirePattern(type.toString(), _problemTypePattern, 'type');
    requireNonEmpty(title, 'title');
    requireRange(status, 400, 599, 'status');
  }

  factory Problem.fromJson(Object? value) {
    final json = readJsonObject(value, 'Problem');
    expectJsonKeys(
      json,
      required: const {
        'type',
        'title',
        'status',
        'code',
        'detail',
        'request_id',
        'retryable',
        'operation_id',
        'details',
      },
      optional: const {},
      name: 'Problem',
    );
    final operationId = nullableJson<String>(json, 'operation_id');
    return Problem(
      type: Uri.parse(requireJson<String>(json, 'type')),
      title: requireJson<String>(json, 'title'),
      status: requireJson<int>(json, 'status'),
      code: parseErrorCode(json['code']),
      detail: requireJson<String>(json, 'detail'),
      requestId: RequestId(requireJson<String>(json, 'request_id')),
      retryable: requireJson<bool>(json, 'retryable'),
      operationId: operationId == null ? null : OperationId(operationId),
      details: JsonObjectValue.fromJson(json['details']),
    );
  }

  final Uri type;
  final String title;
  final int status;
  final ErrorCode code;
  final String detail;
  final RequestId requestId;
  final bool retryable;
  final OperationId? operationId;
  final JsonObjectValue details;

  Map<String, Object?> toJson() => {
    'type': type.toString(),
    'title': title,
    'status': status,
    'code': errorCodeToJson(code),
    'detail': detail,
    'request_id': requestId.value,
    'retryable': retryable,
    'operation_id': operationId?.value,
    'details': details.toJson(),
  };

  @override
  List<Object?> get equalityFields => [
    type,
    title,
    status,
    code,
    detail,
    requestId,
    retryable,
    operationId,
    details,
  ];
}
