import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/host_lease_repository.dart';
import 'package:gaovmd/src/host_scheduler_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late GaoVmDatabase database;
  late SqliteHostLeaseRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-host-leases-',
    );
    database = await GaoVmDatabase.open('${temporaryDirectory.path}/gaovm.db');
    repository = SqliteHostLeaseRepository(database);
  });

  tearDown(() async {
    database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'atomic admission permits only one concurrent lease at capacity',
    () async {
      final decisions = await Future.wait([
        repository.acquire(
          request: _request(_vm1),
          limits: _limits(maxRunningVms: 1),
          metrics: _metrics,
          ownerId: 'daemon-a',
          now: _now,
          ttl: const Duration(seconds: 30),
        ),
        repository.acquire(
          request: _request(_vm2),
          limits: _limits(maxRunningVms: 1),
          metrics: _metrics,
          ownerId: 'daemon-a',
          now: _now,
          ttl: const Duration(seconds: 30),
        ),
      ]);

      expect(decisions.where((decision) => decision.admitted), hasLength(1));
      final rejected = decisions.singleWhere((decision) => !decision.admitted);
      expect(rejected.error?.code, ErrorCode.hostResourceExhausted);
      expect(rejected.error?.retryable, isTrue);
      expect(rejected.constraint, 'max_running_vms');
      expect(await repository.list(activeAt: _now), hasLength(1));
    },
  );

  test('all MVP capacity limits return stable retryable decisions', () async {
    final cases =
        <
          ({
            String constraint,
            HostSchedulerLimits limits,
            HostMetrics metrics,
            HostCapacityRequest request,
          })
        >[
          (
            constraint: 'max_concurrent_boots',
            limits: _limits(maxConcurrentBoots: 1),
            metrics: _metrics,
            request: _request(_vm2),
          ),
          (
            constraint: 'max_driver_processes',
            limits: _limits(maxDriverProcesses: 1),
            metrics: _metrics,
            request: _request(_vm2),
          ),
          (
            constraint: 'cpu_budget',
            limits: _limits(maxCpuCount: 2),
            metrics: _metrics,
            request: _request(_vm2),
          ),
          (
            constraint: 'memory_budget',
            limits: _limits(maxMemoryBytes: 1024),
            metrics: _metrics,
            request: _request(_vm2),
          ),
          (
            constraint: 'host_available_memory',
            limits: _limits(),
            metrics: _metrics.copyWith(availableMemoryBytes: 512),
            request: _request(_vm2, memoryBytes: 1024),
          ),
          (
            constraint: 'min_free_disk',
            limits: _limits(minFreeDiskBytes: 900),
            metrics: _metrics.copyWith(freeDiskBytes: 899),
            request: _request(_vm2, diskBytes: 0),
          ),
        ];

    for (final testCase in cases) {
      await repository.recover(
        requests: [_request(_vm1)],
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'seed',
        now: _now,
        ttl: const Duration(seconds: 30),
      );
      final decision = await repository.acquire(
        request: testCase.request,
        limits: testCase.limits,
        metrics: testCase.metrics,
        ownerId: 'daemon-a',
        now: _now,
        ttl: const Duration(seconds: 30),
      );
      expect(decision.admitted, isFalse, reason: testCase.constraint);
      expect(decision.constraint, testCase.constraint);
      expect(decision.error?.code, ErrorCode.hostResourceExhausted);
      expect(decision.error?.retryable, isTrue);
      await repository.recover(
        requests: const [],
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'cleanup',
        now: _now,
        ttl: const Duration(seconds: 30),
      );
    }
  });

  test(
    'acquire release renew and running transition are owner scoped and idempotent',
    () async {
      final first = await repository.acquire(
        request: _request(_vm1),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now,
        ttl: const Duration(seconds: 30),
      );
      final repeated = await repository.acquire(
        request: _request(_vm1),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now.add(const Duration(seconds: 1)),
        ttl: const Duration(seconds: 30),
      );
      final foreign = await repository.acquire(
        request: _request(_vm1),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-b',
        now: _now,
        ttl: const Duration(seconds: 30),
      );

      expect(first.admitted, isTrue);
      expect(repeated.lease?.request, first.lease?.request);
      expect(repeated.lease?.acquiredAt, first.lease?.acquiredAt);
      expect(repeated.lease?.expiresAt, _now.add(const Duration(seconds: 31)));
      expect(foreign.admitted, isFalse);
      expect(foreign.constraint, 'lease_owner');
      expect(
        await repository.markRunning(
          _vm1,
          ownerId: 'daemon-b',
          operationId: _operation1,
          now: _now,
        ),
        isFalse,
      );
      expect(
        await repository.markRunning(
          _vm1,
          ownerId: 'daemon-a',
          operationId: _operation1,
          now: _now,
        ),
        isTrue,
      );
      expect(
        await repository.renew(
          _vm1,
          ownerId: 'daemon-a',
          operationId: _operation1,
          now: _now,
          ttl: const Duration(minutes: 1),
        ),
        isTrue,
      );
      expect(await repository.release(_vm1, ownerId: 'daemon-b'), isFalse);
      expect(await repository.release(_vm1, ownerId: 'daemon-a'), isTrue);
      expect(await repository.release(_vm1, ownerId: 'daemon-a'), isTrue);
    },
  );

  test(
    'expired leases can be acquired and recovery takes over in catalog order',
    () async {
      await repository.acquire(
        request: _request(_vm3),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'old-daemon',
        now: _now.subtract(const Duration(minutes: 2)),
        ttl: const Duration(seconds: 10),
      );

      final decisions = await repository.recover(
        requests: [_request(_vm2), _request(_vm1)],
        limits: _limits(maxRunningVms: 1),
        metrics: _metrics,
        ownerId: 'new-daemon',
        now: _now,
        ttl: const Duration(seconds: 30),
      );

      expect(decisions.map((decision) => decision.request.vmId), [_vm1, _vm2]);
      expect(decisions.first.admitted, isTrue);
      expect(decisions.last.constraint, 'max_running_vms');
      final active = await repository.list(activeAt: _now);
      expect(active.map((lease) => lease.request.vmId), [_vm1]);
      expect(active.single.ownerId, 'new-daemon');
    },
  );

  test('lease payload and ownership survive database reopen', () async {
    await repository.acquire(
      request: _request(_vm1, diskBytes: 4096),
      limits: _limits(),
      metrics: _metrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    final path = '${temporaryDirectory.path}/gaovm.db';
    database.close();
    database = await GaoVmDatabase.open(path);
    repository = SqliteHostLeaseRepository(database);

    final lease = (await repository.list(activeAt: _now)).single;
    expect(lease.request.diskBytes, 4096);
    expect(lease.ownerId, 'daemon-a');
    expect(lease.expiresAt, _now.add(const Duration(minutes: 1)));
  });

  test(
    'expired leases cannot transition or renew and are never resurrected',
    () async {
      for (final vmId in [_vm1, _vm2]) {
        await repository.acquire(
          request: _request(vmId),
          limits: _limits(),
          metrics: _metrics,
          ownerId: 'daemon-a',
          now: _now,
          ttl: const Duration(seconds: 10),
        );
      }
      final expiredAt = _now.add(const Duration(seconds: 11));

      expect(
        await repository.markRunning(
          _vm1,
          ownerId: 'daemon-a',
          operationId: _operation1,
          now: expiredAt,
        ),
        isFalse,
      );
      expect(
        await repository.renew(
          _vm2,
          ownerId: 'daemon-a',
          operationId: _operation1,
          now: expiredAt,
          ttl: const Duration(minutes: 1),
        ),
        isFalse,
      );
      expect(await repository.list(activeAt: expiredAt), isEmpty);
      expect(await repository.list(), hasLength(2));
    },
  );

  test(
    'same-owner changed request is re-admitted and replaces stale accounting',
    () async {
      await repository.acquire(
        request: _request(_vm1),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now,
        ttl: const Duration(minutes: 1),
      );
      final replacement = HostCapacityRequest(
        vmId: _vm1,
        cpuCount: 4,
        memoryBytes: 2048,
        diskBytes: 4096,
        phase: HostLeasePhase.booting,
        specGeneration: 2,
        operationId: _operation2,
      );

      final replaced = await repository.acquire(
        request: replacement,
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now.add(const Duration(seconds: 1)),
        ttl: const Duration(minutes: 1),
      );
      expect(replaced.admitted, isTrue);
      expect((await repository.list()).single.request, replacement);

      final rejected = await repository.acquire(
        request: HostCapacityRequest(
          vmId: _vm1,
          cpuCount: 65,
          memoryBytes: 2048,
          diskBytes: 4096,
          phase: HostLeasePhase.booting,
          specGeneration: 3,
          operationId: _operation3,
        ),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now.add(const Duration(seconds: 2)),
        ttl: const Duration(minutes: 1),
      );
      expect(rejected.constraint, 'cpu_budget');
      expect((await repository.list()).single.request, replacement);
    },
  );

  test(
    'same-generation operation changes are fenced without lexical ordering',
    () async {
      final lexicallyHigh = OperationId('op_01J0000000000000000000000Z');
      final lexicallyLow = OperationId('op_01J00000000000000000000000');
      final current = _request(_vm1).copyWith(operationId: lexicallyHigh);
      await repository.acquire(
        request: current,
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now,
        ttl: const Duration(minutes: 1),
      );

      final decision = await repository.acquire(
        request: _request(_vm1).copyWith(operationId: lexicallyLow),
        limits: _limits(),
        metrics: _metrics,
        ownerId: 'daemon-a',
        now: _now.add(const Duration(seconds: 1)),
        ttl: const Duration(minutes: 1),
      );

      expect(decision.constraint, 'lease_fence');
      expect((await repository.list()).single.request, current);
    },
  );

  test('duplicate booting acquire cannot downgrade a running lease', () async {
    final request = _request(_vm1);
    await repository.acquire(
      request: request,
      limits: _limits(),
      metrics: _metrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    await repository.markRunning(
      _vm1,
      ownerId: 'daemon-a',
      operationId: _operation1,
      now: _now,
    );

    final repeated = await repository.acquire(
      request: request,
      limits: _limits(),
      metrics: _metrics,
      ownerId: 'daemon-a',
      now: _now.add(const Duration(seconds: 30)),
      ttl: const Duration(minutes: 1),
    );

    expect(repeated.admitted, isTrue);
    expect(repeated.lease?.request.phase, HostLeasePhase.running);
    expect(
      (await repository.list()).single.request.phase,
      HostLeasePhase.running,
    );
  });

  test('admission reserves cumulative boot memory and disk headroom', () async {
    final constrainedMetrics = _metrics.copyWith(
      availableMemoryBytes: 1500,
      freeDiskBytes: 1000,
    );
    await repository.acquire(
      request: _request(_vm1, memoryBytes: 800),
      limits: _limits(),
      metrics: constrainedMetrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    final memoryRejected = await repository.acquire(
      request: _request(_vm2, memoryBytes: 800),
      limits: _limits(),
      metrics: constrainedMetrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    expect(memoryRejected.constraint, 'host_available_memory');

    await repository.recover(
      requests: const [],
      limits: _limits(),
      metrics: _metrics,
      ownerId: 'cleanup',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    final diskMetrics = constrainedMetrics.copyWith(
      availableMemoryBytes: 1 << 30,
    );
    await repository.acquire(
      request: _request(_vm1, diskBytes: 600),
      limits: _limits(minFreeDiskBytes: 100),
      metrics: diskMetrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    final diskRejected = await repository.acquire(
      request: _request(_vm2, diskBytes: 400),
      limits: _limits(minFreeDiskBytes: 100),
      metrics: diskMetrics,
      ownerId: 'daemon-a',
      now: _now,
      ttl: const Duration(minutes: 1),
    );
    expect(diskRejected.constraint, 'min_free_disk');
  });
}

HostCapacityRequest _request(
  VmId vmId, {
  int memoryBytes = 1024,
  int diskBytes = 0,
}) => HostCapacityRequest(
  vmId: vmId,
  cpuCount: 2,
  memoryBytes: memoryBytes,
  diskBytes: diskBytes,
  phase: HostLeasePhase.booting,
  specGeneration: 1,
  operationId: _operation1,
);

HostSchedulerLimits _limits({
  int maxRunningVms = 8,
  int maxConcurrentBoots = 8,
  int maxDriverProcesses = 8,
  int maxCpuCount = 64,
  int maxMemoryBytes = 1 << 30,
  int minFreeDiskBytes = 0,
}) => HostSchedulerLimits(
  maxRunningVms: maxRunningVms,
  maxConcurrentBoots: maxConcurrentBoots,
  maxDriverProcesses: maxDriverProcesses,
  maxCpuCount: maxCpuCount,
  maxMemoryBytes: maxMemoryBytes,
  minFreeDiskBytes: minFreeDiskBytes,
);

const _metrics = HostMetrics(
  logicalCpuCount: 64,
  totalMemoryBytes: 1 << 30,
  availableMemoryBytes: 1 << 30,
  freeDiskBytes: 1 << 30,
  unmanagedDriverProcesses: 0,
);
final _now = DateTime.utc(2026, 9, 4, 10);
final _vm1 = VmId('vm_01J00000000000000000000000');
final _vm2 = VmId('vm_01J00000000000000000000001');
final _vm3 = VmId('vm_01J00000000000000000000002');
final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');
final _operation3 = OperationId('op_01J00000000000000000000002');
