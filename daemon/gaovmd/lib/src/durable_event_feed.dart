import 'package:gaovm_models/gaovm_models.dart';

/// Cursor-resumable committed events. Each subscription owns its cursor and
/// must be cancelled by its consumer when no longer needed.
abstract interface class DurableEventFeed {
  Future<int> latestSequence();

  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  });
}
