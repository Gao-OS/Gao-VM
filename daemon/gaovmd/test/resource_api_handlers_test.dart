import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/public_api_server.dart';
import 'package:gaovmd/src/resource_api_handlers.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_application_service.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  group('adversarial API boundaries', () {
    late Directory directory;
    late GaoVmDatabase database;
    late PublicApiRouter router;
    late _VmMutations mutations;
    late _VmWaiter waiter;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('resource-boundary-');
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final repository = SqliteVmRepository(database, newVmId: () => _vmId);
      await repository.create(name: 'vm', spec: _spec);
      mutations = _VmMutations();
      waiter = _VmWaiter();
      router = PublicApiRouter();
      ResourceApiHandlers(
        vms: VmApplicationService(
          repository: repository,
          mutations: mutations,
          waiter: waiter,
        ),
        operations: OperationApplicationService(
          repository: SqliteOperationRepository(database),
          mutations: _OperationMutations(),
          waiter: _OperationWaiter(),
        ),
      ).register(router);
    });
    tearDown(() async {
      database.close();
      await directory.delete(recursive: true);
    });
    Future<PublicApiResponse> request(
      String method,
      String path,
      Map<String, Object?> body,
    ) => router.handler(method, path)!(
      PublicApiRequest(
        requestId: _requestId,
        method: method,
        uri: Uri.parse(path),
        headers: const {
          'if-match': ['"1"'],
          'idempotency-key': ['same-request'],
        },
        pathParameters: {'vm_id': _vmId.value},
        jsonBody: JsonObjectValue.fromJson(body),
        bodyBytes: utf8.encode(jsonEncode(body)),
      ),
    );
    for (final metadata in [
      {'name': 'x' * 129},
      {'name': 'vm', 'labels': null},
      {
        'name': 'vm',
        'labels': {' bad': 'x'},
      },
      {
        'name': 'vm',
        'labels': {'valid': 'x' * 254},
      },
      {
        'name': 'vm',
        'labels': {for (var i = 0; i < 65; i++) 'k$i': 'v'},
      },
    ]) {
      test(
        'rejects invalid metadata before acceptance ${metadata.toString().substring(0, 20)}',
        () async {
          await expectLater(
            request('POST', '/v1/vms', {
              'api_version': vmApiVersion,
              'kind': vmKind,
              'metadata': metadata,
              'spec': _spec.toJson(),
            }),
            throwsA(
              isA<PublicApiException>().having(
                (e) => e.problem.status,
                'status',
                400,
              ),
            ),
          );
          expect(mutations.createCommand, isNull);
        },
      );
    }
    test('rejects null and unknown patch fields before acceptance', () async {
      for (final body in [
        {
          'metadata': null,
          'spec': {'cpu': 4},
        },
        {
          'metadata': {'labels': null},
        },
        {
          'spec': {'cpu': 4, 'typo': true},
        },
        {
          'spec': {'cpu': null, 'autostart': true},
        },
      ]) {
        await expectLater(
          request('PATCH', '/v1/vms/${_vmId.value}', body),
          throwsA(
            isA<PublicApiException>().having(
              (e) => e.problem.status,
              'status',
              400,
            ),
          ),
        );
      }
      expect(mutations.patchCommand, isNull);
    });
    test(
      'rejects malformed deadline dates and accepts explicit offsets',
      () async {
        final path = '/v1/vms/${_vmId.value}/actions/start';
        for (final date in [
          '2026-09-07',
          '2026-09-07T12:00:00',
          '2026-02-30T00:00:00Z',
          '2026-09-07T24:00:00Z',
          '2026-09-07T12:00:00+24:00',
        ]) {
          await expectLater(
            request('POST', path, {'deadline_at': date}),
            throwsA(isA<PublicApiException>()),
          );
        }
        expect(mutations.lifecycleCommand, isNull);
        await request('POST', path, {
          'deadline_at': '2026-09-07T12:00:00+08:00',
        });
        expect(
          mutations.lifecycleCommand?.deadlineAt,
          DateTime.utc(2026, 9, 7, 4),
        );
      },
    );
    test('returns structured OCC409 and wait504', () async {
      mutations.error = RevisionConflictException(
        id: _vmId,
        expectedRevision: 1,
        actualRevision: 2,
      );
      await expectLater(
        request('PATCH', '/v1/vms/${_vmId.value}', {
          'spec': {'cpu': 4},
        }),
        throwsA(
          isA<PublicApiException>().having(
            (e) => e.problem.status,
            'status',
            409,
          ),
        ),
      );
      waiter.error = TimeoutException('condition');
      await expectLater(
        request('POST', '/v1/vms/${_vmId.value}/wait', {
          'condition': 'runtime_running',
          'timeout_seconds': 1,
        }),
        throwsA(
          isA<PublicApiException>().having(
            (e) => e.problem.status,
            'status',
            504,
          ),
        ),
      );
    });
    test('accepted deletion conflicts return stable HTTP409 problem', () async {
      mutations.error = VmAcceptanceConflict(_vmId);
      await expectLater(
        request('POST', '/v1/vms/${_vmId.value}/actions/start', {}),
        throwsA(
          isA<PublicApiException>()
              .having(
                (error) => error.problem.status,
                'status',
                HttpStatus.conflict,
              )
              .having(
                (error) => error.problem.code,
                'code',
                ErrorCode.vmOperationConflict,
              )
              .having((error) => error.problem.retryable, 'retryable', isFalse)
              .having(
                (error) => error.problem.details.toJson()['vm_id'],
                'vm_id',
                _vmId.value,
              ),
        ),
      );
    });
    test(
      'replays the acceptance snapshot after target failure or cancellation',
      () async {
        final snapshot = OperationAcceptance.fromOperation(_operation).toJson();
        for (final terminal in [
          OperationState.failed,
          OperationState.cancelled,
        ]) {
          final later = Operation(
            id: _operation.id,
            type: _operation.type,
            resourceType: _operation.resourceType,
            resourceId: _operation.resourceId,
            state: terminal,
            requestId: _requestId,
            cancellable: false,
            request: JsonObjectValue.empty,
            createdAt: _now,
            startedAt: _now,
            completedAt: _now,
            error: terminal == OperationState.failed
                ? OperationError(
                    code: ErrorCode.internalError,
                    message: 'failed',
                    retryable: false,
                    details: JsonObjectValue.empty,
                  )
                : null,
          );
          expect(
            () => OperationAcceptance.fromOperation(later),
            throwsArgumentError,
          );
          mutations.acceptance = OperationAcceptance.fromJson(snapshot);
          final response = await request(
            'POST',
            '/v1/vms/${_vmId.value}/actions/start',
            {},
          );
          expect(response.status, 202);
          expect(response.body, snapshot);
        }
      },
    );
  });
  test(
    'lifecycle handler returns an immediate durable operation envelope',
    () async {
      final directory = await Directory.systemTemp.createTemp('resource-api-');
      final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      final vmRepository = SqliteVmRepository(
        database,
        newVmId: () => _vmId,
        now: () => _now,
      );
      await vmRepository.create(name: 'vm', spec: _spec);
      final mutations = _VmMutations();
      final router = PublicApiRouter();
      ResourceApiHandlers(
        vms: VmApplicationService(
          repository: vmRepository,
          mutations: mutations,
          waiter: _VmWaiter(),
        ),
        operations: OperationApplicationService(
          repository: SqliteOperationRepository(database),
          mutations: _OperationMutations(),
          waiter: _OperationWaiter(),
        ),
      ).register(router);
      final body = utf8.encode('{"reason":"test"}');
      final handler = router.handler(
        'POST',
        '/v1/vms/${_vmId.value}/actions/start',
      )!;

      final response = await handler(
        PublicApiRequest(
          requestId: _requestId,
          method: 'POST',
          uri: Uri.parse('/v1/vms/${_vmId.value}/actions/start'),
          headers: const {
            'idempotency-key': ['start-once'],
          },
          jsonBody: JsonObjectValue.fromJson(const {'reason': 'test'}),
          pathParameters: {'vm_id': _vmId.value},
          bodyBytes: body,
        ),
      );

      expect(response.status, HttpStatus.accepted);
      expect(response.body, {
        'operation_id': _operationId.value,
        'state': 'running',
        'resource_type': 'virtual_machine',
        'resource_id': _vmId.value,
      });
      expect(
        response.headers['Location'],
        '/v1/operations/${_operationId.value}',
      );
      expect(mutations.lifecycleCommand?.action, VmLifecycleAction.start);
      expect(mutations.lifecycleCommand?.requestBody, body);
      expect(mutations.lifecycleCommand?.idempotencyKey, 'start-once');

      database.close();
      await directory.delete(recursive: true);
    },
  );

  test(
    'create and patch preserve exact request bytes and OCC metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resource-write-',
      );
      final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      final mutations = _VmMutations();
      final router = PublicApiRouter();
      ResourceApiHandlers(
        vms: VmApplicationService(
          repository: SqliteVmRepository(database),
          mutations: mutations,
          waiter: _VmWaiter(),
        ),
        operations: OperationApplicationService(
          repository: SqliteOperationRepository(database),
          mutations: _OperationMutations(),
          waiter: _OperationWaiter(),
        ),
      ).register(router);
      final createJson = {
        'api_version': vmApiVersion,
        'kind': vmKind,
        'metadata': {
          'name': 'created',
          'labels': {'suite': 'nightly'},
        },
        'spec': _spec.toJson(),
      };
      final createBytes = utf8.encode(jsonEncode(createJson));

      await router.handler('POST', '/v1/vms')!(
        PublicApiRequest(
          requestId: _requestId,
          method: 'POST',
          uri: Uri.parse('/v1/vms'),
          headers: const {},
          jsonBody: JsonObjectValue.fromJson(createJson),
          bodyBytes: createBytes,
        ),
      );
      final patchBytes = utf8.encode('{"spec":{"cpu":4}}');
      await router.handler('PATCH', '/v1/vms/${_vmId.value}')!(
        PublicApiRequest(
          requestId: _requestId,
          method: 'PATCH',
          uri: Uri.parse('/v1/vms/${_vmId.value}'),
          headers: const {
            'if-match': ['"7"'],
          },
          jsonBody: JsonObjectValue.fromJson(const {
            'spec': {'cpu': 4},
          }),
          pathParameters: {'vm_id': _vmId.value},
          bodyBytes: patchBytes,
        ),
      );

      expect(mutations.createCommand?.name, 'created');
      expect(mutations.createCommand?.labels, {'suite': 'nightly'});
      expect(mutations.createCommand?.requestBody, createBytes);
      expect(mutations.patchCommand?.expectedRevision, 7);
      expect(mutations.patchCommand?.spec?.cpu, 4);
      expect(mutations.patchCommand?.requestBody, patchBytes);
      for (final route in [
        ('GET', '/v1/vms'),
        ('POST', '/v1/vms'),
        ('GET', '/v1/vms/${_vmId.value}'),
        ('PATCH', '/v1/vms/${_vmId.value}'),
        ('DELETE', '/v1/vms/${_vmId.value}'),
        ('POST', '/v1/vms/${_vmId.value}/actions/start'),
        ('POST', '/v1/vms/${_vmId.value}/actions/stop'),
        ('POST', '/v1/vms/${_vmId.value}/actions/restart'),
        ('POST', '/v1/vms/${_vmId.value}/actions/kill'),
        ('POST', '/v1/vms/${_vmId.value}/wait'),
        ('GET', '/v1/operations'),
        ('GET', '/v1/operations/${_operationId.value}'),
        ('POST', '/v1/operations/${_operationId.value}/cancel'),
        ('POST', '/v1/operations/${_operationId.value}/wait'),
      ]) {
        expect(router.handler(route.$1, route.$2), isNotNull, reason: route.$2);
      }

      database.close();
      await directory.delete(recursive: true);
    },
  );
}

final class _VmMutations implements VmMutationAcceptor {
  Object? error;
  OperationAcceptance? acceptance;
  VmCreateCommand? createCommand;
  VmPatchCommand? patchCommand;
  VmLifecycleCommand? lifecycleCommand;

  @override
  Future<OperationAcceptance> create(VmCreateCommand command) async {
    if (error case final error?) throw error;
    createCommand = command;
    return acceptance ?? OperationAcceptance.fromOperation(_operation);
  }

  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand command) async {
    if (error case final error?) throw error;
    lifecycleCommand = command;
    return acceptance ?? OperationAcceptance.fromOperation(_operation);
  }

  @override
  Future<OperationAcceptance> patch(VmPatchCommand command) async {
    if (error case final error?) throw error;
    patchCommand = command;
    return acceptance ?? OperationAcceptance.fromOperation(_operation);
  }
}

final class _OperationMutations implements OperationMutationAcceptor {
  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async =>
      OperationAcceptance.fromOperation(_operation);
}

final class _VmWaiter implements VmConditionWaiter {
  Object? error;
  @override
  Future<DateTime> wait(VmWaitCommand command) async {
    if (error case final error?) throw error;
    return _now;
  }
}

final class _OperationWaiter implements OperationWaiter {
  @override
  Future<Operation> wait(OperationWaitCommand command) async => _operation;
}

final _operation = Operation(
  id: _operationId,
  type: 'vm.start',
  resourceType: ResourceType.virtualMachine,
  resourceId: _vmId,
  state: OperationState.running,
  requestId: _requestId,
  cancellable: true,
  request: JsonObjectValue.empty,
  createdAt: _now,
  startedAt: _now,
);

final _now = DateTime.utc(2026, 9, 7);
final _vmId = VmId('vm_01J00000000000000000000000');
final _operationId = OperationId('op_01J00000000000000000000000');
final _requestId = RequestId('req_01J00000000000000000000000');
final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
