import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late _Catalog catalog;
  late VmRegistry registry;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-reconcile-loop-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    catalog = _Catalog(SqliteVmRepository(database));
    registry = VmRegistry(
      repository: catalog,
      operations: SqliteOperationRepository(database),
      effectRunner: _NoEffects(),
      recovery: SqliteVmIntentRecoveryRepository(database),
    );
  });
  tearDown(() async {
    await registry.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  test('rejects nonpositive intervals', () {
    for (final interval in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => VmReconcileLoop(
          registry: registry,
          interval: interval,
          onVmError: (_, _, _) {},
          onError: (_, _) {},
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'starts immediately once and schedules five-second safety ticks',
    () async {
      final scheduler = _Scheduler();
      final loop = VmReconcileLoop(
        registry: registry,
        scheduler: scheduler,
        onVmError: (_, error, _) => fail('$error'),
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        loop.start();
        await scheduler.scheduled.future;
        expect(catalog.scans, 1);
        expect(scheduler.handles.single.delay, const Duration(seconds: 5));
        scheduler.fire();
        await scheduler.scheduled.future;
        expect(catalog.scans, 2);
        expect(scheduler.activeCount, 1);
      } finally {
        await loop.close();
      }
      expect(scheduler.activeCount, 0);
      scheduler.fire();
      expect(catalog.scans, 2);
      expect(loop.start, throwsStateError);
      await loop.close();
    },
  );

  test(
    'blocked scans never overlap and close drains the current scan',
    () async {
      final release = Completer<void>();
      catalog.beforeList = () => release.future;
      final scheduler = _Scheduler();
      final loop = VmReconcileLoop(
        registry: registry,
        scheduler: scheduler,
        onVmError: (_, error, _) => fail('$error'),
        onError: (error, _) => fail('$error'),
      );
      loop.start();
      loop.start();
      scheduler.fire();
      expect(catalog.scans, 1);
      expect(scheduler.activeCount, 0);
      var closed = false;
      final close = loop.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await close;
      expect(scheduler.activeCount, 0);
      expect(catalog.scans, 1);
    },
  );

  test(
    'closing with registry shutdown drains an interrupted catalog scan',
    () async {
      final release = Completer<void>();
      catalog.beforeList = () => release.future;
      final scheduler = _Scheduler();
      final loop = VmReconcileLoop(
        registry: registry,
        scheduler: scheduler,
        onVmError: (_, error, _) => fail('$error'),
        onError: (error, _) => fail('$error'),
      );
      loop.start();
      final close = loop.close();
      final shutdown = registry.shutdown();
      release.complete();
      await Future.wait([close, shutdown]);
      expect(scheduler.activeCount, 0);
      expect(registry.activeCount, 0);
    },
  );

  test(
    'ticks continue while a VM effect is blocked and shutdown cancels it',
    () async {
      final vm = await catalog.delegate.create(name: 'slow', spec: _spec);
      await registry.shutdown();
      final runner = _BlockedEffects();
      registry = VmRegistry(
        repository: catalog,
        operations: SqliteOperationRepository(database),
        effectRunner: runner,
      );
      final controller = (await registry.get(vm.metadata.id))!;
      final command = controller.submit(StartRequested(OperationId.generate()));
      await runner.entered.future;
      final scheduler = _Scheduler();
      final loop = VmReconcileLoop(
        registry: registry,
        scheduler: scheduler,
        onVmError: (_, error, _) => fail('$error'),
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        await scheduler.scheduled.future;
        scheduler.fire();
        await scheduler.scheduled.future;
        expect(catalog.scans, 2);
        expect(runner.release.isCompleted, isFalse);
        await Future.wait([
          loop.close(),
          registry.shutdown(),
        ]).timeout(const Duration(seconds: 2));
        expect(runner.cancelled, isTrue);
        await command;
      } finally {
        if (!runner.release.isCompleted) runner.release.complete();
        await Future.wait([loop.close(), registry.shutdown()]);
      }
    },
  );

  test('scan failures are reported and retried on the next interval', () async {
    final failure = StateError('catalog unavailable');
    catalog.beforeList = () async => throw failure;
    final errors = <Object>[];
    final scheduler = _Scheduler();
    final loop = VmReconcileLoop(
      registry: registry,
      scheduler: scheduler,
      onVmError: (_, error, _) => fail('$error'),
      onError: (error, _) => errors.add(error),
    );
    try {
      loop.start();
      await scheduler.scheduled.future;
      expect(errors, [same(failure)]);
      catalog.beforeList = null;
      scheduler.fire();
      await scheduler.scheduled.future;
      expect(catalog.scans, 2);
      expect(errors, hasLength(1));
    } finally {
      await loop.close();
    }
  });

  test(
    'per-VM failures use their callback while another VM activates',
    () async {
      final bad = await catalog.delegate.create(name: 'bad', spec: _spec);
      final good = await catalog.delegate.create(name: 'good', spec: _spec);
      catalog.failedVmId = bad.metadata.id;
      final failed = Completer<(VmId, Object)>();
      final scheduler = _Scheduler();
      final loop = VmReconcileLoop(
        registry: registry,
        scheduler: scheduler,
        onVmError: (vmId, error, _) => failed.complete((vmId, error)),
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        await scheduler.scheduled.future;
        final (vmId, error) = await failed.future;
        expect(vmId, bad.metadata.id);
        expect(error, same(catalog.activationFailure));
        await registry.reconcileVm(good.metadata.id);
        expect(registry.activeControllers.single.state.vmId, good.metadata.id);
      } finally {
        await loop.close();
      }
    },
  );

  test(
    'production timers keep scanning with a positive test interval',
    () async {
      final secondScan = Completer<void>();
      catalog.beforeList = () async {
        if (catalog.scans == 2) secondScan.complete();
      };
      final loop = VmReconcileLoop(
        registry: registry,
        interval: const Duration(milliseconds: 1),
        onVmError: (_, error, _) => fail('$error'),
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        await secondScan.future.timeout(const Duration(seconds: 2));
        expect(catalog.scans, greaterThanOrEqualTo(2));
      } finally {
        await loop.close();
      }
    },
  );
}

final class _Catalog implements VmRepository {
  _Catalog(this.delegate);
  final SqliteVmRepository delegate;
  Future<void> Function()? beforeList;
  VmId? failedVmId;
  final activationFailure = StateError('VM activation unavailable');
  int scans = 0;

  @override
  Future<List<VirtualMachine>> list({
    bool includeDeleted = false,
    LabelSelector? labelSelector,
  }) async {
    scans++;
    await beforeList?.call();
    return delegate.list(
      includeDeleted: includeDeleted,
      labelSelector: labelSelector,
    );
  }

  @override
  Future<VirtualMachine?> get(VmId vmId, {bool includeDeleted = false}) {
    if (vmId == failedVmId) return Future.error(activationFailure);
    return delegate.get(vmId, includeDeleted: includeDeleted);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _NoEffects implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
}

final class _BlockedEffects
    implements VmEffectRunner, CancellableVmEffectRunner {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool cancelled = false;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      entered.complete();
      await release.future;
    }
    return null;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      cancelled = true;
      if (!release.isCompleted) release.complete();
    }
  }
}

final class _Scheduler implements VmTimerScheduler {
  final handles = <_Handle>[];
  Completer<void> scheduled = Completer<void>();
  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _Handle(delay, callback);
    handles.add(handle);
    scheduled.complete();
    return handle;
  }

  void fire() {
    final pending = handles.where((handle) => handle.isActive).toList();
    if (pending.isEmpty) return;
    scheduled = Completer<void>();
    for (final handle in pending) {
      handle.cancel();
      handle.callback();
    }
  }
}

final class _Handle implements VmTimerHandle {
  _Handle(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}

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
  restartPolicy: RestartPolicy.never,
);
