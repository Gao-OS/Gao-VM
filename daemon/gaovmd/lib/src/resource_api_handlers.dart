import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'public_api_server.dart';
import 'vm_application_service.dart';
import 'vm_repository.dart';

final class ResourceApiHandlers {
  const ResourceApiHandlers({
    required VmApplicationService vms,
    required OperationApplicationService operations,
  }) : _vms = vms,
       _operations = operations;

  final VmApplicationService _vms;
  final OperationApplicationService _operations;

  void register(PublicApiRouter router) {
    router
      ..add('GET', '/v1/vms', _guard(_listVms))
      ..add('POST', '/v1/vms', _guard(_createVm))
      ..add('GET', '/v1/vms/{vm_id}', _guard(_getVm))
      ..add('PATCH', '/v1/vms/{vm_id}', _guard(_patchVm))
      ..add('DELETE', '/v1/vms/{vm_id}', _guard(_deleteVm))
      ..add(
        'POST',
        '/v1/vms/{vm_id}/actions/start',
        _guard((request) => _lifecycle(request, VmLifecycleAction.start)),
      )
      ..add(
        'POST',
        '/v1/vms/{vm_id}/actions/stop',
        _guard((request) => _lifecycle(request, VmLifecycleAction.stop)),
      )
      ..add(
        'POST',
        '/v1/vms/{vm_id}/actions/restart',
        _guard((request) => _lifecycle(request, VmLifecycleAction.restart)),
      )
      ..add(
        'POST',
        '/v1/vms/{vm_id}/actions/kill',
        _guard((request) => _lifecycle(request, VmLifecycleAction.kill)),
      )
      ..add(
        'POST',
        '/v1/vms/{vm_id}/wait',
        _guard(_waitForVm),
        allowsExtendedWait: true,
      )
      ..add('GET', '/v1/operations', _guard(_listOperations))
      ..add('GET', '/v1/operations/{operation_id}', _guard(_getOperation))
      ..add(
        'POST',
        '/v1/operations/{operation_id}/cancel',
        _guard(_cancelOperation),
      )
      ..add(
        'POST',
        '/v1/operations/{operation_id}/wait',
        _guard(_waitForOperation),
        allowsExtendedWait: true,
      );
  }

  Future<PublicApiResponse> _listVms(PublicApiRequest request) async {
    final query = request.uri.queryParameters;
    final selector = query['label_selector'];
    final page = await _vms.list(
      VmListQuery(
        cursor: query['cursor'],
        limit: _limit(query['limit']),
        selector: selector == null ? null : LabelSelector.parse(selector),
        sort: parseVmSort(query['sort']),
      ),
    );
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: {
        'items': page.items.map((item) => item.toJson()).toList(),
        'next_cursor': page.nextCursor,
      },
    );
  }

  Future<PublicApiResponse> _createVm(PublicApiRequest request) async {
    final body = _body(request, required: true);
    _requireKeys(
      body,
      required: const {'api_version', 'kind', 'metadata', 'spec'},
      name: 'VM create request',
    );
    if (body['api_version'] != vmApiVersion || body['kind'] != vmKind) {
      throw const FormatException('unsupported VM api_version or kind');
    }
    final metadata = _object(body['metadata'], 'metadata');
    _requireKeys(
      metadata,
      required: const {'name'},
      allowed: const {'name', 'labels'},
      name: 'metadata',
    );
    final name = _string(metadata['name'], 'metadata.name');
    final labels = metadata.containsKey('labels')
        ? _labels(metadata['labels'])
        : <String, String>{};
    final operation = await _vms.create(
      VmCreateCommand(
        requestId: request.requestId,
        idempotencyKey: _idempotencyKey(request),
        requestBody: request.bodyBytes,
        name: name,
        labels: labels,
        spec: VmSpec.fromJson(body['spec']),
      ),
    );
    return _accepted(operation);
  }

  Future<PublicApiResponse> _getVm(PublicApiRequest request) async {
    final virtualMachine = await _vms.get(_vmId(request));
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: virtualMachine.toJson(),
      headers: {'ETag': '"${virtualMachine.metadata.revision}"'},
    );
  }

  Future<PublicApiResponse> _patchVm(PublicApiRequest request) async {
    final body = _body(request, required: true);
    _requireKeys(
      body,
      required: const {},
      allowed: const {'metadata', 'spec'},
      name: 'VM patch request',
    );
    if (body.isEmpty) throw const FormatException('VM patch is empty');
    String? name;
    Map<String, String>? labels;
    if (body.containsKey('metadata')) {
      final metadata = _object(body['metadata'], 'metadata');
      _requireKeys(
        metadata,
        required: const {},
        allowed: const {'name', 'labels'},
        name: 'metadata',
      );
      if (metadata.isEmpty)
        throw const FormatException('metadata patch is empty');
      if (metadata.containsKey('name')) {
        name = _string(metadata['name'], 'metadata.name');
      }
      if (metadata.containsKey('labels')) labels = _labels(metadata['labels']);
    }
    final spec = body.containsKey('spec')
        ? VmSpecPatch.fromJson(body['spec'])
        : null;
    final operation = await _vms.patch(
      VmPatchCommand(
        requestId: request.requestId,
        idempotencyKey: _idempotencyKey(request),
        requestBody: request.bodyBytes,
        vmId: _vmId(request),
        expectedRevision: _ifMatch(request),
        name: name,
        labels: labels,
        spec: spec,
      ),
    );
    return _accepted(operation);
  }

  Future<PublicApiResponse> _deleteVm(PublicApiRequest request) =>
      _lifecycle(request, VmLifecycleAction.delete);

  Future<PublicApiResponse> _lifecycle(
    PublicApiRequest request,
    VmLifecycleAction action,
  ) async {
    final body = _body(request, required: false);
    _requireKeys(
      body,
      required: const {},
      allowed: const {'reason', 'deadline_at'},
      name: 'VM action request',
    );
    final reason = body.containsKey('reason')
        ? _string(body['reason'], 'reason', allowEmpty: true)
        : null;
    final deadlineAt = body.containsKey('deadline_at')
        ? _dateTime(body['deadline_at'], 'deadline_at')
        : null;
    final operation = await _vms.lifecycle(
      VmLifecycleCommand(
        requestId: request.requestId,
        idempotencyKey: _idempotencyKey(request),
        requestBody: request.bodyBytes,
        vmId: _vmId(request),
        action: action,
        reason: reason,
        deadlineAt: deadlineAt,
      ),
    );
    return _accepted(operation);
  }

  Future<PublicApiResponse> _waitForVm(PublicApiRequest request) async {
    final body = _body(request, required: true);
    _requireKeys(
      body,
      required: const {'condition', 'timeout_seconds'},
      allowed: const {'condition', 'timeout_seconds', 'service_name'},
      name: 'VM wait request',
    );
    final command = VmWaitCommand(
      vmId: _vmId(request),
      condition: parseVmWaitCondition(_string(body['condition'], 'condition')),
      timeout: _timeout(body['timeout_seconds']),
      serviceName: body.containsKey('service_name')
          ? _string(body['service_name'], 'service_name')
          : null,
    );
    request.extendResponseDeadlineForWait(command.timeout);
    final result = await _vms.wait(command);
    return PublicApiResponse.json(status: HttpStatus.ok, body: result.toJson());
  }

  Future<PublicApiResponse> _listOperations(PublicApiRequest request) async {
    final query = request.uri.queryParameters;
    final resourceType = query['resource_type'] == null
        ? null
        : _resourceType(query['resource_type']!);
    final resourceId = query['resource_id'] == null
        ? null
        : ResourceId.parse(query['resource_id']!);
    final state = query['state'] == null
        ? null
        : _operationState(query['state']!);
    final page = await _operations.list(
      OperationListQuery(
        cursor: query['cursor'],
        limit: _limit(query['limit']),
        resourceType: resourceType,
        resourceId: resourceId,
        state: state,
      ),
    );
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: {
        'items': page.items.map((operation) => operation.toJson()).toList(),
        'next_cursor': page.nextCursor,
      },
    );
  }

  Future<PublicApiResponse> _getOperation(PublicApiRequest request) async {
    final operation = await _operations.get(_operationId(request));
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: operation.toJson(),
    );
  }

  Future<PublicApiResponse> _cancelOperation(PublicApiRequest request) async {
    final operation = await _operations.cancel(
      OperationCancelCommand(
        requestId: request.requestId,
        idempotencyKey: _idempotencyKey(request),
        requestBody: request.bodyBytes,
        operationId: _operationId(request),
      ),
    );
    return _accepted(operation);
  }

  Future<PublicApiResponse> _waitForOperation(PublicApiRequest request) async {
    final body = _body(request, required: true);
    _requireKeys(
      body,
      required: const {'timeout_seconds'},
      name: 'operation wait request',
    );
    final command = OperationWaitCommand(
      operationId: _operationId(request),
      timeout: _timeout(body['timeout_seconds']),
    );
    request.extendResponseDeadlineForWait(command.timeout);
    final operation = await _operations.wait(command);
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: operation.toJson(),
    );
  }
}

PublicApiHandler _guard(
  Future<PublicApiResponse> Function(PublicApiRequest request) handler,
) => (request) async {
  try {
    return await handler(request);
  } on PublicApiException {
    rethrow;
  } on VmNotFoundException catch (error) {
    throw _problem(
      status: HttpStatus.notFound,
      code: ErrorCode.vmNotFound,
      type: 'vm-not-found',
      title: 'VM not found',
      detail: 'No VM exists with id ${error.id.value}.',
    );
  } on OperationNotFoundException catch (error) {
    throw _problem(
      status: HttpStatus.notFound,
      code: ErrorCode.operationNotFound,
      type: 'operation-not-found',
      title: 'Operation not found',
      detail: 'No operation exists with id ${error.id.value}.',
    );
  } on VmAcceptanceConflict catch (error) {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.vmOperationConflict,
      type: 'vm-operation-conflict',
      title: 'VM operation conflict',
      detail: 'The VM has an accepted deletion that prevents this action.',
      details: JsonObjectValue.fromJson({'vm_id': error.vmId.value}),
    );
  } on RevisionConflictException catch (error) {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.revisionConflict,
      type: 'revision-conflict',
      title: 'Revision conflict',
      detail: 'The VM revision does not match If-Match.',
      details: JsonObjectValue.fromJson({
        'expected_revision': error.expectedRevision,
        'actual_revision': error.actualRevision,
      }),
    );
  } on IdempotencyConflictException {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.idempotencyConflict,
      type: 'idempotency-conflict',
      title: 'Idempotency conflict',
      detail: 'The idempotency key belongs to a different request.',
    );
  } on IdempotencyInProgressException {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.vmOperationConflict,
      type: 'idempotency-in-progress',
      title: 'Request already in progress',
      detail: 'The idempotent request has not reached a durable response.',
      retryable: true,
    );
  } on OperationNotCancellableException catch (error) {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.operationNotCancellable,
      type: 'operation-not-cancellable',
      title: 'Operation is not cancellable',
      detail: 'Operation ${error.id.value} cannot be cancelled now.',
    );
  } on InvalidOperationTransitionException catch (error) {
    throw _problem(
      status: HttpStatus.conflict,
      code: ErrorCode.vmOperationConflict,
      type: 'operation-conflict',
      title: 'Operation conflict',
      detail: 'Operation ${error.id.value} cannot transition now.',
    );
  } on TimeoutException {
    throw _problem(
      status: HttpStatus.gatewayTimeout,
      code: ErrorCode.waitTimeout,
      type: 'wait-timeout',
      title: 'Wait timeout',
      detail: 'The requested condition was not reached before the timeout.',
      retryable: true,
    );
  } on FormatException catch (error) {
    throw _invalidRequest(error.message);
  } on ArgumentError catch (error) {
    throw _invalidRequest(error.message?.toString() ?? 'Invalid request.');
  }
};

PublicApiResponse _accepted(OperationAcceptance operation) {
  return PublicApiResponse.json(
    status: HttpStatus.accepted,
    body: operation.toJson(),
    headers: {'Location': '/v1/operations/${operation.operationId.value}'},
  );
}

PublicApiException _invalidRequest(String detail) => _problem(
  status: HttpStatus.badRequest,
  code: ErrorCode.invalidRequest,
  type: 'invalid-request',
  title: 'Invalid request',
  detail: detail,
);

PublicApiException _problem({
  required int status,
  required ErrorCode code,
  required String type,
  required String title,
  required String detail,
  bool retryable = false,
  JsonObjectValue? details,
}) => PublicApiException(
  PublicApiProblem(
    status: status,
    code: code,
    type: type,
    title: title,
    detail: detail,
    retryable: retryable,
    details: details ?? JsonObjectValue.empty,
  ),
);

Map<String, Object?> _body(PublicApiRequest request, {required bool required}) {
  final body = request.jsonBody?.toJson();
  if (body == null) {
    if (required) throw const FormatException('request body is required');
    return const {};
  }
  return body;
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object');
  try {
    return Map<String, Object?>.from(value);
  } catch (_) {
    throw FormatException('$name contains a non-string key');
  }
}

void _requireKeys(
  Map<String, Object?> value, {
  required Set<String> required,
  Set<String>? allowed,
  required String name,
}) {
  final missing = required.difference(value.keys.toSet());
  final extras = value.keys.toSet().difference(allowed ?? required);
  if (missing.isNotEmpty || extras.isNotEmpty) {
    throw FormatException('$name has invalid fields');
  }
}

String _string(Object? value, String name, {bool allowEmpty = false}) {
  if (value is! String || !allowEmpty && value.isEmpty) {
    throw FormatException(
      '$name must be ${allowEmpty ? 'a' : 'a non-empty'} string',
    );
  }
  return value;
}

Map<String, String> _labels(Object? value) {
  if (value is! Map) throw const FormatException('labels must be an object');
  try {
    return Map<String, String>.from(value);
  } catch (_) {
    throw const FormatException('labels must contain string values');
  }
}

DateTime _dateTime(Object? value, String name) {
  if (value is! String) throw FormatException('$name must be a date-time');
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([Zz]|[+-](\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (match == null)
    throw FormatException('$name must be an RFC3339 date-time');
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final local = DateTime.utc(year, month, day);
  if (local.year != year ||
      local.month != month ||
      local.day != day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      match[8] != null &&
          (int.parse(match[8]!) > 23 || int.parse(match[9]!) > 59)) {
    throw FormatException('$name contains an invalid date or offset');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$name must be a date-time');
  return parsed.toUtc();
}

Duration _timeout(Object? value) {
  if (value is! num || !value.isFinite || value <= 0 || value > 86400) {
    throw const FormatException('timeout_seconds must be in (0, 86400]');
  }
  return Duration(
    microseconds: (value * Duration.microsecondsPerSecond).round(),
  );
}

int _limit(String? value) {
  if (value == null) return 50;
  final parsed = int.tryParse(value);
  if (parsed == null) throw const FormatException('limit must be an integer');
  return parsed;
}

VmId _vmId(PublicApiRequest request) {
  final value = request.pathParameters['vm_id'];
  if (value == null) throw const FormatException('vm_id is missing');
  return VmId(value);
}

OperationId _operationId(PublicApiRequest request) {
  final value = request.pathParameters['operation_id'];
  if (value == null) throw const FormatException('operation_id is missing');
  return OperationId(value);
}

int _ifMatch(PublicApiRequest request) {
  final values = request.headers['if-match'];
  if (values == null || values.length != 1) {
    throw const FormatException('If-Match is required');
  }
  final match = RegExp(r'^"([1-9][0-9]*)"$').firstMatch(values.single);
  if (match == null) throw const FormatException('If-Match is invalid');
  return int.parse(match.group(1)!);
}

String? _idempotencyKey(PublicApiRequest request) {
  final values = request.headers['idempotency-key'];
  if (values == null) return null;
  if (values.length != 1) {
    throw const FormatException('Idempotency-Key must appear once');
  }
  final value = values.single;
  if (value.isEmpty || value.length > 255) {
    throw const FormatException('Idempotency-Key must be 1-255 chars');
  }
  return value;
}

ResourceType _resourceType(String value) => switch (value) {
  'virtual_machine' => ResourceType.virtualMachine,
  'image' => ResourceType.image,
  'operation' => ResourceType.operation,
  'test_run' => ResourceType.testRun,
  'artifact' => ResourceType.artifact,
  _ => throw FormatException('unsupported resource_type: $value'),
};

OperationState _operationState(String value) => switch (value) {
  'pending' => OperationState.pending,
  'running' => OperationState.running,
  'succeeded' => OperationState.succeeded,
  'failed' => OperationState.failed,
  'cancelled' => OperationState.cancelled,
  _ => throw FormatException('unsupported operation state: $value'),
};
