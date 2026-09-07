import 'vm_command_repository.dart';
import 'vm_controller.dart';

abstract interface class VmCommandTarget {
  Future<VmIntentAdoptionDisposition> adopt(VmCommandRecord record);
}

enum VmCommandDispatchStatus { acknowledged, deferred, lostClaim, failed }

final class VmCommandDispatchOutcome {
  const VmCommandDispatchOutcome({
    required this.record,
    required this.status,
    this.error,
    this.stackTrace,
    this.released,
    this.releaseError,
    this.releaseStackTrace,
  });

  final VmCommandRecord record;
  final VmCommandDispatchStatus status;
  final Object? error;
  final StackTrace? stackTrace;

  /// Null when release was not attempted or threw; false when its claim fence
  /// was lost. An adoption/acknowledgment error remains the primary failure.
  final bool? released;
  final Object? releaseError;
  final StackTrace? releaseStackTrace;
}

/// One bounded claim batch, with one head per VM and parallel VM delivery.
/// The target acknowledges durable adoption, never full lifecycle completion.
/// There is no background polling or automatic retry. Claim errors propagate;
/// delivery errors are retained in the corresponding record's outcome.
final class VmCommandDispatcher {
  VmCommandDispatcher({
    required SqliteVmCommandRepository commands,
    required VmCommandTarget target,
    required String owner,
    Duration lease = const Duration(seconds: 30),
  }) : _commands = commands,
       _target = target,
       _owner = owner,
       _lease = lease {
    if (owner.isEmpty || owner.length > 255) {
      throw ArgumentError.value(
        owner,
        'owner',
        'must contain 1 to 255 characters',
      );
    }
    if (lease <= Duration.zero) {
      throw ArgumentError.value(lease, 'lease', 'must be positive');
    }
  }

  final SqliteVmCommandRepository _commands;
  final VmCommandTarget _target;
  final String _owner;
  final Duration _lease;

  Future<List<VmCommandDispatchOutcome>> dispatchOnce({int limit = 100}) async {
    final claims = await _commands.claim(
      owner: _owner,
      lease: _lease,
      limit: limit,
    );
    return List.unmodifiable(await Future.wait(claims.map(_deliver)));
  }

  Future<VmCommandDispatchOutcome> _deliver(VmCommandClaim claim) async {
    try {
      final disposition = await _target.adopt(claim.record);
      if (disposition == VmIntentAdoptionDisposition.deferred) {
        return _release(claim);
      }
      final acknowledged = await _commands.acknowledge(claim);
      return VmCommandDispatchOutcome(
        record: claim.record,
        status: acknowledged
            ? VmCommandDispatchStatus.acknowledged
            : VmCommandDispatchStatus.lostClaim,
      );
    } catch (error, stackTrace) {
      return _release(claim, error: error, stackTrace: stackTrace);
    }
  }

  Future<VmCommandDispatchOutcome> _release(
    VmCommandClaim claim, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    try {
      final released = await _commands.release(claim);
      return VmCommandDispatchOutcome(
        record: claim.record,
        status: error != null
            ? VmCommandDispatchStatus.failed
            : released
            ? VmCommandDispatchStatus.deferred
            : VmCommandDispatchStatus.lostClaim,
        error: error,
        stackTrace: stackTrace,
        released: released,
      );
    } catch (releaseError, releaseStackTrace) {
      return VmCommandDispatchOutcome(
        record: claim.record,
        status: VmCommandDispatchStatus.failed,
        error: error ?? releaseError,
        stackTrace: stackTrace ?? releaseStackTrace,
        releaseError: releaseError,
        releaseStackTrace: releaseStackTrace,
      );
    }
  }
}
