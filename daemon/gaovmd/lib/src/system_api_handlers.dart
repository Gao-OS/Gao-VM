import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'public_api_server.dart';
import 'system_doctor_service.dart';
import 'vm_repository.dart';

final class SystemApiHandlers {
  const SystemApiHandlers({
    required this.doctor,
    this.guestDevelopmentAcceptance = false,
  });
  final SystemDoctorService doctor;
  final bool guestDevelopmentAcceptance;

  void register(PublicApiRouter router) {
    router.add('GET', '/v1/system/capabilities', (request) async {
      _requireEmptyRequest(request, 'capabilities');
      return PublicApiResponse.json(
        status: HttpStatus.ok,
        body: PublicCapabilities(
          backends: const ['vz'],
          // Development opt-in is support, not guest readiness or native acceptance.
          // Keep private negotiated capability names out of the public response.
          guest: guestDevelopmentAcceptance
              ? const ['health', 'system.info', 'exec', 'artifact.collect']
              : const [],
          maxDefinedVms: maxDefinedVms,
          maxRunningVms: doctor.limits.maxRunningVms,
          maxConcurrentBoots: doctor.limits.maxConcurrentBoots,
        ).toJson(),
      );
    });
    router.add('GET', '/v1/system/doctor', (request) async {
      _requireEmptyRequest(request, 'doctor');
      return PublicApiResponse.json(
        status: HttpStatus.ok,
        body: (await doctor.check()).toJson(),
      );
    });
  }
}

void _requireEmptyRequest(PublicApiRequest request, String name) {
  if (request.uri.query.isEmpty &&
      request.bodyBytes.isEmpty &&
      request.jsonBody == null)
    return;
  throw PublicApiException(
    PublicApiProblem(
      status: HttpStatus.badRequest,
      code: ErrorCode.invalidRequest,
      type: 'invalid-request',
      title: 'Invalid $name request',
      detail: '$name does not accept a body or query parameters.',
      retryable: false,
      details: JsonObjectValue.empty,
    ),
  );
}
