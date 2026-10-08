import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'public_api_server.dart';
import 'vm_log_application_service.dart';
import 'vm_repository.dart';

final class VmLogApiHandlers {
  const VmLogApiHandlers({required this.logs});
  final VmLogApplicationService logs;

  void register(PublicApiRouter router) =>
      router.add('GET', '/v1/vms/{vm_id}/logs', _list);

  Future<PublicApiResponse> _list(PublicApiRequest request) async {
    final VmId id;
    final LogKind? kind;
    try {
      if (request.jsonBody != null || request.bodyBytes.isNotEmpty) {
        throw const FormatException('VM log listing does not accept a body');
      }
      for (final entry in request.uri.queryParametersAll.entries) {
        if (entry.key != 'kind' || entry.value.length != 1) {
          throw const FormatException('unknown or repeated VM log query');
        }
      }
      id = VmId(request.pathParameters['vm_id']!);
      final rawKind = request.uri.queryParameters['kind'];
      kind = rawKind == null ? null : LogKind.parse(rawKind);
    } on FormatException {
      throw _problem(
        HttpStatus.badRequest,
        ErrorCode.invalidRequest,
        'invalid-request',
        'Invalid VM log request.',
      );
    }
    // Stored metadata/filesystem failures are server failures, not invalid
    // client input. PublicApiServer redacts their details into INTERNAL_ERROR.
    try {
      final items = await logs.listForVm(id, kind: kind);
      return PublicApiResponse.json(
        status: HttpStatus.ok,
        body: {'items': items.map((item) => item.toJson()).toList()},
      );
    } on VmNotFoundException {
      throw _problem(
        HttpStatus.notFound,
        ErrorCode.vmNotFound,
        'vm-not-found',
        'The VM does not exist.',
      );
    }
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
    title: 'VM log request failed',
    detail: detail,
    retryable: false,
    details: JsonObjectValue.empty,
  ),
);
