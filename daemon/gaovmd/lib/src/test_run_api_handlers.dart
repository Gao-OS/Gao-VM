import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'image_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'public_api_server.dart';
import 'test_run_application_service.dart';
import 'test_run_repository.dart';

final class TestRunApiHandlers {
  const TestRunApiHandlers({required this.runs});
  final TestRunApplicationService runs;

  void register(PublicApiRouter router) {
    router
      ..add('POST', '/v1/test-runs', _guard(_create))
      ..add('GET', '/v1/test-runs/{test_run_id}', _guard(_get))
      ..add('POST', '/v1/test-runs/{test_run_id}/cancel', _guard(_cancel));
  }

  Future<PublicApiResponse> _create(PublicApiRequest request) async =>
      _accepted(
        await runs.create(
          TestRunCreateCommand(
            requestId: request.requestId,
            idempotencyKey: _key(request),
            requestBody: request.bodyBytes,
            spec: TestRunSpec.fromJson(request.jsonBody?.toJson()),
          ),
        ),
      );

  Future<PublicApiResponse> _get(PublicApiRequest request) async {
    _noBody(request);
    final run = await runs.get(
      TestRunId(request.pathParameters['test_run_id']!),
    );
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: run.toJson(),
      logCorrelation: PublicApiLogCorrelation(
        vmId: run.vmId,
        operationId: run.operationId,
        testRunId: run.id,
      ),
    );
  }

  Future<PublicApiResponse> _cancel(PublicApiRequest request) async {
    _noBody(request);
    return _accepted(
      await runs.cancelRun(
        TestRunCancelCommand(
          testRunId: TestRunId(request.pathParameters['test_run_id']!),
          requestId: request.requestId,
          idempotencyKey: _key(request),
          requestBody: request.bodyBytes,
        ),
      ),
    );
  }
}

PublicApiHandler _guard(PublicApiHandler handler) => (request) async {
  try {
    if (request.uri.query.isNotEmpty) {
      throw const FormatException(
        'TestRun endpoints do not accept query parameters',
      );
    }
    return await handler(request);
  } on TestRunNotFoundException {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.testRunNotFound,
      'test-run-not-found',
      'The TestRun does not exist.',
    );
  } on ImageNotFound {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.imageNotFound,
      'image-not-found',
      'A referenced image does not exist.',
    );
  } on IdempotencyConflictException {
    throw _problem(
      HttpStatus.conflict,
      ErrorCode.idempotencyConflict,
      'idempotency-conflict',
      'The key belongs to another request.',
    );
  } on OperationNotCancellableException {
    throw _problem(
      HttpStatus.conflict,
      ErrorCode.operationNotCancellable,
      'operation-not-cancellable',
      'The TestRun cannot be cancelled now.',
    );
  } on FormatException catch (error) {
    throw _problem(
      HttpStatus.badRequest,
      ErrorCode.invalidRequest,
      'invalid-request',
      error.message,
    );
  } on ArgumentError {
    throw _problem(
      HttpStatus.badRequest,
      ErrorCode.invalidRequest,
      'invalid-request',
      'Invalid TestRun request.',
    );
  }
};

void _noBody(PublicApiRequest request) {
  if (request.jsonBody != null || request.bodyBytes.isNotEmpty) {
    throw const FormatException('This TestRun endpoint does not accept a body');
  }
}

PublicApiException _problem(
  int status,
  ErrorCode code,
  String type,
  String detail,
) => PublicApiException(
  PublicApiProblem(
    status: status,
    code: code,
    type: type,
    title: 'TestRun request failed',
    detail: detail,
    retryable: false,
    details: JsonObjectValue.empty,
  ),
);

PublicApiResponse _accepted(OperationAcceptance accepted) {
  final resourceId = accepted.resourceId;
  return PublicApiResponse.json(
    status: HttpStatus.accepted,
    body: accepted.toJson(),
    headers: {'Location': '/v1/operations/${accepted.operationId.value}'},
    logCorrelation: PublicApiLogCorrelation(
      operationId: accepted.operationId,
      testRunId: resourceId is TestRunId ? resourceId : null,
    ),
  );
}

String? _key(PublicApiRequest request) {
  final values = request.headers['idempotency-key'];
  if (values == null) return null;
  if (values.length != 1 ||
      values.single.isEmpty ||
      values.single.length > 255) {
    throw const FormatException(
      'Idempotency-Key must contain one 1-255 character value',
    );
  }
  return values.single;
}
