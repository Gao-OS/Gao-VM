import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late TestRun run;
  ArtifactRepository repository() => ArtifactRepository(database);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gvm-artifacts-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    run = await SqliteTestRunRepository(database).create(
      requestId: RequestId.generate(),
      spec: TestRunSpec(
        source: ImageTestRunSource(ImageId.generate()),
        wait: VmWaitSpec(
          condition: WaitCondition.guestAgentReady,
          timeoutSeconds: 30,
        ),
        steps: [
          TestStepRequest(argv: ['true'], timeoutSeconds: 60),
        ],
        cleanup: CleanupPolicy.deleteOnSuccess,
        retainOnFailure: true,
      ),
    );
  });

  tearDown(() async {
    database.close();
    await temporary.delete(recursive: true);
  });

  test(
    'published metadata, TestRun reference and event survive reopen',
    () async {
      final id = ArtifactId.generate();
      final artifact = Artifact(
        id: id,
        testRunId: run.id,
        operationId: run.operationId,
        kind: ArtifactKind.result,
        contentType: 'application/json',
        sizeBytes: 2,
        digest: contentDigest('{}'),
        downloadUrl: '/v1/artifacts/${id.value}',
        retentionUntil: DateTime.utc(2026, 11, 7),
        createdAt: DateTime.utc(2026, 10, 8),
      );
      expect(await repository().publish(artifact), artifact);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(await repository().get(id), artifact);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        [id],
      );
      final events = await SqliteEventRepository(
        database,
      ).list(testRunId: run.id);
      final created = events.singleWhere(
        (event) => event.type == 'artifact.created',
      );
      expect(created.resourceType, ResourceType.artifact);
      expect(created.resourceId, id);
      expect(created.operationId, run.operationId);
      expect(created.payload.toJson(), artifact.toJson());
      expect(
        (await SqliteEventRepository(database).readUnpublishedOutbox()).any(
          (row) => row.key == created.eventId.value,
        ),
        isTrue,
      );
    },
  );

  test(
    'caller rollback removes metadata, TestRun link, events and outbox',
    () async {
      final artifact = _artifact(run);
      final events = SqliteEventRepository(database);
      final beforeEvents = await events.list();
      final beforeOutbox = (await events.readUnpublishedOutbox())
          .map((row) => row.id)
          .toList();
      await expectLater(
        database.transaction((_) async {
          await repository().publish(artifact);
          throw StateError('injected outer rollback');
        }),
        throwsStateError,
      );
      expect(await repository().get(artifact.id), isNull);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        isEmpty,
      );
      expect(await events.list(), beforeEvents);
      expect(
        (await events.readUnpublishedOutbox()).map((row) => row.id),
        beforeOutbox,
      );
    },
  );

  test('cleanup and terminal phases fence late artifact publication', () async {
    final runs = SqliteTestRunRepository(database);
    await runs.requestCancel(run.id);
    await runs.transition(
      run.id,
      expectedState: TestRunState.pending,
      nextState: TestRunState.collecting,
      outcome: TestRunState.cancelled,
    );
    await runs.transition(
      run.id,
      expectedState: TestRunState.collecting,
      nextState: TestRunState.cleaningUp,
      cleanupDecision: 'retain',
    );
    for (final terminal in [false, true]) {
      if (terminal) await runs.finish(run.id, outcome: TestRunState.cancelled);
      final artifact = _artifact(run);
      final before = await SqliteEventRepository(database).list();
      await expectLater(
        repository().publish(artifact),
        throwsA(isA<TestRunConflictException>()),
      );
      expect(await repository().get(artifact.id), isNull);
      expect((await runs.get(run.id))!.artifactIds, isEmpty);
      expect(await SqliteEventRepository(database).list(), before);
    }
  });

  test('a foreign operation cannot publish into another TestRun', () async {
    final other = await SqliteTestRunRepository(
      database,
    ).create(requestId: RequestId.generate(), spec: run.spec);
    final artifact = Artifact.fromJson({
      ..._artifact(run).toJson(),
      'operation_id': other.operationId.value,
    });
    final before = await SqliteEventRepository(database).list();
    await expectLater(
      repository().publish(artifact),
      throwsA(isA<ArtifactPublicationConflict>()),
    );
    expect(await repository().get(artifact.id), isNull);
    for (final id in [run.id, other.id]) {
      expect(
        (await SqliteTestRunRepository(database).get(id))!.artifactIds,
        isEmpty,
      );
    }
    expect(await SqliteEventRepository(database).list(), before);
  });

  test(
    'publication replay is immutable even after its TestRun is terminal',
    () async {
      final artifact = await repository().publish(_artifact(run));
      final runs = SqliteTestRunRepository(database);
      await runs.requestCancel(run.id);
      await runs.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await runs.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      await runs.finish(run.id, outcome: TestRunState.cancelled);
      final events = await SqliteEventRepository(database).list();
      expect(await repository().publish(artifact), artifact);
      await expectLater(
        repository().publish(
          Artifact.fromJson({
            ...artifact.toJson(),
            'digest': contentDigest('changed'),
          }),
        ),
        throwsA(isA<ArtifactPublicationConflict>()),
      );
      expect(await repository().get(artifact.id), artifact);
      expect((await runs.get(run.id))!.artifactIds, [artifact.id]);
      expect(await SqliteEventRepository(database).list(), events);
    },
  );

  test('publication cannot attach evidence from a different VM', () async {
    final vms = SqliteVmRepository(database);
    final first = await vms.create(name: 'first', spec: _vmSpec());
    final second = await vms.create(name: 'second', spec: _vmSpec());
    final runs = SqliteTestRunRepository(database);
    await runs.transition(
      run.id,
      expectedState: TestRunState.pending,
      nextState: TestRunState.provisioning,
    );
    await runs.transition(
      run.id,
      expectedState: TestRunState.provisioning,
      nextState: TestRunState.startingVm,
      vmId: first.metadata.id,
    );
    final artifact = Artifact.fromJson({
      ..._artifact(run).toJson(),
      'vm_id': second.metadata.id.value,
    });
    await expectLater(
      repository().publish(artifact),
      throwsA(isA<ArtifactPublicationConflict>()),
    );
    expect(await repository().get(artifact.id), isNull);
    expect((await runs.get(run.id))!.artifactIds, isEmpty);
  });

  test(
    'v10 preserves legacy artifact references without claiming payload ownership',
    () async {
      final artifact = await repository().publish(_artifact(run));
      database.close();
      final legacy = sqlite3.open('${temporary.path}/catalog.db');
      legacy.execute('DROP INDEX IF EXISTS test_runs_collecting_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_collection_items');
      legacy.execute('DROP TABLE IF EXISTS test_run_collection');
      legacy.execute('DROP INDEX IF EXISTS test_runs_starting_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_vm_start');
      legacy.execute('DROP INDEX IF EXISTS test_runs_provisioning_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_vm_provisioning');
      legacy.execute('DROP INDEX IF EXISTS artifacts_vm_created_idx');
      legacy.execute('DROP INDEX IF EXISTS artifacts_test_run_created_idx');
      legacy.execute('DROP TABLE IF EXISTS artifact_payloads');
      legacy.execute('DELETE FROM schema_migrations WHERE version > 9');
      legacy.userVersion = 9;
      legacy.dispose();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(database.schemaVersion, 14);
      expect(await repository().get(artifact.id), artifact);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        [artifact.id],
      );
      await database.read((db) {
        expect(db.select('SELECT * FROM artifact_payloads'), isEmpty);
        expect(
          () => db.execute('INSERT INTO artifact_payloads VALUES(?, 2)', [
            artifact.id.value,
          ]),
          throwsA(isA<SqliteException>()),
        );
      });
    },
  );
  test(
    'v11 indexes preserve v10 managed ownership and paginated metadata',
    () async {
      final vm = await SqliteVmRepository(
        database,
      ).create(name: 'retained', spec: _vmSpec());
      final id = ArtifactId.generate();
      final artifact = Artifact(
        id: id,
        vmId: vm.metadata.id,
        kind: ArtifactKind.stdout,
        contentType: 'text/plain',
        sizeBytes: 2,
        digest: contentDigest('{}'),
        downloadUrl: '/v1/artifacts/${id.value}',
        createdAt: DateTime.utc(2026, 10, 8),
      );
      await repository().publish(artifact, managedPayload: true);
      database.close();
      final legacy = sqlite3.open('${temporary.path}/catalog.db');
      legacy.execute('DROP INDEX IF EXISTS test_runs_collecting_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_collection_items');
      legacy.execute('DROP TABLE IF EXISTS test_run_collection');
      legacy.execute('DROP INDEX IF EXISTS test_runs_starting_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_vm_start');
      legacy.execute('DROP INDEX IF EXISTS test_runs_provisioning_idx');
      legacy.execute('DROP TABLE IF EXISTS test_run_vm_provisioning');
      legacy.execute('DROP INDEX IF EXISTS artifacts_vm_created_idx');
      legacy.execute('DROP INDEX IF EXISTS artifacts_test_run_created_idx');
      legacy.execute('DELETE FROM schema_migrations WHERE version > 10');
      legacy.userVersion = 10;
      legacy.dispose();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(database.schemaVersion, 14);
      expect(await repository().get(id), artifact);
      expect(await repository().hasManagedPayload(id), isTrue);
      expect(
        (await repository().list(
          ArtifactListQuery(owner: vm.metadata.id),
        )).items,
        [artifact],
      );
      await database.read((db) {
        final indexes = db
            .select(
              "SELECT name FROM sqlite_schema WHERE tbl_name = 'artifacts' AND type = 'index'",
            )
            .map((row) => row['name']);
        expect(
          indexes,
          containsAll([
            'artifacts_vm_created_idx',
            'artifacts_test_run_created_idx',
          ]),
        );
      });
    },
  );
  test(
    'default and maximum pages resume after reopen without shifting on earlier inserts',
    () async {
      final vm = await SqliteVmRepository(
        database,
      ).create(name: 'pages', spec: _vmSpec());
      final values = <Artifact>[];
      final time = DateTime.utc(2026, 10, 8);
      Future<Artifact> publish(DateTime createdAt) {
        final id = ArtifactId.generate();
        return repository().publish(
          Artifact(
            id: id,
            vmId: vm.metadata.id,
            kind: ArtifactKind.result,
            contentType: 'application/json',
            sizeBytes: 2,
            digest: contentDigest('{}'),
            downloadUrl: '/v1/artifacts/${id.value}',
            createdAt: createdAt,
          ),
        );
      }

      for (var index = 0; index < 201; index++) {
        values.add(await publish(time.add(Duration(microseconds: index))));
      }
      final first = await repository().list(
        ArtifactListQuery(owner: vm.metadata.id),
      );
      expect(first.items, values.take(50));
      expect(first.nextCursor, isNotNull);
      final maximum = await repository().list(
        ArtifactListQuery(owner: vm.metadata.id, limit: 200),
      );
      expect(maximum.items, values.take(200));
      await publish(time.subtract(const Duration(microseconds: 1)));
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final after = await repository().list(
        ArtifactListQuery(
          owner: vm.metadata.id,
          cursor: first.nextCursor,
          limit: 200,
        ),
      );
      expect(after.items, values.skip(50));
      expect(after.nextCursor, isNull);
      final last = await repository().list(
        ArtifactListQuery(owner: vm.metadata.id, cursor: maximum.nextCursor),
      );
      expect(last.items, [values.last]);
      expect(last.nextCursor, isNull);
      await expectLater(
        () => repository().list(
          ArtifactListQuery(owner: run.id, cursor: first.nextCursor),
        ),
        throwsFormatException,
      );
    },
  );
}

Artifact _artifact(TestRun run) {
  final id = ArtifactId.generate();
  return Artifact(
    id: id,
    testRunId: run.id,
    operationId: run.operationId,
    kind: ArtifactKind.result,
    contentType: 'application/json',
    sizeBytes: 2,
    digest: contentDigest('{}'),
    downloadUrl: '/v1/artifacts/${id.value}',
    createdAt: DateTime.utc(2026, 10, 8),
  );
}

VmSpec _vmSpec() => VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: LinuxKernelBoot(kernelImageId: ImageId.generate()),
  disks: [
    VmDisk(id: 'root', source: ExternalDiskSource('/tmp/disk'), writable: true),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
