import 'package:gaovm_models/gaovm_models.dart';

import 'image_repository.dart';
import 'image_manifest.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_application_service.dart';
import 'vm_create_intent.dart';
import 'vm_provisioning_plan.dart';

/// A per-run dispatch result. An error is an infrastructure failure, not a
/// terminal TestRun outcome; its transaction has rolled back and may retry.
final class TestRunProvisioningOutcome {
  const TestRunProvisioningOutcome({
    required this.testRunId,
    required this.operationId,
    this.vmId,
    this.error,
  });
  final TestRunId testRunId;
  final OperationId operationId;
  final VmId? vmId;
  final Object? error;
}

/// Commits only recoverable VM creation and observes its durable completion.
/// Native VM start, guest execution, artifact collection and cleanup are later
/// phases; no driver or filesystem IO occurs inside this worker's transactions.
final class TestRunProvisioningWorker {
  TestRunProvisioningWorker({required this.database, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunProvisioningOutcome>> dispatchOnce({
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 200) throw RangeError.range(limit, 1, 200);
    if (database.hasActiveCallerTransaction) {
      throw StateError('TestRun provisioning must own its commit boundary');
    }
    final items = await database.read(
      (db) => [
        for (final row in db.select(
          '''
        SELECT t.id, t.operation_id, COALESCE(t.vm_id, p.vm_id) AS vm_id
        FROM test_runs t LEFT JOIN test_run_vm_provisioning p ON p.test_run_id = t.id
        WHERE t.state IN ('pending', 'provisioning') AND t.id > ? ORDER BY t.id LIMIT ?
      ''',
          [_cursor?.value ?? '', limit],
        ))
          (
            id: TestRunId(row['id'] as String),
            operationId: OperationId(row['operation_id'] as String),
            vmId: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
          ),
      ],
    );
    _cursor = items.lastOrNull?.id;
    final results = <TestRunProvisioningOutcome>[];
    for (final item in items) {
      try {
        final run = await _advance(item.id);
        results.add(
          TestRunProvisioningOutcome(
            testRunId: item.id,
            operationId: item.operationId,
            vmId: run.vmId ?? item.vmId,
          ),
        );
      } catch (error) {
        results.add(
          TestRunProvisioningOutcome(
            testRunId: item.id,
            operationId: item.operationId,
            vmId: item.vmId,
            error: error,
          ),
        );
      }
    }
    return List.unmodifiable(results);
  }

  Future<TestRun> _advance(TestRunId id) => database.transaction((db) async {
    final runs = SqliteTestRunRepository(database, now: _now);
    var run = (await runs.get(id))!;
    if (!const {
      TestRunState.pending,
      TestRunState.provisioning,
    }.contains(run.state))
      return run;
    final rows = db.select(
      'SELECT vm_id, operation_id FROM test_run_vm_provisioning WHERE test_run_id = ?',
      [id.value],
    );
    final cancelled =
        db.select('SELECT cancel_requested FROM test_runs WHERE id = ?', [
          id.value,
        ]).single['cancel_requested'] ==
        1;
    final parent = await SqliteOperationRepository(
      database,
    ).get(run.operationId);
    if (parent == null ||
        parent.type != 'test.run' ||
        parent.resourceType != ResourceType.testRun ||
        parent.resourceId != id ||
        parent.state !=
            (run.state == TestRunState.pending
                ? OperationState.pending
                : OperationState.running)) {
      throw StateError('TestRun provisioning operation is not active');
    }
    final expired =
        parent.deadlineAt != null &&
        !_now().toUtc().isBefore(parent.deadlineAt!);
    if (cancelled && rows.isEmpty) {
      return runs.transition(
        id,
        expectedState: run.state,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
    }
    if (expired && rows.isEmpty)
      return _failure(runs, run, ErrorCode.waitTimeout);
    if (run.state == TestRunState.pending) {
      run = await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.provisioning,
      );
    }
    if (run.state != TestRunState.provisioning) return run;
    if (rows.isEmpty) {
      try {
        final source = run.spec.source;
        if (source is! ImageTestRunSource)
          throw const FormatException('image source required');
        final image = await ImageRepository(database).get(source.imageId);
        if (image == null) throw ImageNotFound(source.imageId);
        final manifest = ImageManifest.fromJson(image.manifest.toJson());
        final profile = image.type == ImageType.gaoosBundle
            ? manifest.toJson()['gaoos'] as Map
            : null;
        final boot =
            run.spec.vmOverrides?.boot ??
            switch (image.type) {
              ImageType.gaoosBundle || ImageType.linuxKernel => LinuxKernelBoot(
                kernelImageId: image.id,
                initrdImageId: profile == null ? null : image.id,
                commandLine: profile?['default_command_line'] as String? ?? '',
              ),
              _ => throw const FormatException(
                'this image requires a boot override',
              ),
            };
        final base = VmSpec(
          architecture: image.architecture,
          guestProfile: image.guestProfile,
          cpu: 2,
          memoryBytes: 2 * 1024 * 1024 * 1024,
          boot: boot,
          disks: [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(image.id),
              writable: true,
            ),
          ],
          networks: [SharedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: const SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(
            enabled:
                profile?['guest_agent_expected'] == true ||
                run.spec.wait.condition != WaitCondition.runtimeRunning,
            requiredForReady:
                run.spec.wait.condition != WaitCondition.runtimeRunning,
          ),
          restartPolicy: RestartPolicy.never,
        );
        final spec = VmSpec.fromJson({
          ...base.toJson(),
          ...?run.spec.vmOverrides?.toJson(),
        });
        if (spec.autostart) {
          throw const FormatException(
            'TestRuns require explicit lifecycle orchestration',
          );
        }
        final accepted = await commitVmCreateIntent(
          database: database,
          command: VmCreateCommand(
            requestId: parent.requestId,
            idempotencyKey: null,
            requestBody: const [],
            name: 'test-${id.value}',
            labels: {'gaovm.test-run': id.value},
            spec: spec,
          ),
          now: _now,
        );
        db.execute(
          'INSERT INTO test_run_vm_provisioning(test_run_id, vm_id, operation_id) VALUES (?, ?, ?)',
          [id.value, accepted.resourceId.value, accepted.operationId.value],
        );
        return run;
      } on FormatException {
        return _failure(runs, run, ErrorCode.vmSpecInvalid);
      } on ArgumentError {
        return _failure(runs, run, ErrorCode.vmSpecInvalid);
      } on ImageNotFound {
        return _failure(runs, run, ErrorCode.imageNotFound);
      } on VmProvisioningImageNotFoundException {
        return _failure(runs, run, ErrorCode.imageNotFound);
      }
    }
    final child = (await SqliteOperationRepository(
      database,
    ).get(OperationId(rows.single['operation_id'] as String)))!;
    final vmId = VmId(rows.single['vm_id'] as String);
    if (child.type != 'vm.create' ||
        child.resourceType != ResourceType.virtualMachine ||
        child.resourceId != vmId) {
      throw StateError('TestRun provisioning child operation is mismatched');
    }
    if (const {
      OperationState.pending,
      OperationState.running,
    }.contains(child.state))
      return run;
    if (child.state != OperationState.succeeded &&
        !(child.state == OperationState.cancelled && cancelled)) {
      return _failure(
        runs,
        run,
        child.error?.code ?? ErrorCode.internalError,
        vmId: vmId,
        child: child,
      );
    }
    if (expired && !cancelled)
      return _failure(runs, run, ErrorCode.waitTimeout, vmId: vmId);
    return runs.transition(
      id,
      expectedState: TestRunState.provisioning,
      nextState: cancelled ? TestRunState.collecting : TestRunState.startingVm,
      outcome: cancelled ? TestRunState.cancelled : null,
      vmId: vmId,
    );
  });

  Future<TestRun> _failure(
    SqliteTestRunRepository runs,
    TestRun run,
    ErrorCode code, {
    VmId? vmId,
    Operation? child,
  }) => runs.transition(
    run.id,
    expectedState: run.state,
    nextState: TestRunState.collecting,
    outcome: TestRunState.failed,
    vmId: vmId,
    error: OperationError(
      code: code,
      message:
          child?.error?.message ??
          (code == ErrorCode.waitTimeout
              ? 'The TestRun provisioning deadline expired.'
              : 'Unable to provision the TestRun VM.'),
      retryable: child?.error?.retryable ?? false,
      details: JsonObjectValue.fromJson({
        'phase': 'provisioning',
        if (vmId != null) 'vm_id': vmId.value,
        if (child != null) 'provisioning_operation_id': child.id.value,
        if (child?.error != null) 'cause': child!.error!.toJson(),
      }),
    ),
  );
}
