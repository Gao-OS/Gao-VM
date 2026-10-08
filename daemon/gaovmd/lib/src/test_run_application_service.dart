import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'image_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';

final class TestRunCreateCommand {
  TestRunCreateCommand({
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
    required this.spec,
  }) : requestBody = List<int>.unmodifiable(requestBody) {
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255)) {
      throw const FormatException('invalid Idempotency-Key');
    }
  }

  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final TestRunSpec spec;
}

final class TestRunCancelCommand {
  TestRunCancelCommand({
    required this.testRunId,
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
  }) : requestBody = List<int>.unmodifiable(requestBody) {
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255)) {
      throw const FormatException('invalid Idempotency-Key');
    }
  }

  final TestRunId testRunId;
  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
}

/// Database-only acceptance. Provisioning, guest execution and cleanup are
/// recoverable worker responsibilities, never work performed by an API handler.
final class TestRunApplicationService implements OperationMutationAcceptor {
  TestRunApplicationService({
    required GaoVmDatabase database,
    Duration idempotencyRetention = const Duration(days: 1),
    DateTime Function()? now,
  }) : _database = database,
       _runs = SqliteTestRunRepository(database, now: now),
       _operations = SqliteOperationRepository(database, now: now),
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
         now: now,
       );

  final GaoVmDatabase _database;
  final SqliteTestRunRepository _runs;
  final SqliteOperationRepository _operations;
  final SqliteIdempotencyRepository _idempotency;

  Future<OperationAcceptance> create(TestRunCreateCommand command) => _accept(
    scope: 'POST /v1/test-runs',
    key: command.idempotencyKey,
    requestBody: command.requestBody,
    action: () async {
      final source = command.spec.source;
      if (source is! ImageTestRunSource) {
        throw const FormatException(
          'template TestRun sources are not supported by the MVP',
        );
      }
      final overrides = command.spec.vmOverrides;
      final boot = overrides?.boot;
      final images = {
        source.imageId,
        if (boot is LinuxKernelBoot) boot.kernelImageId,
        if (boot is LinuxKernelBoot && boot.initrdImageId != null)
          boot.initrdImageId!,
        for (final disk in overrides?.disks ?? const <VmDisk>[])
          if (disk.source case ManagedImageDiskSource(:final imageId)) imageId,
      };
      for (final id in images) {
        if (await ImageRepository(_database).get(id) == null) {
          throw ImageNotFound(id);
        }
      }
      final run = await _runs.create(
        spec: command.spec,
        requestId: command.requestId,
        idempotencyKey: command.idempotencyKey,
      );
      return OperationAcceptance.fromOperation(
        (await _operations.get(run.operationId))!,
      );
    },
  );

  Future<TestRun> get(TestRunId id) async =>
      await _runs.get(id) ?? (throw TestRunNotFoundException(id));

  Future<OperationAcceptance> cancelRun(TestRunCancelCommand command) =>
      _accept(
        scope: 'POST /v1/test-runs/${command.testRunId.value}/cancel',
        key: command.idempotencyKey,
        requestBody: command.requestBody,
        action: () async {
          final run = await get(command.testRunId);
          return _recordCancellation(
            run: run,
            target: (await _operations.get(run.operationId))!,
            requestId: command.requestId,
            key: command.idempotencyKey,
            operationEndpoint: false,
          );
        },
      );

  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) => _accept(
    scope: 'POST /v1/operations/${command.operationId.value}/cancel',
    key: command.idempotencyKey,
    requestBody: command.requestBody,
    action: () async {
      final target = await _operations.get(command.operationId);
      if (target == null) throw OperationNotFoundException(command.operationId);
      if (target.type != 'test.run' ||
          target.resourceType != ResourceType.testRun) {
        throw OperationNotCancellableException(target.id);
      }
      return _recordCancellation(
        run: await get(target.resourceId as TestRunId),
        target: target,
        requestId: command.requestId,
        key: command.idempotencyKey,
        operationEndpoint: true,
      );
    },
  );

  Future<OperationAcceptance> _recordCancellation({
    required TestRun run,
    required Operation target,
    required RequestId requestId,
    required String? key,
    required bool operationEndpoint,
  }) async {
    if (run.operationId != target.id ||
        target.type != 'test.run' ||
        target.resourceType != ResourceType.testRun ||
        target.resourceId != run.id ||
        !target.cancellable ||
        !const {
          OperationState.pending,
          OperationState.running,
        }.contains(target.state) ||
        run.state == TestRunState.cleaningUp ||
        const {
          TestRunState.succeeded,
          TestRunState.failed,
          TestRunState.cancelled,
        }.contains(run.state)) {
      throw OperationNotCancellableException(target.id);
    }
    await _runs.requestCancel(run.id);
    final action = await _operations.create(
      type: operationEndpoint ? 'operation.cancel' : 'test.cancel',
      resourceType: operationEndpoint
          ? ResourceType.operation
          : ResourceType.testRun,
      resourceId: operationEndpoint ? target.id : run.id,
      requestId: requestId,
      idempotencyKey: key,
      cancellable: false,
      request: JsonObjectValue.fromJson({
        'test_run_id': run.id.value,
        'target_operation_id': target.id.value,
      }),
    );
    return OperationAcceptance.fromOperation(action);
  }

  Future<OperationAcceptance> _accept({
    required String scope,
    required String? key,
    required List<int> requestBody,
    required Future<OperationAcceptance> Function() action,
  }) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('TestRun acceptance must own its commit boundary');
    }
    return _database.transaction((_) async {
      Future<IdempotencyResponse> accept() async => IdempotencyResponse(
        JsonObjectValue.fromJson((await action()).toJson()),
      );
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: scope,
              key: key,
              requestBody: requestBody,
              action: accept,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }
}
