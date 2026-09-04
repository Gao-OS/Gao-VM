import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-vm-repository-',
    );
    databasePath = '${temporaryDirectory.path}/gaovm.db';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('create/list/get survive closing and reopening the database', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteVmRepository(
      database,
      newVmId: () => VmId('vm_01J00000000000000000000000'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );

    final created = await repository.create(
      name: 'primary',
      labels: const {'environment': 'test'},
      spec: _spec(cpu: 2),
    );

    expect(created.metadata.id.value, 'vm_01J00000000000000000000000');
    expect(created.metadata.revision, 1);
    expect(created.metadata.labels, {'environment': 'test'});
    expect(created.status.specGeneration, 1);
    expect(created.status.phase, VmPhase.defined);
    expect(await repository.list(), [created]);
    expect(await repository.get(created.metadata.id), created);
    database.close();

    final reopened = await GaoVmDatabase.open(databasePath);
    final reopenedRepository = SqliteVmRepository(reopened);
    expect(await reopenedRepository.get(created.metadata.id), created);
    reopened.close();
  });

  test('multiple VM resources coexist without a default singleton', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final ids = [
      VmId('vm_01J00000000000000000000004'),
      VmId('vm_01J00000000000000000000005'),
    ].iterator;
    final repository = SqliteVmRepository(
      database,
      newVmId: () {
        ids.moveNext();
        return ids.current;
      },
      now: () => DateTime.utc(2026, 9, 4, 9),
    );

    final first = await repository.create(name: 'first', spec: _spec(cpu: 2));
    final second = await repository.create(name: 'second', spec: _spec(cpu: 4));

    expect(await repository.list(), [first, second]);
    expect(await repository.get(first.metadata.id), first);
    expect(await repository.get(second.metadata.id), second);
    database.close();
  });

  test(
    'metadata and spec writes advance revision and spec generation',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final repository = SqliteVmRepository(
        database,
        newVmId: () => VmId('vm_01J00000000000000000000001'),
      );
      final created = await repository.create(
        name: 'primary',
        spec: _spec(cpu: 2),
      );

      final patched = await repository.patch(
        created.metadata.id,
        expectedRevision: created.metadata.revision,
        labels: const {'suite': 'network', 'channel': 'nightly'},
        spec: VmSpecPatch(cpu: 4),
      );
      expect(patched.metadata.revision, 2);
      expect(patched.metadata.labels, {
        'suite': 'network',
        'channel': 'nightly',
      });
      expect(patched.spec.cpu, 4);
      expect(patched.status.specGeneration, 2);
      expect(patched.status.restartRequired, isFalse);

      final renamed = await repository.patch(
        created.metadata.id,
        expectedRevision: patched.metadata.revision,
        name: 'renamed',
      );
      expect(renamed.metadata.revision, 3);
      expect(renamed.status.specGeneration, 2);

      final replaced = await repository.updateSpec(
        created.metadata.id,
        expectedRevision: renamed.metadata.revision,
        spec: _spec(cpu: 8),
      );
      expect(replaced.metadata.revision, 4);
      expect(replaced.status.specGeneration, 3);
      expect(replaced.spec.cpu, 8);
      database.close();
    },
  );

  test(
    'a stale revision from another connection cannot overwrite a VM',
    () async {
      final firstDatabase = await GaoVmDatabase.open(databasePath);
      final first = SqliteVmRepository(
        firstDatabase,
        newVmId: () => VmId('vm_01J00000000000000000000002'),
      );
      final created = await first.create(name: 'primary', spec: _spec(cpu: 2));
      final secondDatabase = await GaoVmDatabase.open(databasePath);
      final second = SqliteVmRepository(secondDatabase);

      await first.patch(
        created.metadata.id,
        expectedRevision: created.metadata.revision,
        labels: const {'writer': 'first'},
      );

      await expectLater(
        () => second.patch(
          created.metadata.id,
          expectedRevision: created.metadata.revision,
          labels: const {'writer': 'second'},
        ),
        throwsA(
          isA<RevisionConflictException>()
              .having((error) => error.expectedRevision, 'expectedRevision', 1)
              .having((error) => error.actualRevision, 'actualRevision', 2),
        ),
      );
      expect((await first.get(created.metadata.id))!.metadata.labels, {
        'writer': 'first',
      });

      secondDatabase.close();
      firstDatabase.close();
    },
  );

  test('two-phase deletion retains a hidden durable tombstone', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteVmRepository(
      database,
      newVmId: () => VmId('vm_01J00000000000000000000003'),
    );
    final created = await repository.create(
      name: 'primary',
      spec: _spec(cpu: 2),
    );

    final deleting = await repository.markDeleting(
      created.metadata.id,
      expectedRevision: created.metadata.revision,
    );
    expect(deleting.metadata.revision, 2);
    expect(deleting.status.desiredState, DesiredState.stopped);
    expect(deleting.status.phase, VmPhase.deleting);
    expect(await repository.list(), [deleting]);

    final deleted = await repository.tombstone(
      created.metadata.id,
      expectedRevision: deleting.metadata.revision,
    );
    expect(deleted.metadata.revision, 3);
    expect(deleted.status.phase, VmPhase.deleted);
    expect(await repository.get(created.metadata.id), isNull);
    expect(await repository.list(), isEmpty);
    database.close();

    final reopened = await GaoVmDatabase.open(databasePath);
    final reopenedRepository = SqliteVmRepository(reopened);
    expect(await reopenedRepository.get(created.metadata.id), isNull);
    expect(
      await reopenedRepository.get(created.metadata.id, includeDeleted: true),
      deleted,
    );
    reopened.close();
  });

  test(
    'repository writes join and roll back with an outer transaction',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final repository = SqliteVmRepository(
        database,
        newVmId: () => VmId('vm_01J00000000000000000000006'),
      );
      final created = await repository.create(
        name: 'primary',
        spec: _spec(cpu: 2),
      );

      await expectLater(
        () => database.transaction((_) async {
          await repository.patch(
            created.metadata.id,
            expectedRevision: created.metadata.revision,
            labels: const {'transaction': 'rolled-back'},
          );
          throw StateError('roll back the outer unit of work');
        }),
        throwsStateError,
      );

      expect(await repository.get(created.metadata.id), created);
      database.close();
    },
  );

  test('running spec changes set restart-required', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteVmRepository(
      database,
      newVmId: () => VmId('vm_01J00000000000000000000007'),
    );
    final created = await repository.create(
      name: 'primary',
      spec: _spec(cpu: 2),
    );
    await database.transaction(
      (connection) => connection.execute(
        '''
          UPDATE vm_runtime
          SET desired_state = 'running', phase = 'running',
              observed_generation = 1
          WHERE vm_id = ?
        ''',
        [created.metadata.id.value],
      ),
    );

    final patched = await repository.patch(
      created.metadata.id,
      expectedRevision: created.metadata.revision,
      spec: VmSpecPatch(cpu: 4),
    );

    expect(patched.status.specGeneration, 2);
    expect(patched.status.observedGeneration, 1);
    expect(patched.status.restartRequired, isTrue);
    database.close();
  });

  test('running non-frozen spec changes do not require restart', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteVmRepository(
      database,
      newVmId: () => VmId('vm_01J00000000000000000000008'),
    );
    final created = await repository.create(
      name: 'primary',
      spec: _spec(cpu: 2),
    );
    await database.transaction(
      (connection) => connection.execute(
        '''
          UPDATE vm_runtime
          SET desired_state = 'running', phase = 'running',
              observed_generation = 1
          WHERE vm_id = ?
        ''',
        [created.metadata.id.value],
      ),
    );

    final patched = await repository.patch(
      created.metadata.id,
      expectedRevision: created.metadata.revision,
      spec: VmSpecPatch(
        guestProfile: const PatchField<String?>.present('gaoos'),
        disks: [
          VmDisk(
            id: 'root',
            source: ExternalDiskSource('/tmp/root.img'),
            writable: false,
          ),
        ],
        networks: [SharedNetwork(id: 'net0', macAddress: '02:00:00:00:00:01')],
        serial: const SerialConfig(enabled: false, capture: false),
        guestAgent: GuestAgentConfig(enabled: true, requiredForReady: false),
        restartPolicy: RestartPolicy.always,
        autostart: true,
      ),
    );

    expect(patched.status.specGeneration, 2);
    expect(patched.status.observedGeneration, 1);
    expect(patched.status.restartRequired, isFalse);
    database.close();
  });

  test('list matches equality and inequality label requirements', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final ids = [
      VmId('vm_01J00000000000000000000010'),
      VmId('vm_01J00000000000000000000011'),
      VmId('vm_01J00000000000000000000012'),
    ].iterator;
    final repository = SqliteVmRepository(
      database,
      newVmId: () {
        ids.moveNext();
        return ids.current;
      },
    );
    final web = await repository.create(
      name: 'web',
      labels: const {'environment': 'prod', 'tier': 'web'},
      spec: _spec(cpu: 2),
    );
    await repository.create(
      name: 'batch',
      labels: const {'environment': 'prod', 'tier': 'batch'},
      spec: _spec(cpu: 2),
    );
    final development = await repository.create(
      name: 'development',
      labels: const {'environment': 'dev'},
      spec: _spec(cpu: 2),
    );

    expect(
      await repository.list(
        labelSelector: LabelSelector.parse('environment==prod,tier!=batch'),
      ),
      [web],
    );
    expect(
      await repository.list(labelSelector: LabelSelector.parse('tier!=batch')),
      [web, development],
    );
    database.close();
  });

  test('label selector rejects malformed requirements', () {
    expect(() => LabelSelector.parse('environment'), throwsFormatException);
    expect(() => LabelSelector.parse('=prod'), throwsFormatException);
    expect(
      () => LabelSelector.parse('environment=prod,'),
      throwsFormatException,
    );
  });

  test('fixed-width timestamps preserve chronological list order', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final ids = [
      VmId('vm_01J00000000000000000000014'),
      VmId('vm_01J00000000000000000000013'),
    ].iterator;
    final times = [
      DateTime.utc(2026, 9, 4, 9),
      DateTime.utc(2026, 9, 4, 9, 0, 0, 0, 1),
    ].iterator;
    final repository = SqliteVmRepository(
      database,
      newVmId: () {
        ids.moveNext();
        return ids.current;
      },
      now: () {
        times.moveNext();
        return times.current;
      },
    );
    final first = await repository.create(name: 'first', spec: _spec(cpu: 2));
    final second = await repository.create(name: 'second', spec: _spec(cpu: 2));

    expect(await repository.list(), [first, second]);
    await database.read((connection) {
      final timestamps = connection.select(
        'SELECT created_at FROM vms ORDER BY created_at',
      );
      expect(timestamps.map((row) => row['created_at']), [
        '2026-09-04T09:00:00.000000Z',
        '2026-09-04T09:00:00.000001Z',
      ]);
    });
    database.close();
  });
}

VmSpec _spec({required int cpu}) => VmSpec(
  cpu: cpu,
  memoryBytes: 2147483648,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [SharedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
