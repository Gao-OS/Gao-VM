import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'missing catalog bindings are reported and catalog failure is not hidden',
    () async {
      final temp =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-scan-');
      final root = await OwnedImageDirectory.open(temp);
      const vm = 'vm_01J00000000000000000000000';
      root.createDirectory(vm).close();
      try {
        final result = await DriverRuntimeDiscovery(
          root: root,
          resolveBinding: (_) async => null,
        ).scan();
        expect(result.records, isEmpty);
        expect(
          result.issues.single.kind,
          DriverDiscoveryIssueKind.missingCatalogBinding,
        );
        final failure = StateError('catalog unavailable');
        await expectLater(
          DriverRuntimeDiscovery(
            root: root,
            resolveBinding: (_) async => throw failure,
          ).scan(),
          throwsA(same(failure)),
        );
        expect(await Directory('${root.path}/$vm').exists(), isTrue);
      } finally {
        root.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('reports unresolved namespaces and preserves unknown files', () async {
    final temp =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvm-scan-');
    final root = await OwnedImageDirectory.open(temp);
    final vm = VmId('vm_01J00000000000000000000000');
    final other = VmId('vm_01J00000000000000000000001');
    final vmDirectory = root.createDirectory(vm.value);
    vmDirectory.createDirectory('1').close();
    vmDirectory.createDirectory('3').close();
    await File('${vmDirectory.path}/notes').writeAsString('preserve');
    const falseMarker = '.gaovm-owner-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    await File(
      '${vmDirectory.path}/$falseMarker',
    ).writeAsString('not a marker directory');
    await Link('${root.path}/${other.value}').create(vmDirectory.path);
    vmDirectory.close();
    try {
      final discovery = DriverRuntimeDiscovery(
        root: root,
        resolveBinding: (_) async => const DriverRecoveryBinding(
          driverGeneration: 2,
          executable: '/opt/driver',
          bundlePath: '/bundle',
        ),
      );
      final result = await discovery.scan();
      expect(result.records, isEmpty);
      expect(
        {for (final issue in result.issues) issue.path: issue.kind},
        {
          '${root.path}/${vm.value}/1':
              DriverDiscoveryIssueKind.missingMetadata,
          '${root.path}/${vm.value}/3': DriverDiscoveryIssueKind.unknownEntry,
          '${root.path}/${vm.value}/notes':
              DriverDiscoveryIssueKind.unknownEntry,
          '${root.path}/${vm.value}/$falseMarker':
              DriverDiscoveryIssueKind.unknownEntry,
          '${root.path}/${other.value}':
              DriverDiscoveryIssueKind.invalidMetadata,
        },
      );
      expect(
        await File('${root.path}/${vm.value}/notes').readAsString(),
        'preserve',
      );
      expect(await Link('${root.path}/${other.value}').exists(), isTrue);
    } finally {
      root.close();
      await temp.delete(recursive: true);
    }
  });

  test(
    'discovers catalog-bound generation records without modifying runtime files',
    () async {
      final temp =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-scan-');
      final layout = DriverRuntimeLayout('${temp.path}/run');
      final vm = VmId('vm_01J00000000000000000000000');
      final correlation = DriverCorrelation(
        vmId: vm,
        driverGeneration: 2,
        operationId: null,
      );
      final paths = await layout.create(correlation);
      await layout.writeMetadata(
        paths,
        correlation: correlation,
        pid: 123,
        executable: '/opt/driver',
        bundlePath: '${temp.path}/bundle',
        createdAt: DateTime.utc(2026),
        processIdentity: const DriverProcessIdentity(
          pid: 123,
          uid: 502,
          executablePath: '/opt/driver',
          startedAtMicroseconds: 100,
        ),
      );
      final root = await OwnedImageDirectory.open(Directory(layout.runRoot));
      try {
        final discovery = DriverRuntimeDiscovery(
          root: root,
          resolveBinding: (id) async => id == vm
              ? DriverRecoveryBinding(
                  driverGeneration: 2,
                  executable: '/opt/driver',
                  bundlePath: '${temp.path}/bundle',
                )
              : null,
        );
        final before = await File(paths.metadataPath).readAsBytes();
        final snapshot = await discovery.scan();
        expect(snapshot.records.single.correlation.vmId, vm);
        expect(snapshot.records.single.correlation.driverGeneration, 2);
        expect(snapshot.issues, isEmpty);
        expect(await File(paths.metadataPath).readAsBytes(), before);
      } finally {
        root.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
