import 'common.dart';
import 'json_value.dart';
import 'operation.dart';
import 'resource_id.dart';
import 'vm.dart';

sealed class TestRunSource extends ValueObject {
  const TestRunSource();

  factory TestRunSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'TestRun source');
    if (json.containsKey('image_id')) return ImageTestRunSource.fromJson(json);
    if (json.containsKey('template_vm_id')) {
      return TemplateVmTestRunSource.fromJson(json);
    }
    throw FormatException(
      'TestRun source must identify an image or template VM',
    );
  }

  Map<String, Object?> toJson();
}

final class ImageTestRunSource extends TestRunSource {
  const ImageTestRunSource(this.imageId);

  factory ImageTestRunSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'image TestRun source');
    expectJsonKeys(
      json,
      required: const {'image_id'},
      optional: const {},
      name: 'image TestRun source',
    );
    return ImageTestRunSource(ImageId(requireJson<String>(json, 'image_id')));
  }

  final ImageId imageId;

  @override
  Map<String, Object?> toJson() => {'image_id': imageId.value};

  @override
  List<Object?> get equalityFields => [imageId];
}

final class TemplateVmTestRunSource extends TestRunSource {
  const TemplateVmTestRunSource(this.templateVmId);

  factory TemplateVmTestRunSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'template TestRun source');
    expectJsonKeys(
      json,
      required: const {'template_vm_id'},
      optional: const {},
      name: 'template TestRun source',
    );
    return TemplateVmTestRunSource(
      VmId(requireJson<String>(json, 'template_vm_id')),
    );
  }

  final VmId templateVmId;

  @override
  Map<String, Object?> toJson() => {'template_vm_id': templateVmId.value};

  @override
  List<Object?> get equalityFields => [templateVmId];
}

enum WaitCondition { runtimeRunning, guestAgentReady, guestServiceReady }

WaitCondition _parseWaitCondition(Object? value) => switch (value) {
  'runtime_running' => WaitCondition.runtimeRunning,
  'guest_agent_ready' => WaitCondition.guestAgentReady,
  'guest_service_ready' => WaitCondition.guestServiceReady,
  _ => throw FormatException('unsupported wait condition: $value'),
};

String _waitConditionToJson(WaitCondition value) => switch (value) {
  WaitCondition.runtimeRunning => 'runtime_running',
  WaitCondition.guestAgentReady => 'guest_agent_ready',
  WaitCondition.guestServiceReady => 'guest_service_ready',
};

final class VmWaitSpec extends ValueObject {
  VmWaitSpec({
    required this.condition,
    this.serviceName,
    required this.timeoutSeconds,
  }) {
    if (!timeoutSeconds.isFinite ||
        timeoutSeconds <= 0 ||
        timeoutSeconds > 86400) {
      throw ArgumentError.value(
        timeoutSeconds,
        'timeoutSeconds',
        'must be finite, greater than 0, and at most 86400',
      );
    }
    if (serviceName != null) requireNonEmpty(serviceName!, 'serviceName');
    if (condition == WaitCondition.guestServiceReady && serviceName == null) {
      throw ArgumentError('guest_service_ready requires serviceName');
    }
  }

  factory VmWaitSpec.fromJson(Object? value) {
    final json = readJsonObject(value, 'VM wait specification');
    expectJsonKeys(
      json,
      required: const {'condition', 'timeout_seconds'},
      optional: const {'service_name'},
      name: 'VM wait specification',
    );
    return VmWaitSpec(
      condition: _parseWaitCondition(json['condition']),
      serviceName: optionalJson<String>(json, 'service_name'),
      timeoutSeconds: requireJson<num>(json, 'timeout_seconds'),
    );
  }

  final WaitCondition condition;
  final String? serviceName;
  final num timeoutSeconds;

  Map<String, Object?> toJson() => {
    'condition': _waitConditionToJson(condition),
    if (serviceName != null) 'service_name': serviceName,
    'timeout_seconds': timeoutSeconds,
  };

  @override
  List<Object?> get equalityFields => [condition, serviceName, timeoutSeconds];
}

final class TestRunSpec extends ValueObject {
  TestRunSpec({
    required this.source,
    this.vmOverrides,
    required this.wait,
    required Iterable<TestStepRequest> steps,
    this.timeoutSeconds,
    required this.cleanup,
    required this.retainOnFailure,
  }) : steps = List<TestStepRequest>.unmodifiable(steps) {
    if (this.steps.isEmpty || this.steps.length > 256) {
      throw ArgumentError.value(
        this.steps,
        'steps',
        'must contain 1 to 256 steps',
      );
    }
    if (timeoutSeconds != null &&
        (!timeoutSeconds!.isFinite ||
            timeoutSeconds! <= 0 ||
            timeoutSeconds! > 172800)) {
      throw ArgumentError.value(
        timeoutSeconds,
        'timeoutSeconds',
        'must be finite, greater than 0, and at most 172800',
      );
    }
  }

  factory TestRunSpec.fromJson(Object? value) {
    final json = readJsonObject(value, 'TestRun specification');
    expectJsonKeys(
      json,
      required: const {
        'source',
        'wait',
        'steps',
        'cleanup',
        'retain_on_failure',
      },
      optional: const {'vm_overrides', 'timeout_seconds'},
      name: 'TestRun specification',
    );
    return TestRunSpec(
      source: TestRunSource.fromJson(json['source']),
      vmOverrides: json.containsKey('vm_overrides')
          ? VmSpecPatch.fromJson(json['vm_overrides'])
          : null,
      wait: VmWaitSpec.fromJson(json['wait']),
      steps: readJsonList(json['steps'], 'steps', TestStepRequest.fromJson),
      timeoutSeconds: optionalJson<num>(json, 'timeout_seconds'),
      cleanup: _parseCleanupPolicy(json['cleanup']),
      retainOnFailure: requireJson<bool>(json, 'retain_on_failure'),
    );
  }

  final TestRunSource source;
  final VmSpecPatch? vmOverrides;
  final VmWaitSpec wait;
  final List<TestStepRequest> steps;
  final num? timeoutSeconds;
  final CleanupPolicy cleanup;
  final bool retainOnFailure;

  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    if (vmOverrides != null) 'vm_overrides': vmOverrides!.toJson(),
    'wait': wait.toJson(),
    'steps': steps.map((step) => step.toJson()).toList(),
    if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
    'cleanup': _cleanupPolicyToJson(cleanup),
    'retain_on_failure': retainOnFailure,
  };

  @override
  List<Object?> get equalityFields => [
    source,
    vmOverrides,
    wait,
    steps,
    timeoutSeconds,
    cleanup,
    retainOnFailure,
  ];
}

enum TestStepState { pending, running, succeeded, failed, cancelled, skipped }

TestStepState _parseStepState(Object? value) => switch (value) {
  'pending' => TestStepState.pending,
  'running' => TestStepState.running,
  'succeeded' => TestStepState.succeeded,
  'failed' => TestStepState.failed,
  'cancelled' => TestStepState.cancelled,
  'skipped' => TestStepState.skipped,
  _ => throw FormatException('unsupported test step state: $value'),
};

final class TestStepRequest extends ValueObject {
  TestStepRequest({
    this.name,
    required Iterable<String> argv,
    this.cwd = '/',
    Map<String, String> env = const {},
    required this.timeoutSeconds,
  }) : argv = List<String>.unmodifiable(argv),
       env = immutableStringMap(env) {
    if (name != null) {
      requireNonEmpty(name!, 'name');
      if (name!.length > 128) {
        throw ArgumentError.value(name, 'name', 'is too long');
      }
    }
    if (this.argv.isEmpty) {
      throw ArgumentError.value(this.argv, 'argv', 'must not be empty');
    }
    if (!timeoutSeconds.isFinite ||
        timeoutSeconds <= 0 ||
        timeoutSeconds > 86400) {
      throw ArgumentError.value(
        timeoutSeconds,
        'timeoutSeconds',
        'must be greater than 0 and at most 86400',
      );
    }
  }

  factory TestStepRequest.fromJson(Object? value) {
    final json = readJsonObject(value, 'TestStep request');
    expectJsonKeys(
      json,
      required: const {'type', 'argv', 'timeout_seconds'},
      optional: const {'name', 'cwd', 'env'},
      name: 'TestStep request',
    );
    if (json['type'] != 'guest.exec') {
      throw FormatException('TestStep request type must be guest.exec');
    }
    return TestStepRequest(
      name: optionalJson<String>(json, 'name'),
      argv: readJsonList(
        json['argv'],
        'argv',
        (value) => value is String
            ? value
            : throw FormatException('argv items must be strings'),
      ),
      cwd: optionalJson<String>(json, 'cwd') ?? '/',
      env: json.containsKey('env')
          ? readStringMap(json['env'], 'env')
          : const {},
      timeoutSeconds: requireJson<num>(json, 'timeout_seconds'),
    );
  }

  final String? name;
  final List<String> argv;
  final String cwd;
  final Map<String, String> env;
  final num timeoutSeconds;

  Map<String, Object?> toJson() => {
    'type': 'guest.exec',
    if (name != null) 'name': name,
    'argv': List<String>.of(argv),
    'cwd': cwd,
    'env': Map<String, String>.of(env),
    'timeout_seconds': timeoutSeconds,
  };

  @override
  List<Object?> get equalityFields => [name, argv, cwd, env, timeoutSeconds];
}

final class TestStep extends ValueObject {
  TestStep({
    required this.index,
    required this.state,
    required this.request,
    this.result,
    this.error,
    DateTime? startedAt,
    DateTime? completedAt,
  }) : startedAt = startedAt?.toUtc(),
       completedAt = completedAt?.toUtc() {
    if (index < 0) {
      throw ArgumentError.value(index, 'index', 'must not be negative');
    }
  }

  factory TestStep.fromJson(Object? value) {
    final json = readJsonObject(value, 'TestStep');
    expectJsonKeys(
      json,
      required: const {
        'index',
        'state',
        'request',
        'result',
        'error',
        'started_at',
        'completed_at',
      },
      optional: const {},
      name: 'TestStep',
    );
    return TestStep(
      index: requireJson<int>(json, 'index'),
      state: _parseStepState(json['state']),
      request: TestStepRequest.fromJson(json['request']),
      result: json['result'] == null
          ? null
          : JsonObjectValue.fromJson(json['result']),
      error: json['error'] == null
          ? null
          : OperationError.fromJson(json['error']),
      startedAt: nullableDateTime(json, 'started_at'),
      completedAt: nullableDateTime(json, 'completed_at'),
    );
  }

  final int index;
  final TestStepState state;
  final TestStepRequest request;
  final JsonObjectValue? result;
  final OperationError? error;
  final DateTime? startedAt;
  final DateTime? completedAt;

  Map<String, Object?> toJson() => {
    'index': index,
    'state': state.name,
    'request': request.toJson(),
    'result': result?.toJson(),
    'error': error?.toJson(),
    'started_at': startedAt == null ? null : formatDateTime(startedAt!),
    'completed_at': completedAt == null ? null : formatDateTime(completedAt!),
  };

  @override
  List<Object?> get equalityFields => [
    index,
    state,
    request,
    result,
    error,
    startedAt,
    completedAt,
  ];
}

enum TestRunState {
  pending,
  provisioning,
  startingVm,
  waitingReady,
  runningSteps,
  collecting,
  cleaningUp,
  succeeded,
  failed,
  cancelled,
}

TestRunState _parseTestRunState(Object? value) => switch (value) {
  'pending' => TestRunState.pending,
  'provisioning' => TestRunState.provisioning,
  'starting_vm' => TestRunState.startingVm,
  'waiting_ready' => TestRunState.waitingReady,
  'running_steps' => TestRunState.runningSteps,
  'collecting' => TestRunState.collecting,
  'cleaning_up' => TestRunState.cleaningUp,
  'succeeded' => TestRunState.succeeded,
  'failed' => TestRunState.failed,
  'cancelled' => TestRunState.cancelled,
  _ => throw FormatException('unsupported TestRun state: $value'),
};

String _testRunStateToJson(TestRunState value) => switch (value) {
  TestRunState.startingVm => 'starting_vm',
  TestRunState.waitingReady => 'waiting_ready',
  TestRunState.runningSteps => 'running_steps',
  TestRunState.cleaningUp => 'cleaning_up',
  _ => value.name,
};

enum CleanupPolicy { deleteOnSuccess, alwaysDelete, retain }

CleanupPolicy _parseCleanupPolicy(Object? value) => switch (value) {
  'delete_on_success' => CleanupPolicy.deleteOnSuccess,
  'always_delete' => CleanupPolicy.alwaysDelete,
  'retain' => CleanupPolicy.retain,
  _ => throw FormatException('unsupported cleanup policy: $value'),
};

String _cleanupPolicyToJson(CleanupPolicy value) => switch (value) {
  CleanupPolicy.deleteOnSuccess => 'delete_on_success',
  CleanupPolicy.alwaysDelete => 'always_delete',
  CleanupPolicy.retain => 'retain',
};

final class TestRun extends ValueObject {
  TestRun({
    required this.id,
    required this.state,
    required this.spec,
    this.vmId,
    required this.operationId,
    required Iterable<TestStep> steps,
    this.cleanupDecision,
    this.result,
    this.error,
    Iterable<ArtifactId> artifactIds = const [],
    required DateTime createdAt,
    DateTime? completedAt,
  }) : steps = List<TestStep>.unmodifiable(steps),
       artifactIds = List<ArtifactId>.unmodifiable(artifactIds),
       createdAt = createdAt.toUtc(),
       completedAt = completedAt?.toUtc();

  factory TestRun.fromJson(Object? value) {
    final json = readJsonObject(value, 'TestRun');
    expectJsonKeys(
      json,
      required: const {
        'id',
        'state',
        'spec',
        'vm_id',
        'operation_id',
        'steps',
        'result',
        'error',
        'artifact_ids',
        'created_at',
        'completed_at',
      },
      optional: const {'cleanup_decision'},
      name: 'TestRun',
    );
    final vmId = nullableJson<String>(json, 'vm_id');
    return TestRun(
      id: TestRunId(requireJson<String>(json, 'id')),
      state: _parseTestRunState(json['state']),
      spec: TestRunSpec.fromJson(json['spec']),
      vmId: vmId == null ? null : VmId(vmId),
      operationId: OperationId(requireJson<String>(json, 'operation_id')),
      steps: readJsonList(json['steps'], 'steps', TestStep.fromJson),
      cleanupDecision: nullableJson<String>(json, 'cleanup_decision'),
      result: json['result'] == null
          ? null
          : JsonObjectValue.fromJson(json['result']),
      error: json['error'] == null
          ? null
          : OperationError.fromJson(json['error']),
      artifactIds: readJsonList(
        json['artifact_ids'],
        'artifact_ids',
        (value) => ArtifactId(
          value is String
              ? value
              : throw FormatException('artifact ID must be a string'),
        ),
      ),
      createdAt: requireDateTime(json, 'created_at'),
      completedAt: nullableDateTime(json, 'completed_at'),
    );
  }

  final TestRunId id;
  final TestRunState state;
  final TestRunSpec spec;
  final VmId? vmId;
  final OperationId operationId;
  final List<TestStep> steps;
  final String? cleanupDecision;
  final JsonObjectValue? result;
  final OperationError? error;
  final List<ArtifactId> artifactIds;
  final DateTime createdAt;
  final DateTime? completedAt;

  Map<String, Object?> toJson() => {
    'id': id.value,
    'state': _testRunStateToJson(state),
    'spec': spec.toJson(),
    'vm_id': vmId?.value,
    'operation_id': operationId.value,
    'steps': steps.map((step) => step.toJson()).toList(),
    'cleanup_decision': cleanupDecision,
    'result': result?.toJson(),
    'error': error?.toJson(),
    'artifact_ids': artifactIds.map((id) => id.value).toList(),
    'created_at': formatDateTime(createdAt),
    'completed_at': completedAt == null ? null : formatDateTime(completedAt!),
  };

  @override
  List<Object?> get equalityFields => [
    id,
    state,
    spec,
    vmId,
    operationId,
    steps,
    cleanupDecision,
    result,
    error,
    artifactIds,
    createdAt,
    completedAt,
  ];
}
