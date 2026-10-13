import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/image_repository.dart';
import 'package:gaovmd/src/idempotency_repository.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_vm_create_acceptance.dart';
import 'package:gaovmd/src/vm_application_service.dart';
import 'package:gaovmd/src/vm_command_repository.dart';
import 'package:gaovmd/src/vm_provisioning_repository.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late VmSpec spec;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('vm-create-accept-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    Future<ImageId> image(ImageType type) async {
      final manifest = ImageManifest.create(
        type: type,
        objects: {
          'payload': {'digest': contentDigest(type.name), 'size_bytes': 1},
        },
      );
      final image = Image(
        id: ImageId.generate(),
        digest: manifest.digest,
        type: type,
        architecture: Architecture.arm64,
        manifest: JsonObjectValue.fromJson(manifest.toJson()),
        createdAt: DateTime.utc(2026, 9, 7),
      );
      await ImageRepository(database).insert(image);
      return image.id;
    }

    spec = VmSpec(
      cpu: 2,
      memoryBytes: 268435456,
      boot: LinuxKernelBoot(kernelImageId: await image(ImageType.linuxKernel)),
      disks: [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(await image(ImageType.rawDisk)),
          writable: true,
        ),
      ],
      networks: [DisconnectedNetwork(id: 'net0')],
      graphics: GraphicsConfig(enabled: false),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    );
  });
  tearDown(() async {
    database.close();
    await temporary.delete(recursive: true);
  });
  VmCreateCommand command({String name = 'new-vm', String? key = 'create-1'}) =>
      VmCreateCommand(
        requestId: RequestId.generate(),
        idempotencyKey: key,
        requestBody: utf8.encode(
          jsonEncode({'name': name, 'spec': spec.toJson()}),
        ),
        name: name,
        spec: spec,
      );
  SqliteVmCreateAcceptance acceptor() => SqliteVmCreateAcceptance(
    database: database,
    idempotencyRetention: const Duration(days: 30),
  );

  test(
    'a full 128-VM catalog rejects creation without partial acceptance',
    () async {
      final repository = SqliteVmRepository(database);
      for (var index = 0; index < 128; index++) {
        await repository.create(name: 'defined-$index', spec: spec);
      }
      final before = await SqliteEventRepository(database).list();
      await expectLater(
        acceptor().accept(command()),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('VM catalog limit reached'),
          ),
        ),
      );
      expect(await repository.list(), hasLength(128));
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(await SqliteEventRepository(database).list(), before);
    },
  );

  test(
    'concurrent creates share the last slot and full-catalog retries replay',
    () async {
      final repository = SqliteVmRepository(database);
      for (var index = 0; index < 127; index++) {
        await repository.create(name: 'defined-$index', spec: spec);
      }
      final accepted = <OperationAcceptance>[];
      final rejected = <Object>[];
      await Future.wait([
        for (var index = 0; index < 4; index++)
          acceptor()
              .accept(command(name: 'candidate-$index', key: 'key-$index'))
              .then<void>(
                accepted.add,
                onError: (Object error) => rejected.add(error),
              ),
      ]);
      expect(accepted, hasLength(1));
      expect(rejected, everyElement(isA<VmCatalogLimitExceeded>()));
      expect(rejected, hasLength(3));
      final winner = (await SqliteOperationRepository(
        database,
      ).get(accepted.single.operationId))!;
      final vm = (await repository.get(accepted.single.resourceId as VmId))!;
      final retry = await acceptor().accept(
        command(name: vm.metadata.name, key: winner.idempotencyKey),
      );
      expect(retry.toJson(), accepted.single.toJson());
      expect(await repository.list(), hasLength(128));
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test('only a committed tombstone frees a catalog slot', () async {
    final repository = SqliteVmRepository(database);
    final victim = await repository.create(name: 'victim', spec: spec);
    for (var index = 1; index < 128; index++) {
      await repository.create(name: 'defined-$index', spec: spec);
    }
    final deleting = await repository.markDeleting(
      victim.metadata.id,
      expectedRevision: 1,
    );
    await expectLater(
      acceptor().accept(command()),
      throwsA(isA<VmCatalogLimitExceeded>()),
    );
    await repository.tombstone(
      victim.metadata.id,
      expectedRevision: deleting.metadata.revision,
    );
    expect((await acceptor().accept(command())).state, OperationState.pending);
    expect(await repository.list(), hasLength(128));
    expect(await repository.list(includeDeleted: true), hasLength(129));
  });

  test(
    'accepted create durably pins a pending job without provisioning IO',
    () async {
      final result = await acceptor().accept(command());
      final id = result.resourceId as VmId;
      expect(result.state, OperationState.pending);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final vm = (await SqliteVmRepository(database).get(id))!;
      final operation = (await SqliteOperationRepository(
        database,
      ).get(result.operationId))!;
      final job = (await SqliteVmProvisioningRepository(database).get(id))!;
      expect(vm.status.phase, VmPhase.provisioning);
      expect(vm.status.desiredState, DesiredState.stopped);
      expect(vm.status.driverGeneration, 0);
      expect(vm.status.observedGeneration, 0);
      expect(operation.type, 'vm.create');
      expect(operation.state, OperationState.pending);
      expect(job.plan.vmId, id);
      expect(job.plan.operationId, result.operationId);
      expect(job.plan.specDigest, contentDigest(spec.toJson()));
      final events = await SqliteEventRepository(database).list(vmId: id);
      expect(
        events.map((event) => event.type),
        contains('vm.provisioning.accepted'),
      );
      expect(
        await SqliteVmCommandRepository(
          database,
        ).claim(owner: 'lifecycle-worker', lease: const Duration(seconds: 30)),
        isEmpty,
      );
      expect(await Directory('${temporary.path}/vms').exists(), isFalse);
    },
  );

  test(
    'retry replays acceptance after the operation becomes terminal and database reopens',
    () async {
      final request = command();
      final first = await acceptor().accept(request);
      final operations = SqliteOperationRepository(database);
      await operations.cancel(first.operationId);
      final before = await SqliteEventRepository(database).list();
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final replay = await acceptor().accept(command());
      expect(replay.toJson(), first.toJson());
      expect(replay.state, OperationState.pending);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(first.operationId))!.state,
        OperationState.cancelled,
      );
      expect(await SqliteVmRepository(database).list(), hasLength(1));
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        await SqliteEventRepository(database).list(),
        hasLength(before.length),
      );
    },
  );

  test(
    'missing image rolls back create and leaves the idempotency key retryable',
    () async {
      final kernelId = (spec.boot as LinuxKernelBoot).kernelImageId;
      final images = ImageRepository(database);
      final kernel = (await images.get(kernelId))!;
      await images.delete(kernelId);
      final before = await SqliteEventRepository(database).list();
      await expectLater(acceptor().accept(command()), throwsStateError);
      expect(
        await SqliteVmRepository(database).list(includeDeleted: true),
        isEmpty,
      );
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(
        await SqliteEventRepository(database).list(),
        hasLength(before.length),
      );
      await images.insert(kernel);
      final result = await acceptor().accept(command());
      expect(result.state, OperationState.pending);
      expect(await SqliteVmRepository(database).list(), hasLength(1));
    },
  );

  test(
    'concurrent retries create one VM and reject changed request bytes',
    () async {
      final results = await Future.wait(
        List.generate(5, (_) => acceptor().accept(command())),
      );
      expect(results.map((result) => result.operationId).toSet(), hasLength(1));
      expect(await SqliteVmRepository(database).list(), hasLength(1));
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      await expectLater(
        acceptor().accept(command(name: 'different')),
        throwsA(isA<IdempotencyConflictException>()),
      );
      expect(await SqliteVmRepository(database).list(), hasLength(1));
    },
  );

  test(
    'acceptance cannot return success from an uncommitted caller transaction',
    () async {
      await database.transaction((_) async {
        await expectLater(acceptor().accept(command()), throwsStateError);
      });
      expect(await SqliteVmRepository(database).list(), isEmpty);
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(
        (await acceptor().accept(command())).state,
        OperationState.pending,
      );
    },
  );

  test(
    'requests without an idempotency key create independent VM jobs',
    () async {
      final results = await Future.wait([
        acceptor().accept(command(name: 'vm-a', key: null)),
        acceptor().accept(command(name: 'vm-b', key: null)),
      ]);
      expect(results.map((result) => result.resourceId).toSet(), hasLength(2));
      expect(results.map((result) => result.operationId).toSet(), hasLength(2));
      for (final result in results) {
        final job = await SqliteVmProvisioningRepository(
          database,
        ).get(result.resourceId as VmId);
        expect(job!.plan.operationId, result.operationId);
      }
    },
  );
}
