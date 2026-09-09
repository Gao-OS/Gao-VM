import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late VmControllerState state;
  late OperationId operationId;
  late File external;
  late Image diskImage;
  late Image kernel;
  late VmProvisioningPlan plan;
  late Future<void> Function({BootConfig? boot}) prepareDelete;
  String bundlePath() => '${bundles.path}/${state.vmId.value}.gaovm';
  SqliteVmManagedFileEffectAdapter adapter() =>
      SqliteVmManagedFileEffectAdapter(database: database, bundles: bundles);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vm-delete-');
    database = await GaoVmDatabase.open('${root.path}/catalog.db');
    final store = ImageStore(database, Directory('${root.path}/images'));
    final source = await File('${root.path}/source').writeAsString('original');
    kernel = await store.importFile(source, type: ImageType.linuxKernel);
    diskImage = await store.importFile(source, type: ImageType.rawDisk);
    external = await File('${root.path}/external').writeAsString('external');
    final vmRoot = await Directory('${root.path}/vms').create();
    imageFileMode(vmRoot.path, 0x1c0);
    bundles = await OwnedImageDirectory.open(vmRoot);
    images = await OwnedImageDirectory.open(Directory('${root.path}/images'));
    await prepareDelete();
  });

  prepareDelete = ({BootConfig? boot}) async {
    final accepted =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 1),
        ).create(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'delete',
            spec: VmSpec(
              cpu: 2,
              memoryBytes: 268435456,
              boot: boot ?? LinuxKernelBoot(kernelImageId: kernel.id),
              disks: [
                VmDisk(
                  id: 'root',
                  source: ManagedImageDiskSource(diskImage.id),
                  writable: true,
                ),
                VmDisk(
                  id: 'external',
                  source: ExternalDiskSource(external.path),
                  writable: true,
                ),
              ],
              networks: [DisconnectedNetwork(id: 'net0')],
              graphics: GraphicsConfig(enabled: false),
              serial: const SerialConfig(enabled: true, capture: true),
              guestAgent: GuestAgentConfig(
                enabled: false,
                requiredForReady: false,
              ),
              restartPolicy: RestartPolicy.never,
            ),
          ),
        );
    final id = accepted.resourceId as VmId;
    final results = await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'test',
    ).dispatchOnce();
    expect(results.single.completion, VmProvisioningCompletionKind.succeeded);
    plan = (await SqliteVmProvisioningRepository(database).get(id))!.plan;
    final initial = VmControllerState.initial(
      vmId: id,
      specGeneration: 1,
      restartPolicy: RestartPolicy.never,
    );
    final deletion = await SqliteVmLifecycleAcceptance(
      database: database,
      idempotencyRetention: const Duration(days: 1),
      command: VmLifecycleCommand(
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: const [],
        vmId: id,
        action: VmLifecycleAction.delete,
      ),
    ).commit(initial);
    operationId = deletion.result.operationId;
    await SqliteOperationRepository(database).start(operationId);
    state = reduce(
      initial.copyWith(appliedIntentRevision: deletion.intentRevision),
      DeleteRequested(operationId),
    ).state;
    await SqliteVmStateEffectAdapter(database).persistVm(state);
    await SqliteVmStateEffectAdapter(database).persistRuntime(state);
  };
  tearDown(() async {
    images.close();
    bundles.close();
    database.close();
    await root.delete(recursive: true);
  });

  test(
    'deletes modified managed disk and logs but preserves external disk and images',
    () async {
      await File(
        '${bundlePath()}/disks/root.raw',
      ).writeAsString('guest changed disk');
      await File('${bundlePath()}/logs/driver.log').writeAsString('driver log');
      await adapter().remove(state, operationId);
      expect(await Directory(bundlePath()).exists(), isFalse);
      expect(await external.readAsString(), 'external');
      expect(
        await Directory(
          '${images.path}/sha256-${diskImage.digest.substring(7)}',
        ).exists(),
        isTrue,
      );
      await adapter().remove(state, operationId);
    },
  );

  test(
    'rejects a deletion checkpoint with a different applied spec generation',
    () async {
      await expectLater(
        adapter().remove(state.copyWith(specGeneration: 2), operationId),
        throwsStateError,
      );
      expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
    },
  );

  test(
    'refuses a retained lease even if the caller claims lease-free state',
    () async {
      await SqliteHostLeaseRepository(database).retainForCleanup(
        request: HostCapacityRequest(
          vmId: state.vmId,
          cpuCount: 2,
          memoryBytes: 268435456,
          diskBytes: 0,
          phase: HostLeasePhase.cleanup,
          specGeneration: 1,
          operationId: operationId,
          driverGeneration: 1,
        ),
        ownerId: 'driver-owner',
        now: DateTime.now(),
        ttl: const Duration(seconds: 30),
      );
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
      await SqliteHostLeaseRepository(
        database,
      ).release(state.vmId, ownerId: 'driver-owner');
      await adapter().remove(state, operationId);
      expect(await Directory(bundlePath()).exists(), isFalse);
    },
  );

  test(
    'refuses active generations, foreign operations and terminal durable operations',
    () async {
      await expectLater(
        adapter().remove(
          state.copyWith(activeDriverGeneration: 1),
          operationId,
        ),
        throwsStateError,
      );
      await expectLater(
        adapter().remove(state, OperationId.generate()),
        throwsStateError,
      );
      await SqliteOperationRepository(database).succeed(operationId);
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
    },
  );

  test(
    'unknown artifact content is preserved before any managed disk is removed',
    () async {
      final artifact = await File(
        '${bundlePath()}/artifacts/result',
      ).writeAsString('retained evidence');
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      expect(await artifact.readAsString(), 'retained evidence');
      expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
    },
  );

  test('a symlink in a known leaf cannot delete its external target', () async {
    final disk = File('${bundlePath()}/disks/root.raw');
    await disk.delete();
    await Link(disk.path).create(external.path);
    await expectLater(
      adapter().remove(state, operationId),
      throwsA(isA<FileSystemException>()),
    );
    expect(await external.readAsString(), 'external');
    expect(await Link(disk.path).exists(), isTrue);
  });

  test(
    'resumes quarantine after partial cleanup and can repeat after file completion',
    () async {
      final quarantine =
          '.deleting-${state.vmId.value}-${plan.operationId.value}';
      await bundles.renameDirectoryNoReplace(
        '${state.vmId.value}.gaovm',
        quarantine,
      );
      await File('${bundles.path}/$quarantine/disks/root.raw').delete();
      await adapter().remove(state, operationId);
      expect(await Directory('${bundles.path}/$quarantine').exists(), isFalse);
      await adapter().remove(state, operationId);
      expect(await external.readAsString(), 'external');
    },
  );

  test(
    'resumes an empty quarantine after manifest removal but rejects an unproven nonempty one',
    () async {
      final quarantine =
          '.deleting-${state.vmId.value}-${plan.operationId.value}';
      await bundles.renameDirectoryNoReplace(
        '${state.vmId.value}.gaovm',
        quarantine,
      );
      await File('${bundles.path}/$quarantine/manifest.json').delete();
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      final directory = Directory('${bundles.path}/$quarantine');
      // Model a crash after the adapter removed every validated owned child.
      await File('${directory.path}/disks/root.raw').delete();
      for (final child in ['disks', 'logs', 'artifacts', 'runtime', 'nvram']) {
        await Directory('${directory.path}/$child').delete();
      }
      await adapter().remove(state, operationId);
      expect(await directory.exists(), isFalse);
    },
  );

  test('tampered publication origin never authorizes removal', () async {
    await File('${bundlePath()}/manifest.json').writeAsString('{}');
    await expectLater(
      adapter().remove(state, operationId),
      throwsFormatException,
    );
    expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
  });

  test(
    'removes an EFI store only when the original persisted spec proves managed ownership',
    () async {
      await prepareDelete(boot: EfiBoot());
      await File(
        '${bundlePath()}/nvram/efi-variable-store',
      ).writeAsString('changed firmware');
      await adapter().remove(state, operationId);
      expect(await Directory(bundlePath()).exists(), isFalse);
    },
  );

  test(
    'external EFI storage remains external and does not authorize an owned EFI leaf',
    () async {
      await prepareDelete(
        boot: EfiBoot(
          variableStore: EfiVariableStore.external,
          variableStorePath: external.path,
        ),
      );
      await File(
        '${bundlePath()}/nvram/efi-variable-store',
      ).writeAsString('unproven');
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      expect(await external.readAsString(), 'external');
    },
  );

  test(
    'a referenced artifact blocks deletion even when its bundle directory is empty',
    () async {
      await database.transaction((db) {
        db.execute(
          '''INSERT INTO artifacts
        (id, vm_id, kind, content_type, size_bytes, digest, download_url, created_at)
        VALUES (?, ?, 'test_result', 'text/plain', 1, 'proof', '/retained', ?)
      ''',
          [
            ArtifactId.generate().value,
            state.vmId.value,
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      });
      await expectLater(adapter().remove(state, operationId), throwsStateError);
      expect(await File('${bundlePath()}/disks/root.raw').exists(), isTrue);
    },
  );

  test(
    'a new explicit delete operation resumes the previous operation quarantine',
    () async {
      final quarantine =
          '.deleting-${state.vmId.value}-${plan.operationId.value}';
      await bundles.renameDirectoryNoReplace(
        '${state.vmId.value}.gaovm',
        quarantine,
      );
      final error = OperationError(
        code: ErrorCode.driverUnhealthy,
        message: 'cleanup interruption',
        retryable: true,
        details: JsonObjectValue.empty,
      );
      await SqliteOperationRepository(database).fail(operationId, error: error);
      final failed = reduce(
        state,
        ManagedFilesRemovalFailed(operationId, error),
      ).state;
      await SqliteVmStateEffectAdapter(database).persistVm(failed);
      await SqliteVmStateEffectAdapter(database).persistRuntime(failed);
      final retry = await SqliteVmLifecycleAcceptance(
        database: database,
        idempotencyRetention: const Duration(days: 1),
        command: VmLifecycleCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: state.vmId,
          action: VmLifecycleAction.delete,
        ),
      ).commit(failed);
      final retriedOperation = retry.result.operationId;
      await SqliteOperationRepository(database).start(retriedOperation);
      final retryState = reduce(
        failed.copyWith(appliedIntentRevision: retry.intentRevision),
        DeleteRequested(retriedOperation),
      ).state;
      await SqliteVmStateEffectAdapter(database).persistVm(retryState);
      await SqliteVmStateEffectAdapter(database).persistRuntime(retryState);
      await adapter().remove(retryState, retriedOperation);
      expect(await Directory('${bundles.path}/$quarantine').exists(), isFalse);
    },
  );
}
