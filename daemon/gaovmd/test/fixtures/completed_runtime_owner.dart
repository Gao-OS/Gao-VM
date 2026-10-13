import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';

/// Historical running-VM baseline for guest-only fixtures. This is an existing
/// completed operation, not a newly accepted lifecycle action/event publication.
Future<OperationId> seedCompletedRuntimeOwner(
  GaoVmDatabase database,
  VmId vmId,
) async {
  final id = OperationId.generate();
  final time = DateTime.now().toUtc().toIso8601String();
  await database.transaction((db) {
    db.execute(
      '''INSERT INTO operations (
      id, type, resource_type, resource_id, state, request_id, cancellable,
      progress_json, request_json, created_at, started_at, completed_at
    ) VALUES (?, 'vm.start', 'virtual_machine', ?, 'succeeded', ?, 0, ?, '{}', ?, ?, ?)''',
      [
        id.value,
        vmId.value,
        RequestId.generate().value,
        jsonEncode(OperationProgress(percent: 100).toJson()),
        time,
        time,
        time,
      ],
    );
  });
  return id;
}
