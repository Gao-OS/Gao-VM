import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'runtime_driver.dart';

/// Decoded diagnostic metadata, not proof of filesystem or process ownership.
final class DriverRuntimeMetadata {
  /// A missing record is unknown, not proof that its former driver exited.
  /// The caller supplies an owned generation directory under its trusted root.
  static Future<DriverRuntimeMetadata?> readFrom(
    OwnedImageDirectory directory, {
    required DriverCorrelation correlation,
    required String executable,
    required String bundlePath,
  }) async {
    if (directory.mode & 0x3f != 0 ||
        !directory.path.endsWith(
          '/${correlation.vmId.value}/${correlation.driverGeneration}',
        )) {
      throw const FormatException(
        'invalid private runtime generation directory',
      );
    }
    await directory.verifyPathBinding();
    final file = directory.fileOrNull('metadata.json');
    if (file == null) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(await file.readBounded(64 * 1024)),
      );
      if (decoded is! Map<String, Object?>)
        throw const FormatException('runtime metadata must be an object');
      final record = DriverRuntimeMetadata.fromJson(decoded);
      record.requireBinding(
        vmId: correlation.vmId,
        driverGeneration: correlation.driverGeneration,
        executable: executable,
        bundlePath: bundlePath,
        socketPath: '${directory.path}/driver.sock',
      );
      await file.verifyPathBinding();
      await directory.verifyPathBinding();
      return record;
    } finally {
      file.close();
    }
  }

  DriverRuntimeMetadata._({
    required this.correlation,
    required this.pid,
    required this.executable,
    required this.bundlePath,
    required this.socketPath,
    required this.createdAt,
    required this.processIdentity,
  });

  factory DriverRuntimeMetadata.fromJson(Map<String, Object?> json) {
    if (json['version'] is! int || json['version'] != 1)
      throw const FormatException('unsupported runtime metadata version');
    final vmId = VmId(_string(json, 'vm_id'));
    final generation = _integer(json, 'driver_generation', minimum: 1);
    final operation = json['operation_id'];
    final correlation = DriverCorrelation(
      vmId: vmId,
      driverGeneration: generation,
      operationId: operation == null
          ? null
          : OperationId(_string(json, 'operation_id')),
    );
    final pid = _integer(json, 'pid', minimum: 1, maximum: 0x7fffffff);
    final executable = _path(json, 'executable');
    final createdAt = DateTime.tryParse(_string(json, 'created_at'));
    if (createdAt == null)
      throw const FormatException('invalid runtime creation time');
    final rawIdentity = json['process_identity'];
    DriverProcessIdentity? identity;
    if (json.containsKey('process_identity')) {
      if (rawIdentity is! Map<String, Object?>)
        throw const FormatException('invalid process identity');
      identity = DriverProcessIdentity(
        pidVersion: rawIdentity.containsKey('pid_version')
            ? _integer(
                rawIdentity,
                'pid_version',
                minimum: 0,
                maximum: 0xffffffff,
              )
            : null,
        pid: _integer(rawIdentity, 'pid', minimum: 1, maximum: 0x7fffffff),
        uid: _integer(rawIdentity, 'uid', minimum: 0, maximum: 0xffffffff),
        executablePath: _path(rawIdentity, 'executable_path'),
        startedAtMicroseconds: _integer(
          rawIdentity,
          'started_at_microseconds',
          minimum: 1,
        ),
      );
      if (identity.pid != pid || identity.executablePath != executable) {
        throw const FormatException(
          'runtime process identity contradicts metadata',
        );
      }
    }
    return DriverRuntimeMetadata._(
      correlation: correlation,
      pid: pid,
      executable: executable,
      bundlePath: _path(json, 'bundle_path'),
      socketPath: _path(json, 'socket_path'),
      createdAt: createdAt.toUtc(),
      processIdentity: identity,
    );
  }

  final DriverCorrelation correlation;
  final int pid;
  final String executable;
  final String bundlePath;
  final String socketPath;
  final DateTime createdAt;
  final DriverProcessIdentity? processIdentity;

  /// Compare against trusted catalog identity and caller-derived paths, not
  /// values copied back out of this record. This does not inspect a live PID.
  void requireBinding({
    required VmId vmId,
    required int driverGeneration,
    required String executable,
    required String bundlePath,
    required String socketPath,
  }) {
    if (correlation.vmId != vmId ||
        correlation.driverGeneration != driverGeneration ||
        this.executable != executable ||
        this.bundlePath != bundlePath ||
        this.socketPath != socketPath) {
      throw const FormatException(
        'runtime metadata does not match expected binding',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'vm_id': correlation.vmId.value,
    'driver_generation': correlation.driverGeneration,
    'operation_id': correlation.operationId?.value,
    'pid': pid,
    'executable': executable,
    'bundle_path': bundlePath,
    'socket_path': socketPath,
    'created_at': createdAt.toUtc().toIso8601String(),
    if (processIdentity case final identity?)
      'process_identity': {
        'pid': identity.pid,
        'uid': identity.uid,
        'executable_path': identity.executablePath,
        'started_at_microseconds': identity.startedAtMicroseconds,
        if (identity.pidVersion != null) 'pid_version': identity.pidVersion,
      },
  };
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.contains('\u0000')) {
    throw FormatException('invalid runtime metadata $key');
  }
  return value;
}

String _path(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (!value.startsWith('/'))
    throw FormatException('runtime metadata $key must be absolute');
  return value;
}

int _integer(
  Map<String, Object?> json,
  String key, {
  required int minimum,
  int maximum = 0x7fffffffffffffff,
}) {
  final value = json[key];
  if (value is! int || value < minimum || value > maximum) {
    throw FormatException('invalid runtime metadata $key');
  }
  return value;
}
