import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/guest_exec_application_service.dart';
import 'package:gaovmd/src/guest_exec_request.dart';
import 'package:gaovmd/src/guest_exec_repository.dart';
import 'package:test/test.dart';

import 'fixtures/completed_runtime_owner.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late VmControllerState running;
  late VmController controller;
  late GuestExecApplicationService service;
  final runtimeOwnerIds = <OperationId>{};
  Future<OperationId> seedOwner(VmId vmId) async {
    final id = await seedCompletedRuntimeOwner(database, vmId);
    runtimeOwnerIds.add(id);
    return id;
  }

  Future<List<Operation>> acceptedOperations() async {
    final records = await SqliteOperationRepository(database).list();
    for (final owner in records.where(
      (record) => runtimeOwnerIds.contains(record.id),
    )) {
      expect(owner.state, OperationState.succeeded);
    }
    return records
        .where((record) => !runtimeOwnerIds.contains(record.id))
        .toList();
  }

  setUp(() async {
    runtimeOwnerIds.clear();
    directory = await Directory.systemTemp.createTemp('guest-exec-accept-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    final vm = await SqliteVmRepository(
      database,
    ).create(name: 'guest', spec: _spec);
    running =
        VmControllerState.initial(
          vmId: vm.metadata.id,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ).copyWith(
          desiredState: DesiredState.running,
          phase: VmPhase.running,
          observedGeneration: 1,
          driverGeneration: 3,
          activeDriverGeneration: 3,
          activeSpecGeneration: 1,
          driverOperationId: await seedOwner(vm.metadata.id),
        );
    final persistence = SqliteVmStateEffectAdapter(database);
    await persistence.persistVm(running);
    await persistence.persistRuntime(running);
    await persistence.persistGuestReadiness(running, true);
    controller = VmController(
      initialState: running,
      effectRunner: _HardwareBoundary(),
    );
    service = GuestExecApplicationService(
      database: database,
      resolveController: (vmId) async =>
          vmId == running.vmId ? controller : null,
    );
  });
  tearDown(() async {
    await controller.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });
  GuestExecCommand command({String? key = 'exec-once', List<int>? body}) =>
      GuestExecCommand(
        vmId: running.vmId,
        requestId: RequestId.generate(),
        idempotencyKey: key,
        requestBody: body ?? utf8.encode(jsonEncode(_request)),
        request: GuestExecRequest.fromJson(_request),
      );

  test(
    'guest exec acceptance durably commits a pending operation and generation-bound intent',
    () async {
      final accepted = await service.execute(command());
      expect(accepted.resourceType, ResourceType.virtualMachine);
      expect(accepted.resourceId, running.vmId);
      expect(accepted.state, OperationState.pending);
      final operation = (await SqliteOperationRepository(
        database,
      ).get(accepted.operationId))!;
      expect(operation.type, 'guest.exec');
      expect(operation.request.toJson(), _request);
      expect(operation.cancellable, isTrue);
      final job = (await SqliteGuestExecRepository(
        database,
      ).get(operation.id))!;
      expect(job.vmId, running.vmId);
      expect(job.driverGeneration, 3);
      expect(job.specGeneration, 1);
      expect(job.appliedIntentRevision, running.appliedIntentRevision);
      expect(job.startedAt, isNull);
      expect(job.completedAt, isNull);
      expect(controller.state.phase, VmPhase.running);
      final events = SqliteEventRepository(database);
      expect(
        (await events.list(
          operationId: operation.id,
        )).map((event) => event.type),
        ['operation.created'],
      );
      expect(await events.readUnpublishedOutbox(), hasLength(2));
    },
  );

  test(
    'retries replay the original acceptance after restart, completion and VM stop',
    () async {
      final original = command();
      final accepted = await service.execute(original);
      await SqliteOperationRepository(database).start(accepted.operationId);
      await SqliteOperationRepository(database).succeed(accepted.operationId);
      await database.transaction((connection) {
        connection.execute(
          "UPDATE vm_runtime SET desired_state = 'stopped', phase = 'stopped', guest_agent = 'unavailable' WHERE vm_id = ?",
          [running.vmId.value],
        );
      });
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      service = GuestExecApplicationService(
        database: database,
        resolveController: (_) =>
            throw StateError('replay must not resolve a controller'),
      );
      final replay = await service.execute(original);
      expect(replay.toJson(), accepted.toJson());
      expect(replay.state, OperationState.pending);
      expect(await acceptedOperations(), hasLength(1));
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.driverGeneration,
        3,
      );
    },
  );

  test(
    'idempotency compares exact bytes before busy or guest availability checks',
    () async {
      await service.execute(command());
      await database.transaction((connection) {
        connection.execute(
          "UPDATE vm_runtime SET guest_agent = 'unavailable' WHERE vm_id = ?",
          [running.vmId.value],
        );
      });
      await expectLater(
        service.execute(command(body: utf8.encode(' ${jsonEncode(_request)}'))),
        throwsA(isA<IdempotencyConflictException>()),
      );
      expect(await acceptedOperations(), hasLength(1));
    },
  );

  test(
    'concurrent retries accept once and a different unfinished exec conflicts',
    () async {
      final accepted = await Future.wait(
        List.generate(5, (_) => service.execute(command())),
      );
      expect(accepted.map((value) => value.operationId).toSet(), hasLength(1));
      expect(await acceptedOperations(), hasLength(1));
      await expectLater(
        service.execute(command(key: 'another-exec')),
        throwsA(
          isA<GuestExecAdmissionException>().having(
            (error) => error.code,
            'code',
            ErrorCode.vmOperationConflict,
          ),
        ),
      );
      expect(
        (await SqliteEventRepository(database).list(
          operationId: accepted.first.operationId,
        )).map((event) => event.type),
        ['operation.created'],
      );
    },
  );

  for (final (change, code) in <(String, ErrorCode)>[
    (
      "UPDATE vm_runtime SET guest_agent = 'unavailable'",
      ErrorCode.guestAgentUnavailable,
    ),
    ("UPDATE vm_runtime SET desired_state = 'stopped'", ErrorCode.vmNotRunning),
    (
      "UPDATE vm_runtime SET driver_generation = 4",
      ErrorCode.vmOperationConflict,
    ),
    (
      "UPDATE vm_runtime SET applied_intent_revision = 1",
      ErrorCode.vmOperationConflict,
    ),
    (
      "UPDATE vms SET deleting_at = '2026-10-11T00:00:00Z'",
      ErrorCode.vmOperationConflict,
    ),
  ]) {
    test(
      'admission rejects $change without accepting an operation or reserving the key',
      () async {
        await database.transaction((connection) => connection.execute(change));
        await expectLater(
          service.execute(command()),
          throwsA(
            isA<GuestExecAdmissionException>().having(
              (error) => error.code,
              'code',
              code,
            ),
          ),
        );
        expect(await acceptedOperations(), isEmpty);
        expect(
          await SqliteIdempotencyRepository(
            database,
            retention: const Duration(days: 1),
          ).lookup(
            scope: 'POST /v1/vms/${running.vmId.value}/guest/exec',
            key: 'exec-once',
            requestBody: command().requestBody,
          ),
          isNull,
        );
      },
    );
  }

  test(
    'work-outbox failure rolls back operation, lifecycle event, job and retry reservation',
    () async {
      await database.transaction((connection) {
        connection.execute(
          "CREATE TRIGGER reject_guest_work BEFORE INSERT ON outbox WHEN NEW.topic = 'guest.exec' BEGIN SELECT RAISE(ABORT, 'fixture work publication failure'); END",
        );
      });
      await expectLater(service.execute(command()), throwsA(isA<Exception>()));
      expect(await acceptedOperations(), isEmpty);
      expect(
        (await SqliteEventRepository(
          database,
        ).list()).map((event) => event.type),
        ['vm.guest_agent_ready'],
      );
      expect(
        await SqliteEventRepository(database).readUnpublishedOutbox(),
        hasLength(1),
      );
      await database.transaction(
        (connection) => connection.execute('DROP TRIGGER reject_guest_work'),
      );
      final accepted = await service.execute(command());
      expect(
        await SqliteGuestExecRepository(database).get(accepted.operationId),
        isNotNull,
      );
    },
  );

  test(
    'acceptance refuses an outer transaction that has not committed',
    () async {
      await database.transaction((_) async {
        await expectLater(service.execute(command()), throwsStateError);
      });
      expect(await acceptedOperations(), isEmpty);
    },
  );

  test(
    'one committed execution attempt cannot be replayed after duplicate dispatch or restart',
    () async {
      final accepted = await service.execute(command());
      final attemptId = RequestId.generate();
      final controlEpochId = RequestId.generate();
      final started = (await service.beginAttempt(
        accepted.operationId,
        attemptId: attemptId,
        controlEpochId: controlEpochId,
        stillCurrent: () => true,
      ))!;
      expect(started.startedAt, isNotNull);
      expect(started.attemptId, attemptId);
      expect(started.controlEpochId, controlEpochId);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: attemptId,
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      service = GuestExecApplicationService(
        database: database,
        resolveController: (_) async => controller,
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.attemptId,
        attemptId,
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(operationId: accepted.operationId)).map((event) => event.type),
        ['operation.created', 'operation.started'],
      );
      expect(controller.state.phase, VmPhase.running);
    },
  );

  test(
    'an abandoned attempt fails once, releases admission and never changes VM lifecycle',
    () async {
      final accepted = await service.execute(command());
      final attemptId = RequestId.generate();
      await service.beginAttempt(
        accepted.operationId,
        attemptId: attemptId,
        controlEpochId: RequestId.generate(),
        stillCurrent: () => true,
      );
      final jobs = SqliteGuestExecRepository(database);
      final failure = OperationError(
        code: ErrorCode.guestExecFailed,
        message:
            'Guest connection closed after execution acceptance; outcome is unknown',
        retryable: false,
        details: JsonObjectValue.fromJson({
          'outcome': 'unknown',
          'driver_generation': 3,
        }),
      );
      expect(
        await jobs.failAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          error: failure,
        ),
        isFalse,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        await jobs.failAttempt(
          accepted.operationId,
          attemptId: attemptId,
          error: failure,
        ),
        isTrue,
      );
      expect(
        await jobs.failAttempt(
          accepted.operationId,
          attemptId: attemptId,
          error: failure,
        ),
        isFalse,
      );
      final failed = (await SqliteOperationRepository(
        database,
      ).get(accepted.operationId))!;
      expect(failed.state, OperationState.failed);
      expect(failed.error, failure);
      expect(
        (await jobs.get(accepted.operationId))!.completedAt,
        failed.completedAt,
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(operationId: accepted.operationId)).map((event) => event.type),
        ['operation.created', 'operation.started', 'operation.completed'],
      );
      expect(
        (await SqliteVmRepository(database).get(running.vmId))!.status.phase,
        VmPhase.running,
      );
      expect(controller.state.phase, VmPhase.running);
      expect((await service.execute(command())).toJson(), accepted.toJson());
      expect(
        (await service.execute(
          command(key: 'explicit-new-command'),
        )).operationId,
        isNot(accepted.operationId),
      );
    },
  );

  test(
    'connection revocation during durable start rolls back the attempt and lifecycle event',
    () async {
      final accepted = await service.execute(command());
      var observations = 0;
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => ++observations < 3,
        ),
        isNull,
      );
      final job = (await SqliteGuestExecRepository(
        database,
      ).get(accepted.operationId))!;
      expect(job.startedAt, isNull);
      expect(job.attemptId, isNull);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(operationId: accepted.operationId)).map((event) => event.type),
        ['operation.created'],
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNotNull,
      );
    },
  );

  test(
    'a start-event failure cannot leave an execution claim committed',
    () async {
      final accepted = await service.execute(command());
      await database.transaction(
        (connection) => connection.execute(
          "CREATE TRIGGER reject_guest_start BEFORE INSERT ON events WHEN NEW.type = 'operation.started' BEGIN SELECT RAISE(ABORT, 'fixture start event failure'); END",
        ),
      );
      await expectLater(
        service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.startedAt,
        isNull,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
      await database.transaction(
        (connection) => connection.execute('DROP TRIGGER reject_guest_start'),
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNotNull,
      );
    },
  );

  test(
    'a new driver generation cannot claim an old pending execution',
    () async {
      final accepted = await service.execute(command());
      await database.transaction(
        (connection) => connection.execute(
          'UPDATE vm_runtime SET driver_generation = 4 WHERE vm_id = ?',
          [running.vmId.value],
        ),
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.driverGeneration,
        3,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
    },
  );
  test(
    'execution claims refuse a caller-owned uncommitted savepoint',
    () async {
      final accepted = await service.execute(command());
      await database.transaction((_) async {
        await expectLater(
          SqliteGuestExecRepository(database).beginAttempt(
            accepted.operationId,
            attemptId: RequestId.generate(),
            controlEpochId: RequestId.generate(),
            executionState: running,
            stillCurrent: () => true,
          ),
          throwsStateError,
        );
      });
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.startedAt,
        isNull,
      );
    },
  );
  test(
    'cancellation records intent and blocks an unstarted exec without claiming cleanup',
    () async {
      final accepted = await service.execute(command());
      final cancellation = OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-once',
        requestBody: utf8.encode('{}'),
        operationId: accepted.operationId,
      );
      final action = await service.cancel(cancellation);
      expect(action.resourceType, ResourceType.operation);
      expect(action.resourceId, accepted.operationId);
      expect(action.state, OperationState.pending);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(action.operationId))!.type,
        'operation.cancel',
      );
      expect((await operations.get(action.operationId))!.cancellable, isFalse);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      final job = (await SqliteGuestExecRepository(
        database,
      ).get(accepted.operationId))!;
      expect(job.cancellationRequested, isTrue);
      expect(job.completedAt, isNull);
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      expect((await service.cancel(cancellation)).toJson(), action.toJson());
      await expectLater(
        service.execute(command(key: 'next-exec')),
        throwsA(isA<GuestExecAdmissionException>()),
      );
      expect(controller.state.phase, VmPhase.running);
    },
  );
  test(
    'cancelling before start completes the target and all cancel actions atomically',
    () async {
      final accepted = await service.execute(command());
      OperationCancelCommand cancellation(String key) => OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: key,
        requestBody: utf8.encode('{}'),
        operationId: accepted.operationId,
      );
      final firstCommand = cancellation('cancel-one');
      final first = await service.cancel(firstCommand);
      final second = await service.cancel(cancellation('cancel-two'));
      final jobs = SqliteGuestExecRepository(database);
      expect(await jobs.cancelBeforeStart(accepted.operationId), isTrue);
      expect(await jobs.cancelBeforeStart(accepted.operationId), isFalse);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.cancelled,
      );
      for (final action in [first, second]) {
        expect(
          (await operations.get(action.operationId))!.state,
          OperationState.succeeded,
        );
      }
      final job = (await jobs.get(accepted.operationId))!;
      expect(job.completedAt, isNotNull);
      expect(job.startedAt, isNull);
      expect(job.attemptId, isNull);
      expect((await service.cancel(firstCommand)).toJson(), first.toJson());
      await expectLater(
        service.cancel(cancellation('cancel-after-terminal')),
        throwsA(isA<OperationNotCancellableException>()),
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      expect(
        (await service.execute(command(key: 'after-cancel'))).operationId,
        isNot(accepted.operationId),
      );
      expect(controller.state.phase, VmPhase.running);
    },
  );
  test(
    'disconnect with an unknown exec outcome fails cancellation instead of claiming success',
    () async {
      final accepted = await service.execute(command());
      final attemptId = RequestId.generate();
      await service.beginAttempt(
        accepted.operationId,
        attemptId: attemptId,
        controlEpochId: RequestId.generate(),
        stillCurrent: () => true,
      );
      final cancellation = OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-running',
        requestBody: utf8.encode('{}'),
        operationId: accepted.operationId,
      );
      final action = await service.cancel(cancellation);
      final jobs = SqliteGuestExecRepository(database);
      expect(await jobs.cancelBeforeStart(accepted.operationId), isFalse);
      final failure = OperationError(
        code: ErrorCode.guestExecFailed,
        message: 'Guest execution outcome is unknown',
        retryable: false,
        details: JsonObjectValue.fromJson({
          'outcome': 'unknown',
          'driver_generation': 3,
        }),
      );
      expect(
        await jobs.failAttempt(
          accepted.operationId,
          attemptId: attemptId,
          error: failure,
        ),
        isTrue,
      );
      final cancelled = (await SqliteOperationRepository(
        database,
      ).get(action.operationId))!;
      expect(cancelled.state, OperationState.failed);
      expect(cancelled.error, failure);
      expect((await service.cancel(cancellation)).toJson(), action.toJson());
      expect(controller.state.phase, VmPhase.running);
    },
  );
  test(
    'different VMs accept independent execution intents with the same key',
    () async {
      final vm = await SqliteVmRepository(
        database,
      ).create(name: 'other-guest', spec: _spec);
      final otherState =
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            desiredState: DesiredState.running,
            phase: VmPhase.running,
            observedGeneration: 1,
            driverGeneration: 3,
            activeDriverGeneration: 3,
            activeSpecGeneration: 1,
            driverOperationId: await seedOwner(vm.metadata.id),
          );
      final persistence = SqliteVmStateEffectAdapter(database);
      await persistence.persistVm(otherState);
      await persistence.persistRuntime(otherState);
      await persistence.persistGuestReadiness(otherState, true);
      final otherController = VmController(
        initialState: otherState,
        effectRunner: _HardwareBoundary(),
      );
      addTearDown(otherController.shutdown);
      final controllers = {
        running.vmId: controller,
        otherState.vmId: otherController,
      };
      service = GuestExecApplicationService(
        database: database,
        resolveController: (id) async => controllers[id],
      );
      final second = GuestExecCommand(
        vmId: otherState.vmId,
        requestId: RequestId.generate(),
        idempotencyKey: 'exec-once',
        requestBody: command().requestBody,
        request: GuestExecRequest.fromJson(_request),
      );
      final accepted = await Future.wait([
        service.execute(command()),
        service.execute(second),
      ]);
      expect(accepted.map((value) => value.operationId).toSet(), hasLength(2));
      expect(accepted.map((value) => value.resourceId), [
        running.vmId,
        otherState.vmId,
      ]);
      expect(await acceptedOperations(), hasLength(2));
    },
  );

  test(
    'admission uses the applied guest setting, not an unapplied disabling spec',
    () async {
      final catalog = SqliteVmRepository(database);
      final vm = (await catalog.get(running.vmId))!;
      final patched = await catalog.patch(
        running.vmId,
        expectedRevision: vm.metadata.revision,
        spec: VmSpecPatch(
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
        ),
      );
      expect(patched.status.specGeneration, 2);
      expect(patched.status.observedGeneration, 1);
      final accepted = await service.execute(command());
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.specGeneration,
        1,
      );
      expect(
        await service.beginAttempt(
          accepted.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: RequestId.generate(),
          stillCurrent: () => true,
        ),
        isNotNull,
      );
    },
  );

  test(
    'a cancel-action publication failure rolls back intent, action and retry reservation',
    () async {
      final accepted = await service.execute(command());
      final cancellation = OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-failed-publication',
        requestBody: utf8.encode('{}'),
        operationId: accepted.operationId,
      );
      await database.transaction(
        (connection) => connection.execute(
          "CREATE TRIGGER reject_cancel_work BEFORE INSERT ON outbox WHEN NEW.topic = 'guest.exec' BEGIN SELECT RAISE(ABORT, 'fixture cancellation publication failure'); END",
        ),
      );
      await expectLater(
        service.cancel(cancellation),
        throwsA(isA<Exception>()),
      );
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.cancellationRequested,
        isFalse,
      );
      expect(await acceptedOperations(), hasLength(1));
      await database.transaction(
        (connection) => connection.execute('DROP TRIGGER reject_cancel_work'),
      );
      expect(
        (await service.cancel(cancellation)).state,
        OperationState.pending,
      );
    },
  );

  test(
    'cancel completion is rolled back if a child completion event fails',
    () async {
      final accepted = await service.execute(command());
      final action = await service.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: 'cancel-child-failure',
          requestBody: utf8.encode('{}'),
          operationId: accepted.operationId,
        ),
      );
      await database.transaction(
        (connection) => connection.execute(
          "CREATE TRIGGER reject_cancel_completion BEFORE INSERT ON events WHEN NEW.type = 'operation.completed' AND NEW.operation_id = '${action.operationId.value}' BEGIN SELECT RAISE(ABORT, 'fixture cancellation completion failure'); END",
        ),
      );
      final jobs = SqliteGuestExecRepository(database);
      await expectLater(
        jobs.cancelBeforeStart(accepted.operationId),
        throwsA(isA<Exception>()),
      );
      expect((await jobs.get(accepted.operationId))!.completedAt, isNull);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.pending,
      );
      await database.transaction(
        (connection) =>
            connection.execute('DROP TRIGGER reject_cancel_completion'),
      );
      expect(await jobs.cancelBeforeStart(accepted.operationId), isTrue);
    },
  );

  test(
    'SQLite cannot clear a committed attempt to authorize a second start',
    () async {
      final accepted = await service.execute(command());
      await service.beginAttempt(
        accepted.operationId,
        attemptId: RequestId.generate(),
        controlEpochId: RequestId.generate(),
        stillCurrent: () => true,
      );
      await expectLater(
        database.transaction(
          (connection) => connection.execute(
            'UPDATE guest_exec_jobs SET started_at = NULL, attempt_id = NULL WHERE operation_id = ?',
            [accepted.operationId.value],
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        (await SqliteGuestExecRepository(
          database,
        ).get(accepted.operationId))!.startedAt,
        isNotNull,
      );
    },
  );
}

final class _HardwareBoundary implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      switch (effect) {
        ShutdownDriver(:final driverGeneration, :final operationId) =>
          ControllerDriverShutdownSucceeded(driverGeneration!, operationId!),
        ShutdownLease() => const ControllerLeaseShutdownSucceeded(),
        _ => null,
      };
}

const _request = <String, Object?>{
  'argv': ['gaoos-test', 'smoke'],
  'cwd': '/',
  'env': <String, String>{},
  'timeout_seconds': 30,
  'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 65536},
};
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
  guestAgent: GuestAgentConfig(enabled: true, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
