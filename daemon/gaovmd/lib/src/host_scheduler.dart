import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'host_lease_repository.dart';
import 'host_scheduler_models.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';
import 'vm_repository.dart';

abstract interface class HostMetricsSource {
  Future<HostMetrics> sample();
}

typedef HostLeaseLostHandler =
    void Function(
      VmId vmId,
      int specGeneration,
      OperationId? operationId,
      OperationError error,
    );

abstract interface class HostCapacityCatalog {
  Future<HostCapacityRequest> requestFor(
    VmId vmId, {
    required HostLeasePhase phase,
  });

  Future<List<HostCapacityRequest>> recoveryRequests();
}

final class VmRepositoryHostCapacityCatalog implements HostCapacityCatalog {
  VmRepositoryHostCapacityCatalog(
    this._repository, {
    required int Function(VirtualMachine virtualMachine) diskBytes,
  }) : _diskBytes = diskBytes;

  final VmRepository _repository;
  final int Function(VirtualMachine virtualMachine) _diskBytes;

  @override
  Future<HostCapacityRequest> requestFor(
    VmId vmId, {
    required HostLeasePhase phase,
  }) async {
    final virtualMachine = await _repository.get(vmId);
    if (virtualMachine == null) throw VmNotFoundException(vmId);
    return _request(virtualMachine, phase);
  }

  @override
  Future<List<HostCapacityRequest>> recoveryRequests() async {
    final virtualMachines = await _repository.list();
    final requests =
        virtualMachines
            .where(
              (virtualMachine) =>
                  virtualMachine.status.desiredState == DesiredState.running,
            )
            .map(
              (virtualMachine) => _request(
                virtualMachine,
                virtualMachine.status.phase == VmPhase.running
                    ? HostLeasePhase.running
                    : HostLeasePhase.booting,
              ),
            )
            .toList()
          ..sort((left, right) => left.vmId.value.compareTo(right.vmId.value));
    return List<HostCapacityRequest>.unmodifiable(requests);
  }

  HostCapacityRequest _request(
    VirtualMachine virtualMachine,
    HostLeasePhase phase,
  ) => HostCapacityRequest(
    vmId: virtualMachine.metadata.id,
    cpuCount: virtualMachine.spec.cpu,
    memoryBytes: virtualMachine.spec.memoryBytes,
    diskBytes: _diskBytes(virtualMachine),
    phase: phase,
    specGeneration: virtualMachine.status.specGeneration,
    operationId: null,
  );
}

final class HostScheduler
    implements VmLeaseEffectAdapter, VmEffectCancellationAdapter {
  HostScheduler({
    required HostLeaseRepository leases,
    required HostCapacityCatalog catalog,
    required HostMetricsSource metrics,
    required HostSchedulerLimits limits,
    required String ownerId,
    required HostLeaseLostHandler onLeaseLost,
    Duration leaseTtl = const Duration(seconds: 30),
    Duration? renewalInterval,
    Duration? lossRetryInterval,
    Duration shutdownTimeout = const Duration(seconds: 10),
    VmTimerScheduler renewalScheduler = const DartVmTimerScheduler(),
    DateTime Function()? now,
  }) : _leases = leases,
       _catalog = catalog,
       _metrics = metrics,
       _limits = limits,
       _ownerId = ownerId,
       _onLeaseLost = onLeaseLost,
       _leaseTtl = leaseTtl,
       _renewalInterval =
           renewalInterval ??
           Duration(
             microseconds: leaseTtl.inMicroseconds ~/ 2 == 0
                 ? 1
                 : leaseTtl.inMicroseconds ~/ 2,
           ),
       _lossRetryInterval =
           lossRetryInterval ??
           renewalInterval ??
           Duration(
             microseconds: leaseTtl.inMicroseconds ~/ 2 == 0
                 ? 1
                 : leaseTtl.inMicroseconds ~/ 2,
           ),
       _shutdownTimeout = shutdownTimeout,
       _renewalScheduler = renewalScheduler,
       _now = now ?? DateTime.now {
    if (ownerId.trim().isEmpty)
      throw ArgumentError('ownerId must not be empty');
    if (leaseTtl <= Duration.zero) {
      throw ArgumentError('leaseTtl must be positive');
    }
    if (_renewalInterval <= Duration.zero || _renewalInterval >= leaseTtl) {
      throw ArgumentError('renewalInterval must be positive and below TTL');
    }
    if (_lossRetryInterval <= Duration.zero) {
      throw ArgumentError('lossRetryInterval must be positive');
    }
    if (shutdownTimeout <= Duration.zero) {
      throw ArgumentError('shutdownTimeout must be positive');
    }
  }

  final HostLeaseRepository _leases;
  final HostCapacityCatalog _catalog;
  final HostMetricsSource _metrics;
  final HostSchedulerLimits _limits;
  final String _ownerId;
  final HostLeaseLostHandler _onLeaseLost;
  final Duration _leaseTtl;
  final Duration _renewalInterval;
  final Duration _lossRetryInterval;
  final Duration _shutdownTimeout;
  final VmTimerScheduler _renewalScheduler;
  final DateTime Function() _now;
  final Map<VmId, _RenewalRegistration> _renewals = {};
  final Map<VmId, _LeaseLossDelivery> _leaseLosses = {};
  final Set<_AcquisitionKey> _inFlightAcquisitions = {};
  final Set<_AcquisitionKey> _cancelledAcquisitions = {};
  final Map<VmId, _AcquisitionKey> _latestAcquisitions = {};
  final Map<_AcquisitionKey, Completer<void>> _acquisitionCompletions = {};
  final Set<Completer<void>> _directAdmissionCompletions = {};
  Future<void>? _shutdownFuture;
  bool _closed = false;

  int get pendingRenewalCount => _renewals.length;
  int get pendingLeaseLossCount => _leaseLosses.length;
  bool get isClosed => _closed;

  @override
  Future<void> acquire(VmControllerState state, OperationId operationId) async {
    _ensureOpen();
    final key = _AcquisitionKey(state.vmId, operationId);
    if (_inFlightAcquisitions.contains(key)) {
      throw VmEffectException(_acquisitionConflictError(key));
    }
    final completion = Completer<void>();
    _inFlightAcquisitions.add(key);
    _acquisitionCompletions[key] = completion;
    _latestAcquisitions[state.vmId] = key;
    try {
      final catalogRequest = await _catalog.requestFor(
        state.vmId,
        phase: HostLeasePhase.booting,
      );
      _throwIfCancelled(key);
      final request = catalogRequest.copyWith(
        specGeneration: state.specGeneration,
        operationId: operationId,
      );
      final metrics = await _metrics.sample();
      _throwIfCancelled(key);
      final decision = await _acquire(request, metrics);
      if (_closed ||
          _cancelledAcquisitions.contains(key) ||
          _latestAcquisitions[state.vmId] != key) {
        if (decision.admitted) {
          await _leases.releaseAcquisition(
            state.vmId,
            ownerId: _ownerId,
            operationId: operationId,
          );
        }
        throw VmEffectException(_acquisitionCancelledError(key));
      }
      if (!decision.admitted) throw VmEffectException(decision.error!);
      _startRenewal(decision.lease!);
    } finally {
      _inFlightAcquisitions.remove(key);
      _cancelledAcquisitions.remove(key);
      _acquisitionCompletions.remove(key);
      if (!completion.isCompleted) completion.complete();
      if (_latestAcquisitions[state.vmId] == key) {
        _latestAcquisitions.remove(state.vmId);
      }
    }
  }

  Future<HostLeaseDecision> admit(
    VmId vmId, {
    HostLeasePhase phase = HostLeasePhase.booting,
    int? specGeneration,
    OperationId? operationId,
  }) async {
    _ensureOpen();
    final completion = Completer<void>();
    _directAdmissionCompletions.add(completion);
    try {
      final catalogRequest = await _catalog.requestFor(vmId, phase: phase);
      _ensureOpen();
      final request = catalogRequest.copyWith(
        specGeneration: specGeneration,
        operationId: operationId,
      );
      // Host metrics are sampled before the repository opens its transaction.
      final metrics = await _metrics.sample();
      _ensureOpen();
      final decision = await _acquire(request, metrics);
      if (_closed) {
        if (decision.admitted) {
          if (request.operationId case final operationId?) {
            await _leases.releaseAcquisition(
              vmId,
              ownerId: _ownerId,
              operationId: operationId,
            );
          } else {
            await _leases.release(vmId, ownerId: _ownerId);
          }
        }
        throw const HostSchedulerClosedException();
      }
      if (decision.admitted) _startRenewal(decision.lease!);
      return decision;
    } finally {
      _directAdmissionCompletions.remove(completion);
      if (!completion.isCompleted) completion.complete();
    }
  }

  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {
    _stopRenewal(state.vmId);
    final released = await _leases.release(state.vmId, ownerId: _ownerId);
    if (!released) throw VmEffectException(_leaseOwnerError(state.vmId));
  }

  @override
  Future<void> markRunning(
    VmControllerState state,
    OperationId operationId,
  ) async {
    final marked = await markLeaseRunning(state.vmId, operationId);
    if (!marked) {
      final catalogRequest = await _catalog.requestFor(
        state.vmId,
        phase: HostLeasePhase.cleanup,
      );
      final cleanup = await _leases.retainForCleanup(
        request: catalogRequest.copyWith(
          phase: HostLeasePhase.cleanup,
          specGeneration: state.specGeneration,
          operationId: operationId,
        ),
        ownerId: _ownerId,
        now: _now(),
        ttl: _leaseTtl,
      );
      if (cleanup != null) _startRenewal(cleanup);
      throw VmEffectException(_leaseLostError(state.vmId));
    }
  }

  Future<bool> markLeaseRunning(VmId vmId, OperationId operationId) =>
      _markLeaseRunning(vmId, operationId);

  Future<bool> _markLeaseRunning(VmId vmId, OperationId operationId) async {
    _ensureOpen();
    return _leases.markRunning(
      vmId,
      ownerId: _ownerId,
      operationId: operationId,
      now: _now(),
    );
  }

  Future<bool> renew(VmId vmId) async {
    _ensureOpen();
    final registration = _renewals[vmId];
    if (registration == null) return false;
    final renewed = await _leases.renew(
      vmId,
      ownerId: _ownerId,
      operationId: registration.operationId,
      now: _now(),
      ttl: _leaseTtl,
    );
    return !_closed && renewed;
  }

  Future<List<HostLeaseDecision>> recover() async {
    _ensureOpen();
    final requests = await _catalog.recoveryRequests();
    _ensureOpen();
    final metrics = await _metrics.sample();
    _ensureOpen();
    final decisions = await _leases.recover(
      requests: requests,
      limits: _limits,
      metrics: metrics,
      ownerId: _ownerId,
      now: _now(),
      ttl: _leaseTtl,
    );
    if (_closed) {
      for (final decision in decisions.where((decision) => decision.admitted)) {
        await _leases.release(decision.request.vmId, ownerId: _ownerId);
      }
      throw const HostSchedulerClosedException();
    }
    _stopAllRenewals();
    for (final decision in decisions) {
      if (decision.admitted) _startRenewal(decision.lease!);
    }
    return decisions;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      final operationId = effect.operationId!;
      final key = _AcquisitionKey(state.vmId, operationId);
      if (_inFlightAcquisitions.contains(key)) {
        _cancelledAcquisitions.add(key);
      }
      final released = await _leases.releaseAcquisition(
        state.vmId,
        ownerId: _ownerId,
        operationId: operationId,
      );
      if (!_inFlightAcquisitions.contains(key)) {
        _cancelledAcquisitions.remove(key);
      }
      if (released) _stopRenewal(state.vmId, operationId: operationId);
    }
  }

  Future<void> shutdown() {
    final pending = _shutdownFuture;
    if (pending != null) return pending;
    _closed = true;
    _cancelledAcquisitions.addAll(_inFlightAcquisitions);
    _stopAllRenewals();
    _stopAllLeaseLosses();
    late Future<void> attempt;
    attempt = _shutdownAttempt().whenComplete(() {
      if (identical(_shutdownFuture, attempt)) _shutdownFuture = null;
    });
    _shutdownFuture = attempt;
    return attempt;
  }

  Future<void> _shutdownAttempt() async {
    final waiters = _acquisitionCompletions.values
        .map((completion) => completion.future)
        .followedBy(
          _directAdmissionCompletions.map((completion) => completion.future),
        )
        .toList();
    try {
      await Future.wait(waiters).timeout(_shutdownTimeout);
    } on TimeoutException {
      throw HostSchedulerShutdownException(waiters.length);
    } finally {
      _stopAllRenewals();
      _stopAllLeaseLosses();
    }
  }

  Future<HostLeaseDecision> _acquire(
    HostCapacityRequest request,
    HostMetrics metrics,
  ) => _leases.acquire(
    request: request,
    limits: _limits,
    metrics: metrics,
    ownerId: _ownerId,
    now: _now(),
    ttl: _leaseTtl,
  );

  void _ensureOpen() {
    if (_closed) throw const HostSchedulerClosedException();
  }

  void _throwIfCancelled(_AcquisitionKey key) {
    if (_closed ||
        _cancelledAcquisitions.contains(key) ||
        _latestAcquisitions[key.vmId] != key) {
      throw VmEffectException(_acquisitionCancelledError(key));
    }
  }

  void _startRenewal(HostLease lease) {
    if (_closed) return;
    _stopRenewal(lease.request.vmId);
    _stopLeaseLoss(lease.request.vmId);
    late VmTimerHandle handle;
    handle = _renewalScheduler.schedule(_renewalInterval, () {
      final current = _renewals[lease.request.vmId];
      if (current == null || !identical(current.handle, handle)) return;
      unawaited(_renew(current));
    });
    _renewals[lease.request.vmId] = _RenewalRegistration(
      vmId: lease.request.vmId,
      specGeneration: lease.request.specGeneration,
      operationId: lease.request.operationId,
      handle: handle,
    );
  }

  Future<void> _renew(_RenewalRegistration registration) async {
    final current = _renewals[registration.vmId];
    if (!identical(current, registration)) return;
    try {
      final renewed = await _leases.renew(
        registration.vmId,
        ownerId: _ownerId,
        operationId: registration.operationId,
        now: _now(),
        ttl: _leaseTtl,
      );
      if (!identical(_renewals[registration.vmId], registration)) return;
      if (!renewed) {
        _recordLeaseLoss(registration);
        return;
      }
      final lease = (await _leases.list(
        activeAt: _now(),
      )).where((lease) => lease.request.vmId == registration.vmId).firstOrNull;
      if (lease == null) {
        _recordLeaseLoss(registration);
        return;
      }
      if (!identical(_renewals[registration.vmId], registration)) return;
      _startRenewal(lease);
    } catch (_) {
      _recordLeaseLoss(registration);
    }
  }

  void _recordLeaseLoss(_RenewalRegistration registration) {
    if (!identical(_renewals[registration.vmId], registration)) return;
    _stopRenewal(registration.vmId);
    if (_closed) return;
    _stopLeaseLoss(registration.vmId);
    final delivery = _LeaseLossDelivery(
      vmId: registration.vmId,
      specGeneration: registration.specGeneration,
      operationId: registration.operationId,
      error: _leaseLostError(registration.vmId),
    );
    _leaseLosses[registration.vmId] = delivery;
    _deliverLeaseLoss(delivery);
  }

  void _deliverLeaseLoss(_LeaseLossDelivery delivery) {
    if (_closed || !identical(_leaseLosses[delivery.vmId], delivery)) {
      return;
    }
    try {
      _onLeaseLost(
        delivery.vmId,
        delivery.specGeneration,
        delivery.operationId,
        delivery.error,
      );
      if (identical(_leaseLosses[delivery.vmId], delivery)) {
        _leaseLosses.remove(delivery.vmId);
        delivery.retryHandle?.cancel();
      }
    } catch (_) {
      if (!_closed && identical(_leaseLosses[delivery.vmId], delivery)) {
        _scheduleLeaseLossRetry(delivery);
      }
    }
  }

  void _scheduleLeaseLossRetry(_LeaseLossDelivery delivery) {
    delivery.retryHandle?.cancel();
    late VmTimerHandle handle;
    handle = _renewalScheduler.schedule(_lossRetryInterval, () {
      if (_closed ||
          !identical(_leaseLosses[delivery.vmId], delivery) ||
          !identical(delivery.retryHandle, handle)) {
        return;
      }
      delivery.retryHandle = null;
      _deliverLeaseLoss(delivery);
    });
    delivery.retryHandle = handle;
  }

  void _stopLeaseLoss(VmId vmId) {
    final delivery = _leaseLosses.remove(vmId);
    delivery?.retryHandle?.cancel();
  }

  void _stopAllLeaseLosses() {
    final deliveries = _leaseLosses.values.toList();
    _leaseLosses.clear();
    for (final delivery in deliveries) {
      delivery.retryHandle?.cancel();
    }
  }

  void _stopRenewal(VmId vmId, {OperationId? operationId}) {
    final current = _renewals[vmId];
    if (current == null ||
        operationId != null && current.operationId != operationId) {
      return;
    }
    _renewals.remove(vmId);
    current.handle.cancel();
  }

  void _stopAllRenewals() {
    final registrations = _renewals.values.toList();
    _renewals.clear();
    for (final registration in registrations) {
      registration.handle.cancel();
    }
  }
}

OperationError _leaseOwnerError(VmId vmId) => OperationError(
  code: ErrorCode.internalError,
  message: 'host lease is owned by another daemon',
  retryable: true,
  details: JsonObjectValue.fromJson({'vm_id': vmId.value}),
);

OperationError _leaseLostError(VmId vmId) => OperationError(
  code: ErrorCode.hostResourceExhausted,
  message: 'host lease renewal lost',
  retryable: true,
  details: JsonObjectValue.fromJson({'vm_id': vmId.value}),
);

OperationError _acquisitionCancelledError(_AcquisitionKey key) =>
    OperationError(
      code: ErrorCode.vmOperationConflict,
      message: 'host lease acquisition cancelled',
      retryable: true,
      details: JsonObjectValue.fromJson({
        'vm_id': key.vmId.value,
        'operation_id': key.operationId.value,
      }),
    );

OperationError _acquisitionConflictError(_AcquisitionKey key) => OperationError(
  code: ErrorCode.vmOperationConflict,
  message: 'host lease acquisition already in progress',
  retryable: true,
  details: JsonObjectValue.fromJson({
    'vm_id': key.vmId.value,
    'operation_id': key.operationId.value,
  }),
);

final class HostSchedulerClosedException implements Exception {
  const HostSchedulerClosedException();

  @override
  String toString() => 'host scheduler is closed';
}

final class HostSchedulerShutdownException implements Exception {
  const HostSchedulerShutdownException(this.pendingOperations);

  final int pendingOperations;

  @override
  String toString() =>
      'host scheduler shutdown timed out with $pendingOperations pending '
      'operation(s)';
}

final class _AcquisitionKey {
  const _AcquisitionKey(this.vmId, this.operationId);

  final VmId vmId;
  final OperationId operationId;

  @override
  bool operator ==(Object other) =>
      other is _AcquisitionKey &&
      other.vmId == vmId &&
      other.operationId == operationId;

  @override
  int get hashCode => Object.hash(vmId, operationId);
}

final class _RenewalRegistration {
  const _RenewalRegistration({
    required this.vmId,
    required this.specGeneration,
    required this.operationId,
    required this.handle,
  });

  final VmId vmId;
  final int specGeneration;
  final OperationId? operationId;
  final VmTimerHandle handle;
}

final class _LeaseLossDelivery {
  _LeaseLossDelivery({
    required this.vmId,
    required this.specGeneration,
    required this.operationId,
    required this.error,
  });

  final VmId vmId;
  final int specGeneration;
  final OperationId? operationId;
  final OperationError error;
  VmTimerHandle? retryHandle;
}
