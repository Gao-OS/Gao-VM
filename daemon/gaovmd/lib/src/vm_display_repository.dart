import 'package:gaovm_models/gaovm_models.dart';

import 'sqlite_database.dart';
import 'vm_repository.dart';

abstract interface class VmDisplayReader {
  Future<VmDisplayStatus> get(VmId vmId);
}

/// Reads only the last committed observation; never contacts a driver.
final class SqliteVmDisplayRepository implements VmDisplayReader {
  const SqliteVmDisplayRepository(this._database);
  final GaoVmDatabase _database;
  @override
  Future<VmDisplayStatus> get(VmId vmId) => _database.read((db) {
    final rows = db.select(
      '''SELECT r.driver_generation, r.display_state, r.display_observed_at
      FROM vm_runtime r JOIN vms v ON v.id = r.vm_id
      WHERE v.id = ? AND v.deleted_at IS NULL''',
      [vmId.value],
    );
    if (rows.isEmpty) throw VmNotFoundException(vmId);
    final row = rows.single;
    return VmDisplayStatus.fromJson({
      'vm_id': vmId.value,
      'driver_generation': row['driver_generation'] == 0
          ? null
          : row['driver_generation'],
      'state': row['display_state'],
      'observed_at': row['display_observed_at'],
    });
  });
}
