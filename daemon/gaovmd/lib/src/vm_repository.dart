import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

final _labelSelectorNamePattern = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9._/-]*[A-Za-z0-9])?$',
);

final class LabelSelector {
  LabelSelector._(List<_LabelRequirement> requirements)
    : _requirements = List<_LabelRequirement>.unmodifiable(requirements);

  factory LabelSelector.parse(String value) {
    if (value.length > 4096) {
      throw FormatException(
        'label selector must contain at most 4096 characters',
      );
    }
    if (value.isEmpty) return LabelSelector._(const []);

    final requirements = <_LabelRequirement>[];
    for (final rawRequirement in value.split(',')) {
      final requirement = rawRequirement.trim();
      if (requirement.isEmpty) {
        throw FormatException('label selector contains an empty requirement');
      }
      final inequality = requirement.indexOf('!=');
      final doubleEquality = requirement.indexOf('==');
      final equality = requirement.indexOf('=');
      final operatorIndex = inequality >= 0
          ? inequality
          : doubleEquality >= 0
          ? doubleEquality
          : equality;
      if (operatorIndex <= 0) {
        throw FormatException(
          'invalid label selector requirement: $requirement',
        );
      }
      final operatorLength = inequality >= 0 || doubleEquality >= 0 ? 2 : 1;
      final name = requirement.substring(0, operatorIndex);
      final expected = requirement.substring(operatorIndex + operatorLength);
      if (name.length > 253 || !_labelSelectorNamePattern.hasMatch(name)) {
        throw FormatException('invalid label selector name: $name');
      }
      if (expected.length > 253) {
        throw FormatException('label selector value is too long');
      }
      requirements.add(_LabelRequirement(name, expected, inequality >= 0));
    }
    return LabelSelector._(requirements);
  }

  final List<_LabelRequirement> _requirements;

  bool matches(Map<String, String> labels) =>
      _requirements.every((requirement) => requirement.matches(labels));

  @override
  String toString() => _requirements.join(',');
}

final class _LabelRequirement {
  const _LabelRequirement(this.name, this.expected, this.isInequality);

  final String name;
  final String expected;
  final bool isInequality;

  bool matches(Map<String, String> labels) => isInequality
      ? labels[name] != expected
      : labels.containsKey(name) && labels[name] == expected;

  @override
  String toString() => '$name${isInequality ? '!=' : '='}$expected';
}

abstract interface class VmRepository {
  Future<VirtualMachine> create({
    required String name,
    Map<String, String> labels = const {},
    required VmSpec spec,
  });

  Future<List<VirtualMachine>> list({
    bool includeDeleted = false,
    LabelSelector? labelSelector,
  });

  Future<VirtualMachine?> get(VmId id, {bool includeDeleted = false});

  Future<VirtualMachine> patch(
    VmId id, {
    required int expectedRevision,
    String? name,
    Map<String, String>? labels,
    VmSpecPatch? spec,
  });

  Future<VirtualMachine> updateSpec(
    VmId id, {
    required int expectedRevision,
    required VmSpec spec,
  });

  Future<VirtualMachine> markDeleting(VmId id, {required int expectedRevision});

  Future<VirtualMachine> tombstone(VmId id, {required int expectedRevision});
}

final class VmNotFoundException implements Exception {
  const VmNotFoundException(this.id);

  final VmId id;

  @override
  String toString() => 'VM not found: $id';
}

final class VmProvisioningConflictException implements Exception {
  const VmProvisioningConflictException(this.vmId);

  final VmId vmId;

  @override
  String toString() => 'VM provisioning has not completed: $vmId';
}

final class RevisionConflictException implements Exception {
  const RevisionConflictException({
    required this.id,
    required this.expectedRevision,
    required this.actualRevision,
  });

  final VmId id;
  final int expectedRevision;
  final int actualRevision;

  @override
  String toString() =>
      'revision conflict for $id: expected $expectedRevision, '
      'actual $actualRevision';
}

final class SqliteVmRepository implements VmRepository {
  SqliteVmRepository(
    this._database, {
    VmId Function()? newVmId,
    DateTime Function()? now,
  }) : _newVmId = newVmId ?? VmId.generate,
       _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final VmId Function() _newVmId;
  final DateTime Function() _now;

  @override
  Future<VirtualMachine> create({
    required String name,
    Map<String, String> labels = const {},
    required VmSpec spec,
  }) {
    final id = _newVmId();
    final now = _timestamp();
    final metadata = VmMetadata(
      id: id,
      name: name,
      labels: labels,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    );
    final status = VmStatus(
      desiredState: DesiredState.stopped,
      phase: VmPhase.defined,
      specGeneration: 1,
      observedGeneration: 0,
      driverGeneration: 0,
      guestAgent: spec.guestAgent.enabled
          ? GuestAgentState.unavailable
          : GuestAgentState.disabled,
      lastTransitionAt: now,
    );

    return _database.transaction((connection) {
      connection.execute(
        '''
          INSERT INTO vms(
            id, name, labels_json, revision, spec_generation,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          id.value,
          name,
          jsonEncode(labels),
          metadata.revision,
          status.specGeneration,
          formatPersistenceTimestamp(now),
          formatPersistenceTimestamp(now),
        ],
      );
      connection.execute(
        '''
          INSERT INTO vm_specs(vm_id, generation, spec_json, created_at)
          VALUES (?, ?, ?, ?)
        ''',
        [
          id.value,
          status.specGeneration,
          jsonEncode(spec.toJson()),
          formatPersistenceTimestamp(now),
        ],
      );
      connection.execute(
        '''
          INSERT INTO vm_runtime(
            vm_id, desired_state, phase, observed_generation,
            driver_generation, guest_agent, restart_required,
            last_transition_at, last_error_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          id.value,
          status.desiredState.name,
          _phaseName(status.phase),
          status.observedGeneration,
          status.driverGeneration,
          status.guestAgent.name,
          status.restartRequired ? 1 : 0,
          formatPersistenceTimestamp(now),
          null,
        ],
      );
      return VirtualMachine(metadata: metadata, spec: spec, status: status);
    });
  }

  @override
  Future<List<VirtualMachine>> list({
    bool includeDeleted = false,
    LabelSelector? labelSelector,
  }) => _database.read((connection) {
    final rows = connection.select('''
      $_selectVm
      ${includeDeleted ? '' : 'WHERE v.deleted_at IS NULL'}
      ORDER BY v.created_at, v.id
    ''');
    final virtualMachines = rows.map(_decodeVm);
    return List<VirtualMachine>.unmodifiable(
      labelSelector == null
          ? virtualMachines
          : virtualMachines.where(
              (virtualMachine) =>
                  labelSelector.matches(virtualMachine.metadata.labels),
            ),
    );
  });

  @override
  Future<VirtualMachine?> get(VmId id, {bool includeDeleted = false}) =>
      _database.read(
        (connection) => _get(connection, id, includeDeleted: includeDeleted),
      );

  @override
  Future<VirtualMachine> patch(
    VmId id, {
    required int expectedRevision,
    String? name,
    Map<String, String>? labels,
    VmSpecPatch? spec,
  }) {
    if (name == null && labels == null && spec == null) {
      throw ArgumentError('patch must change metadata or spec');
    }
    return _write(
      id,
      expectedRevision: expectedRevision,
      name: name,
      labels: labels,
      specPatch: spec,
    );
  }

  @override
  Future<VirtualMachine> updateSpec(
    VmId id, {
    required int expectedRevision,
    required VmSpec spec,
  }) => _write(id, expectedRevision: expectedRevision, replacementSpec: spec);

  @override
  Future<VirtualMachine> markDeleting(
    VmId id, {
    required int expectedRevision,
  }) => _transitionDeletion(
    id,
    expectedRevision: expectedRevision,
    phase: VmPhase.deleting,
  );

  @override
  Future<VirtualMachine> tombstone(VmId id, {required int expectedRevision}) =>
      _transitionDeletion(
        id,
        expectedRevision: expectedRevision,
        phase: VmPhase.deleted,
      );

  Future<VirtualMachine> _write(
    VmId id, {
    required int expectedRevision,
    String? name,
    Map<String, String>? labels,
    VmSpecPatch? specPatch,
    VmSpec? replacementSpec,
  }) => _database.transaction((connection) {
    final current = _requireCurrent(connection, id, expectedRevision);
    if (current.status.phase == VmPhase.provisioning) {
      throw VmProvisioningConflictException(id);
    }
    final nextSpec =
        replacementSpec ??
        (specPatch == null
            ? current.spec
            : _applyPatch(current.spec, specPatch));
    final specChanged = specPatch != null || replacementSpec != null;
    final nextRevision = current.metadata.revision + 1;
    final nextGeneration =
        current.status.specGeneration + (specChanged ? 1 : 0);
    final now = _timestamp();

    final nextMetadata = VmMetadata(
      id: id,
      name: name ?? current.metadata.name,
      labels: labels ?? current.metadata.labels,
      revision: nextRevision,
      createdAt: current.metadata.createdAt,
      updatedAt: now,
    );

    connection.execute(
      '''
        UPDATE vms
        SET name = ?, labels_json = ?, revision = ?, spec_generation = ?,
            updated_at = ?
        WHERE id = ? AND revision = ? AND deleted_at IS NULL
      ''',
      [
        nextMetadata.name,
        jsonEncode(nextMetadata.labels),
        nextRevision,
        nextGeneration,
        formatPersistenceTimestamp(now),
        id.value,
        expectedRevision,
      ],
    );
    if (connection.updatedRows != 1) {
      throw RevisionConflictException(
        id: id,
        expectedRevision: expectedRevision,
        actualRevision: current.metadata.revision,
      );
    }

    if (specChanged) {
      connection.execute(
        '''
          INSERT INTO vm_specs(vm_id, generation, spec_json, created_at)
          VALUES (?, ?, ?, ?)
        ''',
        [
          id.value,
          nextGeneration,
          jsonEncode(nextSpec.toJson()),
          formatPersistenceTimestamp(now),
        ],
      );
      if (_restartFieldsDiffer(current.spec, nextSpec) &&
          current.status.phase == VmPhase.running &&
          nextGeneration > current.status.observedGeneration) {
        connection.execute(
          '''
            UPDATE vm_runtime
            SET restart_required = 1
            WHERE vm_id = ?
          ''',
          [id.value],
        );
      }
    }

    return _get(connection, id, includeDeleted: false)!;
  });

  Future<VirtualMachine> _transitionDeletion(
    VmId id, {
    required int expectedRevision,
    required VmPhase phase,
  }) => _database.transaction((connection) {
    final current = _requireCurrent(connection, id, expectedRevision);
    if (phase == VmPhase.deleted && current.status.phase != VmPhase.deleting) {
      throw StateError('VM must be marked deleting before it is tombstoned');
    }
    final now = _timestamp();
    final nextRevision = current.metadata.revision + 1;
    final isDeleted = phase == VmPhase.deleted;

    connection.execute(
      '''
        UPDATE vms
        SET revision = ?, updated_at = ?,
            deleting_at = COALESCE(deleting_at, ?),
            deleted_at = CASE WHEN ? = 1 THEN ? ELSE deleted_at END
        WHERE id = ? AND revision = ? AND deleted_at IS NULL
      ''',
      [
        nextRevision,
        formatPersistenceTimestamp(now),
        formatPersistenceTimestamp(now),
        isDeleted ? 1 : 0,
        isDeleted ? formatPersistenceTimestamp(now) : null,
        id.value,
        expectedRevision,
      ],
    );
    if (connection.updatedRows != 1) {
      throw RevisionConflictException(
        id: id,
        expectedRevision: expectedRevision,
        actualRevision: current.metadata.revision,
      );
    }
    connection.execute(
      '''
        UPDATE vm_runtime
        SET desired_state = 'stopped', phase = ?, last_transition_at = ?
        WHERE vm_id = ?
      ''',
      [_phaseName(phase), formatPersistenceTimestamp(now), id.value],
    );
    return _get(connection, id, includeDeleted: true)!;
  });

  VirtualMachine _requireCurrent(
    Database connection,
    VmId id,
    int expectedRevision,
  ) {
    final current = _get(connection, id, includeDeleted: false);
    if (current == null) throw VmNotFoundException(id);
    if (current.metadata.revision != expectedRevision) {
      throw RevisionConflictException(
        id: id,
        expectedRevision: expectedRevision,
        actualRevision: current.metadata.revision,
      );
    }
    return current;
  }

  VirtualMachine? _get(
    Database connection,
    VmId id, {
    required bool includeDeleted,
  }) {
    final rows = connection.select(
      '''
        $_selectVm
        WHERE v.id = ? ${includeDeleted ? '' : 'AND v.deleted_at IS NULL'}
      ''',
      [id.value],
    );
    return rows.isEmpty ? null : _decodeVm(rows.single);
  }

  DateTime _timestamp() => _now().toUtc();
}

VmSpec _applyPatch(VmSpec current, VmSpecPatch patch) =>
    VmSpec.fromJson({...current.toJson(), ...patch.toJson()});

bool _restartFieldsDiffer(VmSpec current, VmSpec next) =>
    current.backend != next.backend ||
    current.architecture != next.architecture ||
    current.cpu != next.cpu ||
    current.memoryBytes != next.memoryBytes ||
    current.boot != next.boot ||
    !_sameDiskSources(current.disks, next.disks) ||
    !_sameNetworkModes(current.networks, next.networks) ||
    current.graphics != next.graphics;

bool _sameDiskSources(List<VmDisk> current, List<VmDisk> next) {
  if (current.length != next.length) return false;
  final nextById = {for (final disk in next) disk.id: disk.source};
  if (nextById.length != next.length) return false;
  return current.every((disk) => nextById[disk.id] == disk.source);
}

bool _sameNetworkModes(List<VmNetwork> current, List<VmNetwork> next) {
  if (current.length != next.length) return false;
  final nextById = {
    for (final network in next) network.id: _networkMode(network),
  };
  if (nextById.length != next.length) return false;
  return current.every(
    (network) => nextById[network.id] == _networkMode(network),
  );
}

String _networkMode(VmNetwork network) => switch (network) {
  SharedNetwork() => 'shared',
  DisconnectedNetwork() => 'none',
};

VirtualMachine _decodeVm(Row row) {
  final labels = jsonDecode(row['labels_json'] as String);
  final spec = jsonDecode(row['spec_json'] as String);
  final lastError = row['last_error_json'] == null
      ? null
      : jsonDecode(row['last_error_json'] as String);
  return VirtualMachine.fromJson({
    'api_version': vmApiVersion,
    'kind': vmKind,
    'metadata': {
      'id': row['id'],
      'name': row['name'],
      'labels': labels,
      'revision': row['revision'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
    },
    'spec': spec,
    'status': {
      'desired_state': row['desired_state'],
      'phase': row['phase'],
      'spec_generation': row['spec_generation'],
      'observed_generation': row['observed_generation'],
      'driver_generation': row['driver_generation'],
      'guest_agent': row['guest_agent'],
      'restart_required': (row['restart_required'] as int) == 1,
      'last_transition_at': row['last_transition_at'],
      'last_error': lastError,
    },
  });
}

String _phaseName(VmPhase phase) => switch (phase) {
  VmPhase.spawningDriver => 'spawning_driver',
  _ => phase.name,
};

const _selectVm = '''
  SELECT
    v.id,
    v.name,
    v.labels_json,
    v.revision,
    v.spec_generation,
    v.created_at,
    v.updated_at,
    s.spec_json,
    r.desired_state,
    r.phase,
    r.observed_generation,
    r.driver_generation,
    r.guest_agent,
    r.restart_required,
    r.last_transition_at,
    r.last_error_json
  FROM vms AS v
  JOIN vm_specs AS s
    ON s.vm_id = v.id AND s.generation = v.spec_generation
  JOIN vm_runtime AS r ON r.vm_id = v.id
''';
