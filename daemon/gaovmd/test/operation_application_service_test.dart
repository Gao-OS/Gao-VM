import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  test('wait deadline includes a blocked initial repository read', () async {
    final read = Completer<Operation?>();
    final service = OperationApplicationService(
      repository: _ReadRepository(() => read.future),
      mutations: _OperationMutations(),
      waiter: _OperationWaiter(),
    );
    await expectLater(
      service
          .wait(
            OperationWaitCommand(
              operationId: _cancelOperation.id,
              timeout: const Duration(milliseconds: 20),
            ),
          )
          .timeout(
            const Duration(milliseconds: 500),
            onTimeout: () =>
                throw StateError('service deadline was not enforced'),
          ),
      throwsA(isA<TimeoutException>()),
    );
    read.complete(_cancelOperation);
  });

  test('initial read consumes the budget passed to the waiter', () async {
    final pending = Operation.fromJson({
      ..._cancelOperation.toJson(),
      'state': 'running',
      'completed_at': null,
    });
    Duration? received;
    final service = OperationApplicationService(
      repository: _ReadRepository(
        () => Future<Operation>.delayed(
          const Duration(milliseconds: 30),
          () => pending,
        ),
      ),
      mutations: _OperationMutations(),
      waiter: _CallbackWaiter((command) async {
        received = command.timeout;
        return _cancelOperation;
      }),
    );
    expect(
      await service.wait(
        OperationWaitCommand(
          operationId: pending.id,
          timeout: const Duration(seconds: 1),
        ),
      ),
      _cancelOperation,
    );
    expect(received!, lessThan(const Duration(milliseconds: 980)));
    expect(received!, greaterThan(Duration.zero));
  });

  test(
    'bounds a stalled waiter and preserves immediate terminal behavior',
    () async {
      final pending = Operation.fromJson({
        ..._cancelOperation.toJson(),
        'state': 'running',
        'completed_at': null,
      });
      final blocked = Completer<Operation>();
      final service = OperationApplicationService(
        repository: _ReadRepository(() async => pending),
        mutations: _OperationMutations(),
        waiter: _CallbackWaiter((_) => blocked.future),
      );
      await expectLater(
        service.wait(
          OperationWaitCommand(
            operationId: pending.id,
            timeout: const Duration(milliseconds: 20),
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      blocked.complete(_cancelOperation);
      final terminalService = OperationApplicationService(
        repository: _ReadRepository(() async => _cancelOperation),
        mutations: _OperationMutations(),
        waiter: _OperationWaiter(),
      );
      expect(
        await terminalService.wait(
          OperationWaitCommand(
            operationId: pending.id,
            timeout: const Duration(seconds: 1),
          ),
        ),
        _cancelOperation,
      );
    },
  );

  test('still rejects a nonterminal or wrong-ID waiter result', () async {
    final pending = Operation.fromJson({
      ..._cancelOperation.toJson(),
      'state': 'running',
      'completed_at': null,
    });
    for (final invalid in [
      pending,
      Operation.fromJson({
        ..._cancelOperation.toJson(),
        'id': _operation(99).value,
      }),
    ]) {
      final service = OperationApplicationService(
        repository: _ReadRepository(() async => pending),
        mutations: _OperationMutations(),
        waiter: _CallbackWaiter((_) async => invalid),
      );
      await expectLater(
        service.wait(
          OperationWaitCommand(
            operationId: pending.id,
            timeout: const Duration(seconds: 1),
          ),
        ),
        throwsStateError,
      );
    }
  });

  test('lists and resumes durable operations with filters', () async {
    final directory = await Directory.systemTemp.createTemp('operation-app-');
    final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
    final ids = [_operation(1), _operation(2), _operation(3)].iterator;
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () {
        ids.moveNext();
        return ids.current;
      },
    );
    for (var index = 1; index <= 3; index++) {
      await repository.create(
        type: 'operation.probe',
        resourceType: ResourceType.operation,
        resourceId: _operation(20 + index),
        requestId: _request(index),
        cancellable: true,
        request: JsonObjectValue.fromJson({'index': index}),
      );
    }
    final service = OperationApplicationService(
      repository: repository,
      mutations: _OperationMutations(),
      waiter: _OperationWaiter(),
    );

    final first = await service.list(
      OperationListQuery(limit: 2, state: OperationState.pending),
    );
    final second = await service.list(
      OperationListQuery(
        limit: 2,
        cursor: first.nextCursor,
        state: OperationState.pending,
      ),
    );

    expect(first.items.map((item) => item.id), [_operation(1), _operation(2)]);
    expect(first.nextCursor, isNotNull);
    expect(second.items.map((item) => item.id), [_operation(3)]);
    expect(second.nextCursor, isNull);

    // A state-filtered cursor must survive its anchor completing between pages.
    await repository.start(_operation(2));
    final resumed = await service.list(
      OperationListQuery(
        cursor: first.nextCursor,
        state: OperationState.pending,
      ),
    );
    expect(resumed.items.map((item) => item.id), [_operation(3)]);
    await expectLater(
      service.list(
        OperationListQuery(
          cursor: first.nextCursor,
          state: OperationState.running,
        ),
      ),
      throwsFormatException,
    );

    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'delegates cancellation action and waits for a terminal operation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'operation-command-',
      );
      final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      final repository = SqliteOperationRepository(
        database,
        newOperationId: () => _operation(1),
      );
      final target = await repository.createAndStart(
        type: 'vm.start',
        resourceType: ResourceType.operation,
        resourceId: _operation(21),
        requestId: _request(1),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      final mutations = _OperationMutations();
      final service = OperationApplicationService(
        repository: repository,
        mutations: mutations,
        waiter: _OperationWaiter(target),
      );
      final cancel = OperationCancelCommand(
        requestId: _request(2),
        idempotencyKey: 'cancel-once',
        requestBody: const [],
        operationId: target.id,
      );

      expect(
        (await service.cancel(cancel)).toJson(),
        OperationAcceptance.fromOperation(_cancelOperation).toJson(),
      );
      final completed = await service.wait(
        OperationWaitCommand(
          operationId: target.id,
          timeout: const Duration(seconds: 5),
        ),
      );

      expect(mutations.command, same(cancel));
      expect(completed.id, target.id);
      expect(completed.state, OperationState.succeeded);

      database.close();
      await directory.delete(recursive: true);
    },
  );
}

final class _ReadRepository implements OperationRepository {
  _ReadRepository(this.read);
  final Future<Operation?> Function() read;
  @override
  Future<Operation?> get(OperationId id) => read();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected repository mutation');
}

final class _CallbackWaiter implements OperationWaiter {
  _CallbackWaiter(this.callback);
  final Future<Operation> Function(OperationWaitCommand) callback;
  @override
  Future<Operation> wait(OperationWaitCommand command) => callback(command);
}

final class _OperationMutations implements OperationMutationAcceptor {
  OperationCancelCommand? command;

  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async {
    this.command = command;
    return OperationAcceptance.fromOperation(_cancelOperation);
  }
}

final class _OperationWaiter implements OperationWaiter {
  _OperationWaiter([this.target]);

  final Operation? target;

  @override
  Future<Operation> wait(OperationWaitCommand command) async {
    final operation = target!;
    return Operation(
      id: operation.id,
      type: operation.type,
      resourceType: operation.resourceType,
      resourceId: operation.resourceId,
      state: OperationState.succeeded,
      requestId: operation.requestId,
      cancellable: false,
      request: operation.request,
      createdAt: operation.createdAt,
      startedAt: operation.startedAt,
      completedAt: DateTime.utc(2026, 9, 7),
    );
  }
}

OperationId _operation(int value) => OperationId(
  'op_01J00000000000000000000${value.toString().padLeft(3, '0')}',
);

RequestId _request(int value) =>
    RequestId('req_01J00000000000000000000${value.toString().padLeft(3, '0')}');

final _cancelOperation = Operation(
  id: _operation(10),
  type: 'operation.cancel',
  resourceType: ResourceType.operation,
  resourceId: _operation(1),
  state: OperationState.succeeded,
  requestId: _request(10),
  cancellable: false,
  request: JsonObjectValue.empty,
  createdAt: DateTime.utc(2026, 9, 7),
  startedAt: DateTime.utc(2026, 9, 7),
  completedAt: DateTime.utc(2026, 9, 7),
);
