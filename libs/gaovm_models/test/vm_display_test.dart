import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  final vm = VmId.generate();
  final snapshot = {
    'vm_id': vm.value,
    'driver_generation': null,
    'state': 'unknown',
    'observed_at': null,
  };
  test(
    'display snapshots round trip nullable observations and reject unknown fields',
    () {
      final status = VmDisplayStatus.fromJson(snapshot);
      expect(status.toJson(), snapshot);
      expect(status, VmDisplayStatus(vmId: vm, state: VmDisplayState.unknown));
      for (final invalid in [
        {...snapshot, 'state': 'running'},
        {...snapshot, 'driver_generation': 0},
        {...snapshot, 'driver_generation': '1'},
        {...snapshot, 'observed_at': 'yesterday'},
        {...snapshot, 'extra': true},
        {...snapshot}..remove('observed_at'),
      ]) {
        expect(() => VmDisplayStatus.fromJson(invalid), throwsFormatException);
      }
      expect(
        () => VmDisplayStatus(
          vmId: vm,
          state: VmDisplayState.unknown,
          driverGeneration: 0,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'display acceptance is the exact VM-targeted OperationAccepted contract',
    () {
      final accepted = {
        'operation_id': OperationId.generate().value,
        'state': 'pending',
        'resource_type': 'virtual_machine',
        'resource_id': vm.value,
      };
      expect(VmDisplayActionAcceptance.fromJson(accepted).toJson(), accepted);
      for (final invalid in [
        {...accepted, 'state': 'failed'},
        {...accepted, 'resource_type': 'image'},
        {...accepted, 'extra': true},
        {...accepted, 'resource_id': 'default'},
      ]) {
        expect(
          () => VmDisplayActionAcceptance.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );
}
