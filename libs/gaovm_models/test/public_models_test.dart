import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  const ulid = '01J00000000000000000000000';
  final at = DateTime.utc(2026, 9, 4, 8);

  test('Image round trips with typed manifest JSON', () {
    final image = Image(
      id: ImageId('img_$ulid'),
      digest: 'sha256:${'a' * 64}',
      type: ImageType.gaoosBundle,
      architecture: Architecture.arm64,
      labels: const {'channel': 'nightly'},
      manifest: JsonObjectValue.fromJson({'kernel': 'objects/kernel'}),
      createdAt: at,
    );

    expect(Image.fromJson(image.toJson()), image);
    expect(() => image.labels['x'] = 'y', throwsUnsupportedError);
  });

  test('Operation preserves typed IDs, state, progress, and error', () {
    final operation = Operation(
      id: OperationId('op_$ulid'),
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_$ulid'),
      state: OperationState.failed,
      requestId: RequestId('req_$ulid'),
      cancellable: false,
      progress: OperationProgress(percent: 50, step: 'handshake'),
      request: JsonObjectValue.fromJson({'reason': 'test'}),
      error: OperationError(
        code: ErrorCode.driverStartFailed,
        message: 'driver exited',
        retryable: true,
        details: JsonObjectValue.empty,
      ),
      createdAt: at,
      completedAt: at.add(const Duration(seconds: 2)),
    );

    expect(Operation.fromJson(operation.toJson()), operation);
    expect(operation.resourceId, isA<VmId>());
  });

  test('Operation resource type must match its concrete resource ID', () {
    expect(
      () => Operation(
        id: OperationId('op_$ulid'),
        type: 'vm.start',
        resourceType: ResourceType.image,
        resourceId: VmId('vm_$ulid'),
        state: OperationState.pending,
        requestId: RequestId('req_$ulid'),
        cancellable: true,
        request: JsonObjectValue.empty,
        createdAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('Event resource type must match its concrete resource ID', () {
    expect(
      () => Event(
        sequence: 1,
        eventId: EventId('evt_$ulid'),
        type: 'vm.running',
        resourceType: ResourceType.virtualMachine,
        resourceId: ImageId('img_$ulid'),
        payload: JsonObjectValue.empty,
        occurredAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('Event, TestRun, Artifact, and Problem round trip', () {
    final event = Event(
      sequence: 1,
      eventId: EventId('evt_$ulid'),
      type: 'vm.running',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_$ulid'),
      vmId: VmId('vm_$ulid'),
      operationId: OperationId('op_$ulid'),
      payload: JsonObjectValue.fromJson({'driver_generation': 8}),
      occurredAt: at,
    );
    final step = TestStep(
      index: 0,
      state: TestStepState.succeeded,
      request: TestStepRequest(argv: const ['/bin/true'], timeoutSeconds: 30),
      result: JsonObjectValue.fromJson({'exit_code': 0}),
      startedAt: at,
      completedAt: at,
    );
    final run = TestRun(
      id: TestRunId('tr_$ulid'),
      state: TestRunState.succeeded,
      spec: TestRunSpec(
        source: ImageTestRunSource(ImageId('img_$ulid')),
        wait: VmWaitSpec(
          condition: WaitCondition.guestAgentReady,
          timeoutSeconds: 120,
        ),
        steps: [step.request],
        timeoutSeconds: 900,
        cleanup: CleanupPolicy.deleteOnSuccess,
        retainOnFailure: true,
      ),
      vmId: VmId('vm_$ulid'),
      operationId: OperationId('op_$ulid'),
      steps: [step],
      result: JsonObjectValue.fromJson({'passed': true}),
      artifactIds: [ArtifactId('art_$ulid')],
      createdAt: at,
      completedAt: at,
    );
    final artifact = Artifact(
      id: ArtifactId('art_$ulid'),
      vmId: VmId('vm_$ulid'),
      operationId: OperationId('op_$ulid'),
      testRunId: TestRunId('tr_$ulid'),
      kind: ArtifactKind.result,
      contentType: 'application/json',
      sizeBytes: 2,
      digest: 'sha256:${'b' * 64}',
      downloadUrl: '/v1/artifacts/art_$ulid',
      createdAt: at,
    );
    final problem = Problem(
      type: Uri.parse('https://gaovm.dev/problems/driver-start-failed'),
      title: 'Driver start failed',
      status: 503,
      code: ErrorCode.driverStartFailed,
      detail: 'driver exited',
      requestId: RequestId('req_$ulid'),
      retryable: true,
      operationId: OperationId('op_$ulid'),
      details: JsonObjectValue.empty,
    );

    expect(Event.fromJson(event.toJson()), event);
    final runJson = run.toJson();
    expect(runJson['spec'], run.spec.toJson());
    expect(runJson, isNot(contains('source')));
    expect(runJson, isNot(contains('cleanup')));
    expect(runJson, isNot(contains('retain_on_failure')));
    expect(TestRun.fromJson(runJson), run);
    expect(Artifact.fromJson(artifact.toJson()), artifact);
    expect(Problem.fromJson(problem.toJson()), problem);
  });

  test('persisted TestRun spec retains overrides, wait, and timeout', () {
    final spec = TestRunSpec(
      source: ImageTestRunSource(ImageId('img_$ulid')),
      vmOverrides: VmSpecPatch(
        cpu: 4,
        memoryBytes: 4294967296,
        guestProfile: const PatchField<String?>.present(null),
      ),
      wait: VmWaitSpec(
        condition: WaitCondition.guestAgentReady,
        timeoutSeconds: 120,
      ),
      steps: [
        TestStepRequest(
          argv: const ['gaoos-test', 'network'],
          timeoutSeconds: 600,
        ),
      ],
      timeoutSeconds: 900,
      cleanup: CleanupPolicy.deleteOnSuccess,
      retainOnFailure: true,
    );

    final decoded = TestRunSpec.fromJson(spec.toJson());
    expect(decoded, spec);
    expect(decoded.vmOverrides!.guestProfile.isPresent, isTrue);
    expect(decoded.vmOverrides!.guestProfile.value, isNull);
  });

  test('VmSpecPatch distinguishes a missing field from explicit null', () {
    final missing = VmSpecPatch.fromJson({'cpu': 4});
    final cleared = VmSpecPatch.fromJson({'guest_profile': null});

    expect(missing.guestProfile.isPresent, isFalse);
    expect(cleared.guestProfile.isPresent, isTrue);
    expect(cleared.guestProfile.value, isNull);
  });

  test('reject progress above 100 percent', () {
    expect(() => OperationProgress(percent: 101), throwsArgumentError);
  });

  test('reject negative artifact size', () {
    expect(
      () => Artifact(
        id: ArtifactId('art_$ulid'),
        kind: ArtifactKind.file,
        contentType: 'text/plain',
        sizeBytes: -1,
        digest: 'sha256:${'a' * 64}',
        downloadUrl: '/v1/artifacts/art_$ulid',
        createdAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('reject malformed artifact digest', () {
    expect(
      () => Artifact(
        id: ArtifactId('art_$ulid'),
        kind: ArtifactKind.file,
        contentType: 'text/plain',
        sizeBytes: 0,
        digest: 'not-a-digest',
        downloadUrl: '/v1/artifacts/art_$ulid',
        createdAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('reject malformed artifact download URL', () {
    expect(
      () => Artifact(
        id: ArtifactId('art_$ulid'),
        kind: ArtifactKind.file,
        contentType: 'text/plain',
        sizeBytes: 0,
        digest: 'sha256:${'a' * 64}',
        downloadUrl: '/bad',
        createdAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('reject malformed image label', () {
    expect(
      () => Image(
        id: ImageId('img_$ulid'),
        digest: 'sha256:${'a' * 64}',
        type: ImageType.rawDisk,
        architecture: Architecture.arm64,
        labels: const {'bad label': 'value'},
        manifest: JsonObjectValue.empty,
        createdAt: at,
      ),
      throwsArgumentError,
    );
  });

  test('reject a Problem type outside the GaoVM namespace', () {
    expect(
      () => Problem(
        type: Uri.parse('https://example.com/problem'),
        title: 'Internal error',
        status: 500,
        code: ErrorCode.internalError,
        detail: '',
        requestId: RequestId('req_$ulid'),
        retryable: false,
        details: JsonObjectValue.empty,
      ),
      throwsArgumentError,
    );
  });

  test('reject an empty Problem title', () {
    expect(
      () => Problem(
        type: Uri.parse('https://gaovm.dev/problems/internal-error'),
        title: '',
        status: 500,
        code: ErrorCode.internalError,
        detail: '',
        requestId: RequestId('req_$ulid'),
        retryable: false,
        details: JsonObjectValue.empty,
      ),
      throwsArgumentError,
    );
  });

  test('reject a Problem status outside the HTTP error range', () {
    expect(
      () => Problem(
        type: Uri.parse('https://gaovm.dev/problems/internal-error'),
        title: 'Internal error',
        status: 200,
        code: ErrorCode.internalError,
        detail: '',
        requestId: RequestId('req_$ulid'),
        retryable: false,
        details: JsonObjectValue.empty,
      ),
      throwsArgumentError,
    );
  });

  test('reject NaN numeric input', () {
    expect(() => OperationProgress(percent: double.nan), throwsArgumentError);
  });

  test('reject NaN timeout input', () {
    expect(
      () => TestStepRequest(
        argv: const ['/bin/true'],
        timeoutSeconds: double.nan,
      ),
      throwsArgumentError,
    );
  });

  test('reject infinite numeric input', () {
    expect(
      () => TestStepRequest(
        argv: const ['/bin/true'],
        timeoutSeconds: double.infinity,
      ),
      throwsArgumentError,
    );
  });
}
