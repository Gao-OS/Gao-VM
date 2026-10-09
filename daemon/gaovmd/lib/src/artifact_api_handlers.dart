import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_application_service.dart';
import 'artifact_repository.dart';
import 'public_api_server.dart';
import 'test_run_repository.dart';
import 'vm_repository.dart';

final class ArtifactApiHandlers {
  const ArtifactApiHandlers({required this.artifacts});
  final ArtifactApplicationService artifacts;

  void register(PublicApiRouter router) {
    router
      ..add('GET', '/v1/artifacts/{artifact_id}', _guard(_download))
      ..add('GET', '/v1/vms/{vm_id}/artifacts', _guard(_listVm))
      ..add(
        'GET',
        '/v1/test-runs/{test_run_id}/artifacts',
        _guard(_listTestRun),
      );
  }

  Future<PublicApiResponse> _listVm(PublicApiRequest request) async {
    final query = _query(request);
    return _page(
      await artifacts.listForVm(
        VmId(request.pathParameters['vm_id']!),
        cursor: query.cursor,
        limit: query.limit,
      ),
    );
  }

  Future<PublicApiResponse> _listTestRun(PublicApiRequest request) async {
    final query = _query(request);
    return _page(
      await artifacts.listForTestRun(
        TestRunId(request.pathParameters['test_run_id']!),
        cursor: query.cursor,
        limit: query.limit,
      ),
    );
  }

  Future<PublicApiResponse> _download(PublicApiRequest request) async {
    if (request.uri.query.isNotEmpty)
      throw const FormatException(
        'artifact download does not accept query parameters',
      );
    final id = ArtifactId(request.pathParameters['artifact_id']!);
    ArtifactDownload download;
    try {
      download = await artifacts.download(id);
    } on FormatException {
      throw ArtifactContentUnavailable(id);
    } on ArgumentError {
      throw ArtifactContentUnavailable(id);
    } on TypeError {
      throw ArtifactContentUnavailable(id);
    }
    final hex = download.artifact.digest.substring(7);
    final digest = List<int>.generate(
      32,
      (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
    );
    return PublicApiResponse.stream(
      body: download.bytes,
      contentType: ContentType('application', 'octet-stream'),
      headers: {
        'Digest': 'sha-256=${base64.encode(digest)}',
        'Content-Length': '${download.artifact.sizeBytes}',
      },
      logCorrelation: PublicApiLogCorrelation(
        vmId: download.artifact.vmId,
        operationId: download.artifact.operationId,
        testRunId: download.artifact.testRunId,
      ),
    );
  }
}

({String? cursor, int limit}) _query(PublicApiRequest request) {
  for (final entry in request.uri.queryParametersAll.entries) {
    if (!const {'cursor', 'limit'}.contains(entry.key) ||
        entry.value.length != 1) {
      throw const FormatException(
        'unknown or repeated artifact query parameter',
      );
    }
  }
  final query = request.uri.queryParameters;
  final limit = query['limit'] == null ? 50 : int.tryParse(query['limit']!);
  if (limit == null) throw const FormatException('limit must be an integer');
  return (cursor: query['cursor'], limit: limit);
}

PublicApiResponse _page(ArtifactPage page) => PublicApiResponse.json(
  status: HttpStatus.ok,
  body: {
    'items': page.items.map((artifact) => artifact.toJson()).toList(),
    'next_cursor': page.nextCursor,
  },
);

PublicApiHandler _guard(PublicApiHandler handler) => (request) async {
  try {
    if (request.jsonBody != null || request.bodyBytes.isNotEmpty) {
      throw const FormatException('artifact endpoints do not accept a body');
    }
    return await handler(request);
  } on VmNotFoundException {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.vmNotFound,
      'vm-not-found',
      'The VM does not exist.',
    );
  } on TestRunNotFoundException {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.testRunNotFound,
      'test-run-not-found',
      'The TestRun does not exist.',
    );
  } on ArtifactNotFoundException {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.artifactNotFound,
      'artifact-not-found',
      'The artifact does not exist.',
    );
  } on ArtifactContentUnavailable {
    throw _unavailable();
  } on FileSystemException {
    throw _unavailable();
  } on FormatException {
    throw _problem(
      HttpStatus.badRequest,
      ErrorCode.invalidRequest,
      'invalid-request',
      'Invalid artifact request.',
    );
  } on ArgumentError {
    throw _problem(
      HttpStatus.badRequest,
      ErrorCode.invalidRequest,
      'invalid-request',
      'Invalid artifact request.',
    );
  }
};

PublicApiException _unavailable() => _problem(
  HttpStatus.internalServerError,
  ErrorCode.internalError,
  'artifact-content-unavailable',
  'The artifact payload is unavailable or failed integrity checks.',
);

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
    title: 'Artifact request failed',
    detail: detail,
    retryable: false,
    details: JsonObjectValue.empty,
  ),
);
