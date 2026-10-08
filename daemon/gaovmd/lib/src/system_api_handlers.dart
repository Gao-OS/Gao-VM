import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'public_api_server.dart';
import 'system_doctor_service.dart';

final class SystemApiHandlers {
  const SystemApiHandlers({required this.doctor});
  final SystemDoctorService doctor;

  void register(PublicApiRouter router) {
    router.add('GET', '/v1/system/doctor', (request) async {
      if (request.uri.query.isNotEmpty ||
          request.bodyBytes.isNotEmpty ||
          request.jsonBody != null) {
        throw PublicApiException(
          PublicApiProblem(
            status: HttpStatus.badRequest,
            code: ErrorCode.invalidRequest,
            type: 'invalid-request',
            title: 'Invalid doctor request',
            detail: 'Doctor does not accept a body or query parameters.',
            retryable: false,
            details: JsonObjectValue.empty,
          ),
        );
      }
      return PublicApiResponse.json(
        status: HttpStatus.ok,
        body: (await doctor.check()).toJson(),
      );
    });
  }
}
