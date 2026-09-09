import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/driver_runtime_layout.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    final temporaryRoot = Platform.isMacOS
        ? Directory('/private/tmp')
        : Directory.systemTemp;
    root = await temporaryRoot.createTemp('gvl-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('cleanup preserves unknown generation content for recovery', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    await File('${paths.directory}/metadata.json').writeAsString('{}');
    await File('${paths.directory}/unexpected').writeAsString('preserve');
    await expectLater(
      layout.remove(paths),
      throwsA(isA<FileSystemException>()),
    );
    final quarantine = '${paths.directory}.cleanup.${paths.cleanupToken}';
    expect(await File('$quarantine/unexpected').readAsString(), 'preserve');
    expect(await File('$quarantine/metadata.json').readAsString(), '{}');
  });

  test('cleanup preserves content inside a VM ownership marker', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    final vmPath = Directory(paths.directory).parent.path;
    final markerName = '.gaovm-owner-${paths.vmCleanupToken}';
    await File('$vmPath/$markerName/unexpected').writeAsString('preserve');

    await expectLater(
      layout.remove(paths),
      throwsA(isA<FileSystemException>()),
    );

    final quarantine = '$vmPath.cleanup.${paths.vmCleanupToken}';
    expect(
      await File('$quarantine/$markerName/unexpected').readAsString(),
      'preserve',
    );
    await File('$quarantine/$markerName/unexpected').delete();
    await layout.remove(paths);
    expect(await Directory(quarantine).exists(), isFalse);
  });

  test('cleanup resumes after removing the last quarantine marker', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    final vmPath = Directory(paths.directory).parent.path;
    final generationQuarantine =
        '${paths.directory}.cleanup.${paths.cleanupToken}';
    await Directory(paths.directory).rename(generationQuarantine);
    await Directory(
      '$generationQuarantine/.gaovm-owner-${paths.cleanupToken}',
    ).delete();
    await layout.remove(paths);
    expect(await Directory(generationQuarantine).exists(), isFalse);
    expect(await Directory(vmPath).exists(), isFalse);

    final next = await layout.create(_correlation);
    await Directory(
      '${next.directory}/.gaovm-owner-${next.cleanupToken}',
    ).delete();
    await Directory(next.directory).delete();
    final vmQuarantine = '$vmPath.cleanup.${next.vmCleanupToken}';
    await Directory(vmPath).rename(vmQuarantine);
    await Directory(
      '$vmQuarantine/.gaovm-owner-${next.vmCleanupToken}',
    ).delete();
    await layout.remove(next);
    expect(await Directory(vmQuarantine).exists(), isFalse);
    expect(await Directory(vmPath).exists(), isFalse);
  });

  test(
    'recovery reads owned cleanup tokens without changing runtime files',
    () async {
      final layout = DriverRuntimeLayout('${root.path}/run');
      final paths = await layout.create(_correlation);
      final recovered = await layout.recoverPaths(_correlation);
      expect(recovered.directory, paths.directory);
      expect(recovered.cleanupToken, paths.cleanupToken);
      expect(recovered.vmCleanupToken, paths.vmCleanupToken);
      final marker = '${paths.directory}/.gaovm-owner-${paths.cleanupToken}';
      await File('$marker/unexpected').writeAsString('preserve');
      await expectLater(
        layout.recoverPaths(_correlation),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('$marker/unexpected').readAsString(), 'preserve');
    },
  );

  test('VM quarantine cleanup never follows a replacement symlink', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    await layout.remove(paths);
    final target = await Directory('${root.path}/foreign').create();
    final marker = await Directory(
      '${target.path}/.gaovm-owner-${paths.vmCleanupToken}',
    ).create();
    final quarantine =
        '${Directory(paths.directory).parent.path}.cleanup.${paths.vmCleanupToken}';
    await Link(quarantine).create(target.path);

    await expectLater(
      layout.remove(paths),
      throwsA(isA<FileSystemException>()),
    );

    expect(await marker.exists(), isTrue);
    expect(await Link(quarantine).exists(), isTrue);
  });

  test('rejects symlink run root and VM directory components', () async {
    final target = await Directory('${root.path}/target').create();
    final linkedRoot = '${root.path}/linked-run';
    await Link(linkedRoot).create(target.path);
    await expectLater(
      DriverRuntimeLayout(linkedRoot).create(_correlation),
      throwsA(isA<FileSystemException>()),
    );

    final runRoot = await Directory('${root.path}/run').create();
    await Link('${runRoot.path}/${_vmId.value}').create(target.path);
    await expectLater(
      DriverRuntimeLayout(runRoot.path).create(_correlation),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.list().isEmpty, isTrue);
  });

  test('cleanup never removes a replacement generation directory', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    final displaced = '${paths.directory}.owned';
    await Directory(paths.directory).rename(displaced);
    await Directory(paths.directory).create();
    final replacement = File('${paths.directory}/replacement');
    await replacement.writeAsString('foreign');

    await layout.remove(paths);

    expect(await replacement.readAsString(), 'foreign');
    expect(await Directory(displaced).exists(), isTrue);
  });

  test('cleanup refuses an occupied quarantine destination', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    final quarantine = await Directory(
      '${paths.directory}.cleanup.${paths.cleanupToken}',
    ).create();

    await expectLater(
      layout.remove(paths),
      throwsA(isA<FileSystemException>()),
    );

    expect(await Directory(paths.directory).exists(), isTrue);
    expect(await quarantine.exists(), isTrue);
  });

  test(
    'duplicate generation publication preserves its owner and removes staging',
    () async {
      final layout = DriverRuntimeLayout('${root.path}/run');
      final paths = await layout.create(_correlation);

      await expectLater(
        layout.create(_correlation),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await Directory(
          '${paths.directory}/.gaovm-owner-${paths.cleanupToken}',
        ).exists(),
        isTrue,
      );
      final entries = await Directory(paths.directory).parent.list().toList();
      expect(
        entries.where((entry) => entry.path.contains('.gaovm-stage-')),
        isEmpty,
      );
      await layout.remove(paths);
    },
  );

  test('cleanup resumes an owned quarantined generation', () async {
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(_correlation);
    final quarantine = '${paths.directory}.cleanup.${paths.cleanupToken}';
    await Directory(paths.directory).rename(quarantine);

    await layout.remove(paths);

    expect(await Directory(quarantine).exists(), isFalse);
    expect(await Directory(paths.directory).parent.exists(), isFalse);
  });

  test(
    'cleanup retries after the VM quarantine destination is freed',
    () async {
      final layout = DriverRuntimeLayout('${root.path}/run');
      final paths = await layout.create(_correlation);
      final vmDirectory = Directory(paths.directory).parent;
      final quarantine = await Directory(
        '${vmDirectory.path}.cleanup.${paths.vmCleanupToken}',
      ).create();

      await expectLater(
        layout.remove(paths),
        throwsA(isA<FileSystemException>()),
      );
      expect(await vmDirectory.exists(), isTrue);
      expect(await quarantine.exists(), isTrue);
      await quarantine.delete();

      await layout.remove(paths);

      expect(await vmDirectory.exists(), isFalse);
    },
  );
}

final _vmId = VmId('vm_01J00000000000000000000000');
final _correlation = DriverCorrelation(
  vmId: _vmId,
  driverGeneration: 1,
  operationId: OperationId('op_01J00000000000000000000000'),
);
