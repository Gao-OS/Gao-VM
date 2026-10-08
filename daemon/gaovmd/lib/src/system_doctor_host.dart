import 'host_scheduler_models.dart';
import 'macos_driver_inventory.dart';

typedef DoctorPlatformObservation = ({
  bool macOS,
  bool appleSilicon,
  int majorVersion,
});

typedef DoctorDriverObservation = ({
  bool executable,
  bool arm64,
  bool validSignature,
  bool virtualizationEntitlement,
  String signatureMessage,
});

/// Read-only operating-system boundaries. No method launches or repairs a VM.
abstract interface class DoctorHost {
  Future<DoctorPlatformObservation> inspectPlatform();
  Future<DoctorDriverObservation> inspectDriver();
  Future<HostMetrics> sampleResources();
  Future<DriverInventorySnapshot> inventory();
}
