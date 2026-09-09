import 'package:gaovmd/src/driver_runtime_metadata.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'dart:convert';
import 'dart:io';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'round trips optional kernel PID version without inventing one for legacy records',
    () {
      final json = _record();
      (json['process_identity'] as Map<String, Object?>)['pid_version'] = 42;
      final record = DriverRuntimeMetadata.fromJson(json);
      expect(record.processIdentity!.pidVersion, 42);
      expect(record.toJson(), json);
      expect(
        DriverRuntimeMetadata.fromJson(_record()).processIdentity!.pidVersion,
        isNull,
      );
      (json['process_identity'] as Map<String, Object?>)['pid_version'] = -1;
      expect(() => DriverRuntimeMetadata.fromJson(json), throwsFormatException);
    },
  );

  test('rejects malformed identity fields and non-integer versions', () {
    for (final change in <Map<String, Object?>>[
      {'pid': 0},
      {'uid': -1},
      {'uid': 0x100000000},
      {'started_at_microseconds': 0},
      {'started_at_microseconds': '1'},
      {'executable_path': 'driver'},
    ]) {
      final json = _record();
      json['process_identity'] = {
        ...json['process_identity'] as Map<String, Object?>,
        ...change,
      };
      expect(() => DriverRuntimeMetadata.fromJson(json), throwsFormatException);
    }
    expect(
      () => DriverRuntimeMetadata.fromJson(_record()..['version'] = 1.0),
      throwsFormatException,
    );
    expect(
      () => DriverRuntimeMetadata.fromJson(
        _record()..['process_identity'] = null,
      ),
      throwsFormatException,
    );
  });

  test(
    'loads bounded metadata through owned generation directory and rejects symlinks',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'runtime-metadata-',
      );
      final root = await OwnedImageDirectory.open(temporary);
      final vm = root.createDirectory(_vm);
      final generation = vm.createDirectory('4');
      try {
        Future<DriverRuntimeMetadata?> read() => DriverRuntimeMetadata.readFrom(
          generation,
          correlation: DriverCorrelation(
            vmId: VmId(_vm),
            driverGeneration: 4,
            operationId: null,
          ),
          executable: '/opt/driver',
          bundlePath: '/data/vms/$_vm.gaovm',
        );
        expect(await read(), isNull);
        final file = File('${generation.path}/metadata.json');
        final json = _record()
          ..['socket_path'] = '${generation.path}/driver.sock';
        await file.writeAsString(jsonEncode(json));
        expect((await read())!.processIdentity!.pid, 123);
        await file.writeAsString(' ' * (64 * 1024 + 1));
        await expectLater(read(), throwsFormatException);
        await file.rename('${generation.path}/other.json');
        await Link(file.path).create('${generation.path}/other.json');
        await expectLater(read(), throwsA(isA<FileSystemException>()));
      } finally {
        generation.close();
        vm.close();
        root.close();
        await temporary.delete(recursive: true);
      }
    },
  );

  test('legacy metadata has no inferred process identity', () {
    final json = _record()..remove('process_identity');
    final record = DriverRuntimeMetadata.fromJson(json);
    expect(record.processIdentity, isNull);
    expect(record.toJson(), json);
  });

  test('binding checks catalog VM generation and derived paths', () {
    final record = DriverRuntimeMetadata.fromJson(_record());
    void bind({
      int generation = 4,
      String vm = _vm,
      String executable = '/opt/driver',
      String socket = '/data/run/$_vm/4/driver.sock',
      String bundle = '/data/vms/$_vm.gaovm',
    }) {
      record.requireBinding(
        vmId: VmId(vm),
        driverGeneration: generation,
        executable: executable,
        socketPath: socket,
        bundlePath: bundle,
      );
    }

    bind();
    expect(() => bind(generation: 5), throwsFormatException);
    expect(
      () => bind(vm: 'vm_01J00000000000000000000001'),
      throwsFormatException,
    );
    expect(() => bind(executable: '/other/driver'), throwsFormatException);
    expect(() => bind(socket: '/other/driver.sock'), throwsFormatException);
    expect(() => bind(bundle: '/other/vm.gaovm'), throwsFormatException);
  });

  test(
    'rejects contradictory process identity rather than selecting one PID',
    () {
      for (final change in [
        {'pid': 456},
        {'executable_path': '/other/driver'},
      ]) {
        final json = _record();
        json['process_identity'] = {
          ...json['process_identity'] as Map<String, Object?>,
          ...change,
        };
        expect(
          () => DriverRuntimeMetadata.fromJson(json),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'decodes recorded kernel identity without treating creation time as birth',
    () {
      final record = DriverRuntimeMetadata.fromJson(_record());
      expect(record.correlation.vmId.value, _vm);
      expect(record.correlation.driverGeneration, 4);
      expect(record.processIdentity!.pid, 123);
      expect(record.processIdentity!.uid, 502);
      expect(record.processIdentity!.startedAtMicroseconds, 1000001);
      expect(record.processIdentity!.executablePath, '/opt/driver');
      expect(record.toJson(), _record());
    },
  );
}

const _vm = 'vm_01J00000000000000000000000';
Map<String, Object?> _record() => {
  'version': 1,
  'vm_id': _vm,
  'driver_generation': 4,
  'operation_id': null,
  'pid': 123,
  'executable': '/opt/driver',
  'bundle_path': '/data/vms/$_vm.gaovm',
  'socket_path': '/data/run/$_vm/4/driver.sock',
  'created_at': '2026-09-07T00:00:00.000Z',
  'process_identity': {
    'pid': 123,
    'uid': 502,
    'executable_path': '/opt/driver',
    'started_at_microseconds': 1000001,
  },
};
