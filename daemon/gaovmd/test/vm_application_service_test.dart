import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_application_service.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  test('maximal Unicode sort keys produce resumable bounded cursors', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vm-cursor-unicode-',
    );
    final database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    try {
      final ids = [_vm(1), _vm(2)].iterator;
      final repository = SqliteVmRepository(
        database,
        newVmId: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final name = List.generate(
        128,
        (index) => String.fromCharCode(0x4000 + index),
      ).join();
      await repository.create(
        name: name,
        labels: {'suite': 'nightly'},
        spec: _spec,
      );
      await repository.create(
        name: '高' * 128,
        labels: {'suite': 'nightly'},
        spec: _spec,
      );
      final service = VmApplicationService(
        repository: repository,
        mutations: _Mutations(),
        waiter: _VmWaiter(),
      );
      for (final sort in VmSort.values) {
        final first = await service.list(
          VmListQuery(
            limit: 1,
            sort: sort,
            selector: LabelSelector.parse('suite=nightly'),
          ),
        );
        expect(first.nextCursor!.length, lessThanOrEqualTo(512));
        final second = await service.list(
          VmListQuery(
            limit: 1,
            sort: sort,
            selector: LabelSelector.parse('suite=nightly'),
            cursor: first.nextCursor,
          ),
        );
        expect(second.items, hasLength(1));
        expect(
          second.items.single.metadata.id,
          isNot(first.items.single.metadata.id),
        );
      }
    } finally {
      database.close();
      await directory.delete(recursive: true);
    }
  });
  test('lists VMs with stable sort, selector, limit, and cursor', () async {
    final directory = await Directory.systemTemp.createTemp('vm-app-');
    final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
    final ids = [_vm(1), _vm(2), _vm(3)].iterator;
    final repository = SqliteVmRepository(
      database,
      newVmId: () {
        ids.moveNext();
        return ids.current;
      },
    );
    await repository.create(
      name: 'alpha',
      labels: const {'suite': 'nightly'},
      spec: _spec,
    );
    await repository.create(
      name: 'charlie',
      labels: const {'suite': 'nightly'},
      spec: _spec,
    );
    await repository.create(
      name: 'bravo',
      labels: const {'suite': 'stable'},
      spec: _spec,
    );
    final service = VmApplicationService(
      repository: repository,
      mutations: _Mutations(),
      waiter: _VmWaiter(),
    );

    final first = await service.list(
      VmListQuery(
        limit: 1,
        selector: LabelSelector.parse('suite=nightly'),
        sort: VmSort.nameDescending,
      ),
    );
    final second = await service.list(
      VmListQuery(
        limit: 1,
        cursor: first.nextCursor,
        selector: LabelSelector.parse('suite=nightly'),
        sort: VmSort.nameDescending,
      ),
    );

    expect(first.items.single.metadata.name, 'charlie');
    expect(first.nextCursor, isNotNull);
    expect(second.items.single.metadata.name, 'alpha');
    expect(second.nextCursor, isNull);

    await database.transaction((db) {
      db.execute('UPDATE vms SET name = ? WHERE id = ?', [
        'aardvark',
        _vm(2).value,
      ]);
    });
    final renamedAnchor = await service.list(
      VmListQuery(
        cursor: first.nextCursor,
        selector: LabelSelector.parse('suite=nightly'),
        sort: VmSort.nameDescending,
      ),
    );
    expect(
      renamedAnchor.items.map((vm) => vm.metadata.name),
      contains('alpha'),
    );
    await database.transaction((db) {
      db.execute('UPDATE vms SET deleted_at = ? WHERE id = ?', [
        '2026-09-07T00:00:00.000000Z',
        _vm(2).value,
      ]);
    });
    final deletedAnchor = await service.list(
      VmListQuery(
        cursor: first.nextCursor,
        selector: LabelSelector.parse('suite=nightly'),
        sort: VmSort.nameDescending,
      ),
    );
    expect(deletedAnchor.items.map((vm) => vm.metadata.name), ['alpha']);
    await expectLater(
      service.list(VmListQuery(cursor: first.nextCursor, sort: VmSort.name)),
      throwsFormatException,
    );

    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'delegates durable mutations and explicit waits without blocking',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vm-app-command-',
      );
      final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      final repository = SqliteVmRepository(database, newVmId: () => _vm(1));
      await repository.create(name: 'vm', spec: _spec);
      final mutations = _Mutations();
      final waiter = _VmWaiter();
      final service = VmApplicationService(
        repository: repository,
        mutations: mutations,
        waiter: waiter,
      );
      final create = VmCreateCommand(
        requestId: _request,
        idempotencyKey: 'create-once',
        requestBody: const [1, 2, 3],
        name: 'created',
        spec: _spec,
      );
      final lifecycle = VmLifecycleCommand(
        requestId: _request,
        idempotencyKey: 'kill-once',
        requestBody: const [],
        vmId: _vm(1),
        action: VmLifecycleAction.kill,
      );

      expect((await service.create(create)).toJson(), _acceptance.toJson());
      expect(
        (await service.lifecycle(lifecycle)).toJson(),
        _acceptance.toJson(),
      );
      final wait = await service.wait(
        VmWaitCommand(
          vmId: _vm(1),
          condition: VmWaitCondition.runtimeRunning,
          timeout: const Duration(seconds: 5),
        ),
      );

      expect(mutations.createCommand, same(create));
      expect(mutations.lifecycleCommand, same(lifecycle));
      expect(wait.vmId, _vm(1));
      expect(wait.observedAt, _observedAt);

      database.close();
      await directory.delete(recursive: true);
    },
  );
}

final class _Mutations implements VmMutationAcceptor {
  VmCreateCommand? createCommand;
  VmLifecycleCommand? lifecycleCommand;

  @override
  Future<OperationAcceptance> create(VmCreateCommand command) async {
    createCommand = command;
    return _acceptance;
  }

  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand command) async {
    lifecycleCommand = command;
    return _acceptance;
  }

  @override
  Future<OperationAcceptance> patch(VmPatchCommand command) =>
      throw UnimplementedError();
}

final class _VmWaiter implements VmConditionWaiter {
  @override
  Future<DateTime> wait(VmWaitCommand command) async => _observedAt;
}

VmId _vm(int value) => VmId('vm_01J0000000000000000000000${value.toString()}');

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

final _request = RequestId('req_01J00000000000000000000000');
final _operation = Operation(
  id: OperationId('op_01J00000000000000000000000'),
  type: 'vm.create',
  resourceType: ResourceType.virtualMachine,
  resourceId: _vm(1),
  state: OperationState.running,
  requestId: _request,
  cancellable: true,
  request: JsonObjectValue.empty,
  createdAt: DateTime.utc(2026, 9, 7),
  startedAt: DateTime.utc(2026, 9, 7),
);
final _observedAt = DateTime.utc(2026, 9, 7, 1);
final _acceptance = OperationAcceptance.fromOperation(_operation);
