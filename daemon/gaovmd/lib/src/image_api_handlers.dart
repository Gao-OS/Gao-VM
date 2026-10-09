import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'image_application_service.dart';
import 'image_repository.dart';
import 'operation_application_service.dart';
import 'public_api_server.dart';
import 'vm_repository.dart' show LabelSelector;

final class ImageApiHandlers {
  const ImageApiHandlers({required this.images});
  final ImageApplicationService images;

  void register(PublicApiRouter router) {
    router
      ..add('GET', '/v1/images', _guard(_list))
      ..add('POST', '/v1/images/import', _guard(_import))
      ..add('DELETE', '/v1/images/{image_id}', _guard(_delete));
  }

  Future<PublicApiResponse> _list(PublicApiRequest request) async {
    for (final entry in request.uri.queryParametersAll.entries) {
      if (!const {'cursor', 'limit', 'label_selector'}.contains(entry.key) ||
          entry.value.length != 1) {
        throw const FormatException(
          'unknown or repeated image query parameter',
        );
      }
    }
    final query = request.uri.queryParameters;
    final limit = query['limit'] == null ? 50 : int.tryParse(query['limit']!);
    if (limit == null) throw const FormatException('limit must be an integer');
    final page = await images.list(
      ImageListQuery(
        cursor: query['cursor'],
        limit: limit,
        selector: query['label_selector'] == null
            ? null
            : LabelSelector.parse(query['label_selector']!),
      ),
    );
    return PublicApiResponse.json(
      status: HttpStatus.ok,
      body: {
        'items': page.items.map((image) => image.toJson()).toList(),
        'next_cursor': page.nextCursor,
      },
    );
  }

  Future<PublicApiResponse> _import(PublicApiRequest request) async {
    if (request.uri.query.isNotEmpty)
      throw const FormatException(
        'image import does not accept query parameters',
      );
    final body = request.jsonBody?.toJson();
    if (body == null)
      throw const FormatException('image import body is required');
    return _accepted(
      await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: request.requestId,
          idempotencyKey: _key(request),
          requestBody: request.bodyBytes,
        ),
      ),
    );
  }

  Future<PublicApiResponse> _delete(PublicApiRequest request) async {
    if (request.uri.query.isNotEmpty)
      throw const FormatException(
        'image deletion does not accept query parameters',
      );
    if (request.jsonBody != null)
      throw const FormatException('image deletion does not accept a body');
    final id = ImageId(request.pathParameters['image_id']!);
    return _accepted(
      await images.deleteImage(
        ImageDeleteCommand(
          imageId: id,
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
    return await handler(request);
  } on IdempotencyConflictException {
    throw _problem(
      HttpStatus.conflict,
      ErrorCode.idempotencyConflict,
      'idempotency-conflict',
      'The key belongs to another request.',
    );
  } on ImageNotFound {
    throw _problem(
      HttpStatus.notFound,
      ErrorCode.imageNotFound,
      'image-not-found',
      'The image does not exist.',
    );
  } on ImageInUse {
    throw _problem(
      HttpStatus.conflict,
      ErrorCode.imageInUse,
      'image-in-use',
      'The image is referenced by a VM or unfinished TestRun.',
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
      'Invalid image request.',
    );
  }
};

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
    title: 'Image request failed',
    detail: detail,
    retryable: false,
    details: JsonObjectValue.empty,
  ),
);

PublicApiResponse _accepted(OperationAcceptance accepted) =>
    PublicApiResponse.json(
      status: HttpStatus.accepted,
      body: accepted.toJson(),
      headers: {'Location': '/v1/operations/${accepted.operationId.value}'},
      logCorrelation: PublicApiLogCorrelation(
        operationId: accepted.operationId,
      ),
    );

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
