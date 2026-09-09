import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'vm_bundle_store.dart';
import 'vm_bundle_manifest.dart';
import 'managed_disk_materializer.dart';
import 'vm_provisioning_repository.dart';
import 'vm_provisioning_work_repository.dart';

enum VmProvisioningOutcomeKind { completed, deferred, failed }

/// [failed] describes a delivery/infrastructure error, not a failed Operation.
/// Durable Operation outcomes are [completed] with [completion] populated.
final class VmProvisioningOutcome {
  const VmProvisioningOutcome(
    this.operationId,
    this.kind, {
    this.completion,
    this.error,
  });
  final OperationId operationId;
  final VmProvisioningOutcomeKind kind;
  final VmProvisioningCompletionKind? completion;
  final Object? error;
}

final class VmProvisioningWorker {
  VmProvisioningWorker({
    required this.work,
    required this.bundles,
    required this.owner,
    this.lease = const Duration(seconds: 30),
  }) {
    if (lease.inMicroseconds < 3)
      throw ArgumentError.value(
        lease,
        'lease',
        'must be at least 3 microseconds',
      );
  }
  final SqliteVmProvisioningWorkRepository work;
  final VmBundleStore bundles;
  final String owner;
  final Duration lease;

  Future<List<VmProvisioningOutcome>> dispatchOnce({int limit = 100}) async {
    final claims = await work.claim(owner: owner, lease: lease, limit: limit);
    return Future.wait(claims.map(_dispatch));
  }

  Future<VmProvisioningOutcome> _dispatch(VmProvisioningClaim claim) async {
    final delivery = _DeliveryLease(work, claim, lease)..start();
    var terminal = false;
    VmProvisioningOutcome result;
    VmProvisioningOutcome deferred() => VmProvisioningOutcome(
      claim.plan.operationId,
      VmProvisioningOutcomeKind.deferred,
      error: delivery.error,
    );
    try {
      result = await bundles.withBundle(claim.plan, (bundle) async {
        Future<VmProvisioningOutcome> cancel() async {
          delivery.start();
          await bundle.removeUncommitted();
          await delivery.freeze();
          if (delivery.lost) return deferred();
          terminal = await work.completeCancelled(delivery.claim);
          return terminal
              ? VmProvisioningOutcome(
                  claim.plan.operationId,
                  VmProvisioningOutcomeKind.completed,
                  completion: VmProvisioningCompletionKind.cancelled,
                )
              : deferred();
        }

        await delivery.refresh();
        if (delivery.lost) return deferred();
        if (delivery.cancelled) return cancel();
        VmBundleManifest manifest;
        try {
          // Once ownership is lost, leave any in-flight publication for the
          // next claimant. The held filesystem lock still excludes its IO.
          manifest = await bundle.publish(
            isCancelled: () => !delivery.lost && delivery.cancelled,
          );
        } catch (error) {
          await delivery.refresh();
          if (delivery.lost) return deferred();
          await bundle.removeUncommitted();
          await delivery.freeze();
          if (delivery.lost) return deferred();
          if (delivery.cancelled) return cancel();
          try {
            terminal = await work.completeFailed(
              delivery.claim,
              error: OperationError(
                code: error is ManagedDiskInsufficientSpace
                    ? ErrorCode.hostResourceExhausted
                    : error is FormatException
                    ? ErrorCode.vmSpecInvalid
                    : ErrorCode.internalError,
                message: 'VM provisioning failed: $error',
                retryable: error is ManagedDiskInsufficientSpace,
                details: JsonObjectValue.empty,
              ),
            );
          } on StateError {
            await delivery.refresh();
            if (delivery.lost) return deferred();
            if (delivery.cancelled) return cancel();
            rethrow;
          }
          return terminal
              ? VmProvisioningOutcome(
                  claim.plan.operationId,
                  VmProvisioningOutcomeKind.completed,
                  completion: VmProvisioningCompletionKind.failed,
                  error: error,
                )
              : deferred();
        }
        await delivery.freeze();
        if (delivery.lost) return deferred();
        if (delivery.cancelled) return cancel();
        try {
          terminal = await work.completePublished(
            delivery.claim,
            manifestDigest: manifest.digest,
          );
        } on StateError {
          await delivery.refresh();
          if (delivery.lost) return deferred();
          if (delivery.cancelled) return cancel();
          rethrow;
        }
        return terminal
            ? VmProvisioningOutcome(
                claim.plan.operationId,
                VmProvisioningOutcomeKind.completed,
                completion: VmProvisioningCompletionKind.succeeded,
              )
            : deferred();
      });
    } catch (error) {
      result = VmProvisioningOutcome(
        claim.plan.operationId,
        delivery.lost
            ? VmProvisioningOutcomeKind.deferred
            : VmProvisioningOutcomeKind.failed,
        error: error,
      );
    } finally {
      await delivery.stop();
    }
    if (!terminal && !delivery.lost) {
      try {
        await work.release(delivery.claim);
      } catch (error) {
        return VmProvisioningOutcome(
          claim.plan.operationId,
          VmProvisioningOutcomeKind.failed,
          error: error,
        );
      }
    }
    return result;
  }
}

final class _DeliveryLease {
  _DeliveryLease(this.work, this.claim, this.duration);
  final SqliteVmProvisioningWorkRepository work;
  VmProvisioningClaim claim;
  final Duration duration;
  Timer? _timer;
  Future<void>? _renewing;
  bool lost = false;
  Object? error;
  bool get cancelled => claim.job.cancellationRequested;

  void start() {
    _timer ??= Timer.periodic(
      Duration(microseconds: duration.inMicroseconds ~/ 3),
      (_) {
        if (_renewing == null && !lost) unawaited(refresh());
      },
    );
  }

  Future<void> refresh() async {
    if (_renewing != null) return _renewing;
    if (lost) return;
    final renewal = _renew();
    _renewing = renewal;
    try {
      await renewal;
    } finally {
      _renewing = null;
    }
  }

  Future<void> _renew() async {
    try {
      final next = await work.renew(claim, lease: duration);
      if (next == null) {
        lost = true;
      } else {
        claim = next;
      }
    } catch (failure) {
      error = failure;
      lost = true;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _renewing;
  }

  Future<void> freeze() async {
    await stop();
    await refresh();
  }
}
