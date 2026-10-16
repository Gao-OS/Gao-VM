import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/candidate_validation_launch.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_component_info.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_release_inspection.dart';
import 'package:gaovmd/src/macos_cold_state_host.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/macos_cold_publication.dart';
import 'package:gaovmd/src/macos_cold_validation.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary;
  late Directory app;
  late _NativeBoundary host;
  _RealNativeBoundary? realHost;
  var retainInputs = false;
  var activeRetirementChecks = 0;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'gvm-release-inspection-',
    );
    temporary = Directory(await created.resolveSymbolicLinks());
    imageFileMode(temporary.path, 0x1c0);
    app = Directory('${temporary.path}/GaoVM.app');
    await _fixture(app);
    host = _NativeBoundary();
    realHost = null;
    retainInputs = false;
  });
  tearDown(() async {
    if (realHost?.retainInputs == true ||
        host.retainInputs ||
        retainInputs ||
        activeRetirementChecks != 0) {
      throw StateError(
        'retaining inputs for unconfirmed native child: ${temporary.path}',
      );
    }
    await temporary.delete(recursive: true);
  });

  Future<Map<String, Object?>> inspect() => inspectMacOsRelease(
    app,
    bundleIdentifier: 'org.gaovm.tests.Release',
    version: '0.1.0',
    teamIdentifier: 'ABCDEFGHIJ',
    catalogSchema: 21,
    host: host,
  );

  test(
    'release inspection binds real private files to native identity and actual role evidence',
    () async {
      final before = await File(
        '${app.path}/Contents/MacOS/gaovmd',
      ).readAsBytes();
      final result = await inspect();
      expect(result['format'], 'gaovm.release-inspection.v1');
      expect(result['compatibility'], 'compatible');
      expect(result['bundle_identifier'], 'org.gaovm.tests.Release');
      expect(result['team_identifier'], 'ABCDEFGHIJ');
      expect(result['version'], '0.1.0');
      expect(result['required_catalog_schema'], 21);
      expect(result['applied_catalog_schema'], isNull);
      expect(result['negotiated_runtime'], 'unobserved');
      final components = result['components'] as Map;
      expect(
        components.keys,
        unorderedEquals(['daemon', 'cli', 'driver-vz', 'service']),
      );
      expect(
        (components['daemon'] as Map)['digest'],
        'sha256:${sha256.convert(before)}',
      );
      expect(
        await File('${app.path}/Contents/MacOS/gaovmd').readAsBytes(),
        before,
      );
      expect(host.executedRoles, ['daemon', 'cli', 'driver-vz', 'service']);
      expect(await temporary.list().length, 1);
    },
  );

  test(
    'cold host rebinds inspected app bytes before its read-only service query',
    () async {
      final cold = await MacOsColdStateHost.open(
        app,
        bundleIdentifier: 'org.gaovm.tests.Release',
        version: '0.1.0',
        teamIdentifier: 'ABCDEFGHIJ',
        catalogSchema: 21,
        host: host,
      );
      try {
        final status = await cold.serviceStatus();
        expect(
          jsonDecode(status.stdout as String)['authorization_state'],
          'notRegistered',
        );
        expect(host.statusCalls, 1);
        final file = File('${app.path}/Contents/MacOS/gaovm-service');
        await file.writeAsBytes([...await file.readAsBytes(), 0]);
        await expectLater(cold.serviceStatus(), throwsFormatException);
        expect(
          host.statusCalls,
          1,
          reason: 'changed helper must not be executed',
        );
      } finally {
        cold.close();
      }
    },
  );

  test(
    'oversized schema evidence is rejected before any candidate code executes',
    () async {
      final schema = File(
        '${app.path}/Contents/Resources/schemas/driver-protocol/v2.schema.json',
      );
      await schema.writeAsString(
        '${' ' * (1024 * 1024)}${await schema.readAsString()}',
      );
      await expectLater(
        inspect(),
        throwsA(
          isA<ReleaseInspectionFailure>().having(
            (e) => e.status,
            'status',
            'incompatible',
          ),
        ),
      );
      expect(host.executedRoles, isEmpty);
    },
  );

  test('native signature refusal precedes every component execution', () async {
    host.rejectSignature = true;
    await expectLater(
      inspect(),
      throwsA(
        isA<ReleaseInspectionFailure>()
            .having((e) => e.stage, 'stage', 'signature')
            .having((e) => e.status, 'status', 'incompatible'),
      ),
    );
    expect(host.executedRoles, isEmpty);
  });

  test(
    'Intel/static verification is unverified, never executable compatibility',
    () async {
      host.nativeArm64 = false;
      await expectLater(
        inspect(),
        throwsA(
          isA<ReleaseInspectionFailure>()
              .having((e) => e.stage, 'stage', 'components')
              .having((e) => e.status, 'status', 'unverified'),
        ),
      );
      expect(host.executedRoles, isEmpty);
    },
  );

  for (final mismatch in ['team', 'runtime', 'entitlements']) {
    test(
      'signed $mismatch mismatch rejects the release before probes',
      () async {
        if (mismatch == 'team') host.metadataTeam = 'ZZZZZZZZZZ';
        if (mismatch == 'runtime') host.runtimeFlag = false;
        if (mismatch == 'entitlements')
          host.extraEntitlements['com.apple.security.get-task-allow'] = true;
        await expectLater(
          inspect(),
          throwsA(
            isA<ReleaseInspectionFailure>().having(
              (e) => e.stage,
              'stage',
              'signature',
            ),
          ),
        );
        expect(host.executedRoles, isEmpty);
      },
    );
  }

  for (final change in [
    {'role': 'daemon'},
    {'version': '0.2.0'},
    {'public_api': 'v2'},
    {'vm_spec': 'gaovm.io/v2'},
  ]) {
    test(
      'actual CLI mismatch $change is incompatible despite matching app metadata',
      () async {
        host.componentChanges['cli'] = change;
        await expectLater(
          inspect(),
          throwsA(
            isA<ReleaseInspectionFailure>()
                .having((e) => e.stage, 'stage', 'components')
                .having((e) => e.status, 'status', 'incompatible'),
          ),
        );
      },
    );
  }

  test(
    'layout and owning launch configuration must match without hidden arguments',
    () async {
      final file = File(
        '${app.path}/Contents/Library/LaunchAgents/gaovmd.plist',
      );
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      value['EnvironmentVariables'] = {'GAOVM_STATE_DIR': '/other'};
      await file.writeAsString(jsonEncode(value));
      await expectLater(
        inspect(),
        throwsA(
          isA<ReleaseInspectionFailure>().having(
            (e) => e.stage,
            'stage',
            'bundle',
          ),
        ),
      );
      expect(host.executedRoles, isEmpty);
    },
  );

  test(
    'signed schema declarations must agree with executable contracts',
    () async {
      final file = File(
        '${app.path}/Contents/Resources/schemas/vm-spec/v1alpha1.schema.json',
      );
      final old = await file.readAsString();
      await file.writeAsString(
        old.replaceAll('gaovm.io/v1alpha1', 'gaovm.io/v2'),
      );
      await expectLater(
        inspect(),
        throwsA(
          isA<ReleaseInspectionFailure>().having(
            (e) => e.stage,
            'stage',
            'schemas',
          ),
        ),
      );
      expect(host.executedRoles, isEmpty);
    },
  );

  test(
    'mutation of an unknown resource during probes is rejected and retained',
    () async {
      final extra = File('${app.path}/Contents/Resources/unknown');
      await extra.writeAsString('before');
      host.onProbe = () async => extra.writeAsString('after!');
      await expectLater(
        inspect(),
        throwsA(
          isA<ReleaseInspectionFailure>().having(
            (e) => e.reason,
            'reason',
            contains('changed after inspection'),
          ),
        ),
      );
      expect(await extra.readAsString(), 'after!');
      expect(host.executedRoles.length, 4);
    },
  );

  test(
    'real native requirement rejects a signed ARM64 ad-hoc fixture without executing it',
    () async {
      final native = realHost = _RealNativeBoundary();
      Future<ProcessResult> run(String executable, List<String> args) async {
        final result = await native.run(executable, args);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result;
      }

      final found = await run('/usr/bin/xcrun', ['--find', 'clang']);
      final sdk = await run('/usr/bin/xcrun', [
        '--sdk',
        'macosx',
        '--show-sdk-path',
      ]);
      final binary = '${temporary.path}/arm64-fixture';
      await run((found.stdout as String).trim(), [
        '-isysroot',
        (sdk.stdout as String).trim(),
        '-target',
        'arm64-apple-macos14.0',
        'test/fixtures/package_fixture.c',
        '-o',
        binary,
      ]);
      const binaries = {
        'Contents/MacOS/gaovmd': '',
        'Contents/MacOS/gaovm': '.cli',
        'Contents/Helpers/gaovm-driver-vz': '.driver',
        'Contents/MacOS/gaovm-service': '.service',
      };
      for (final entry in binaries.entries) {
        final path = '${app.path}/${entry.key}';
        await File(binary).copy(path);
        imageFileMode(path, 0x1ed);
        if (entry.value.isNotEmpty) {
          await run('/usr/bin/codesign', [
            '--force',
            '--sign',
            '-',
            '--timestamp=none',
            '--options',
            'runtime',
            '--identifier',
            'org.gaovm.tests.Release${entry.value}',
            path,
          ]);
        }
      }
      await run('/usr/bin/plutil', [
        '-convert',
        'xml1',
        '${app.path}/Contents/Info.plist',
      ]);
      await run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '--timestamp=none',
        '--options',
        'runtime',
        app.path,
      ]);
      await run('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        app.path,
      ]);
      await expectLater(
        inspectMacOsRelease(
          app,
          bundleIdentifier: 'org.gaovm.tests.Release',
          version: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          catalogSchema: 21,
          host: native,
        ),
        throwsA(
          isA<ReleaseInspectionFailure>().having(
            (e) => e.stage,
            'stage',
            'signature',
          ),
        ),
      );
      expect(
        native.rejectedSignature,
        contains('failed to satisfy specified code requirement'),
      );
      expect(native.executedCandidate, isFalse);
    },
    skip: !Platform.isMacOS,
  );
  group('native cold app retirement', () {
    late Directory state;
    late OwnedImageDirectory storage;
    late ColdStateLease lease;
    late MaintenanceStateFence fence;
    late MacOsColdStateHost original;
    final recoveredHosts = <MacOsColdStateHost>[];
    final inventoryPaths = <String>[];
    String? referencedApp;
    String? unresolvedExecutable;
    Future<DriverInventorySnapshot> inventory(String path) async {
      inventoryPaths.add(path);
      return DriverInventorySnapshot(
        processes: [],
        unresolvedProcessIds: unresolvedExecutable == path ? [pid + 51] : [],
      );
    }

    MacOsOpenReferences observer() => MacOsOpenReferences(
      command: (_, arguments) async => ProcessResult(
        pid,
        referencedApp == arguments.last ? 0 : 1,
        referencedApp == arguments.last ? 'p${pid + 50}\x00ftxt\x00\n' : '',
        '',
      ),
    );
    Future<T> check<T>(Future<T> Function() action) async {
      activeRetirementChecks++;
      try {
        return await action();
      } finally {
        activeRetirementChecks--;
      }
    }

    Future<Map<String, Object?>> retire() async {
      final tree = await MaintenanceTree.open(state);
      try {
        final manifest = await tree.capture(nativeMetadata: true);
        return await lease.retireApp(
          fence,
          storage,
          'old',
          verifyPreparedInputs: () =>
              tree.verify(manifest, nativeMetadata: true),
        );
      } finally {
        tree.close();
      }
    }

    Future<MacOsColdStateHost> reopen({
      String version = '0.1.0',
      String bundle = 'org.gaovm.tests.Release',
      String team = 'ABCDEFGHIJ',
      int schema = 0,
    }) async {
      final recovered = await MacOsColdStateHost.openRetired(
        app,
        state,
        fence,
        storage,
        'old',
        bundleIdentifier: bundle,
        version: version,
        teamIdentifier: team,
        catalogSchema: schema,
        host: host,
        observer: observer(),
        inventory: inventory,
      );
      recoveredHosts.add(recovered);
      return recovered;
    }

    Future<void> assertStateOwner() async {
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(
          await DaemonOwnership.tryAcquireForMaintenance(root, fence),
          isNull,
        );
      } finally {
        root.close();
      }
    }

    Future<Map<String, Object?>> publish({
      Future<void> Function()? verifyInputs,
      bool resume = false,
    }) async {
      final candidate = Directory('${temporary.path}/Candidate.app');
      if (!resume) await _fixture(candidate);
      final tree = await MaintenanceTree.open(candidate);
      final stateTree = await MaintenanceTree.open(state);
      final directory = Directory('${temporary.path}/publications');
      if (!resume) {
        await directory.create();
        imageFileMode(directory.path, 0x1c0);
      }
      final output = await OwnedImageDirectory.open(directory);
      try {
        final before = await stateTree.capture(nativeMetadata: true);
        return await lease.publishCandidate(
          fence,
          output,
          'upgrade',
          candidate,
          version: '0.1.0',
          catalogSchema: 0,
          candidateManifest: await tree.capture(nativeMetadata: true),
          verifyPreparedInputs: () async {
            await verifyInputs?.call();
            await stateTree.verify(before, nativeMetadata: true);
          },
        );
      } finally {
        output.close();
        stateTree.close();
        tree.close();
      }
    }

    Future<MacOsColdStateHost> reopenPublished({
      String version = '0.1.0',
    }) async {
      final output = await OwnedImageDirectory.open(
        Directory('${temporary.path}/publications'),
      );
      try {
        final recovered = await MacOsColdStateHost.openPublished(
          app,
          state,
          fence,
          storage,
          'old',
          output,
          'upgrade',
          bundleIdentifier: 'org.gaovm.tests.Release',
          oldVersion: '0.1.0',
          newVersion: version,
          teamIdentifier: 'ABCDEFGHIJ',
          retiredCatalogSchema: 0,
          catalogSchema: 0,
          host: host,
          observer: observer(),
          inventory: inventory,
        );
        recoveredHosts.add(recovered);
        return recovered;
      } finally {
        output.close();
      }
    }

    setUp(() async {
      inventoryPaths.clear();
      referencedApp = null;
      unresolvedExecutable = null;
      state = await Directory('${temporary.path}/state').create();
      imageFileMode(state.path, 0x1c0);
      await File(
        '${state.path}/unknown-data',
      ).writeAsString('keep original state');
      imageFileMode('${state.path}/unknown-data', 0x180);
      final directory = await Directory(
        '${temporary.path}/retirements',
      ).create();
      imageFileMode(directory.path, 0x1c0);
      storage = await OwnedImageDirectory.open(directory);
      original = await MacOsColdStateHost.open(
        app,
        bundleIdentifier: 'org.gaovm.tests.Release',
        version: '0.1.0',
        teamIdentifier: 'ABCDEFGHIJ',
        catalogSchema: 0,
        host: host,
        observer: observer(),
        inventory: inventory,
      );
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Release',
        host: original,
      );
      fence = await MaintenanceStateFence.begin(lease);
    });
    tearDown(() async {
      if (activeRetirementChecks != 0) {
        retainInputs = true;
        return;
      }
      lease.close();
      fence.close();
      original.close();
      for (final recovered in recoveredHosts) {
        recovered.close();
      }
      recoveredHosts.clear();
      storage.close();
    });

    for (final published in [false, true]) {
      test(
        'whole state preservation reopens native ${published ? 'published' : 'retired'} app provenance without service actions',
        () => check(() async {
          PreservedColdState? preserved;
          final parent = await OwnedImageDirectory.open(temporary);
          final preservation = parent.createDirectory('state-preservation');
          MaintenanceTree? appTree,
              publishedTree,
              stateTree,
              retainedTree,
              recoveryTree;
          try {
            await retire();
            if (published) await publish();
            appTree = await MaintenanceTree.open(Directory(lease.appPath));
            final appBefore = await appTree.capture(nativeMetadata: true);
            Map<String, Object?>? candidateBefore;
            if (published) {
              publishedTree = await MaintenanceTree.open(app);
              candidateBefore = await publishedTree.capture(
                nativeMetadata: true,
              );
            }
            stateTree = await MaintenanceTree.open(state);
            final stateBefore = await stateTree.capture(nativeMetadata: true);
            final admissions = host.admissions;
            preserved = await lease.preserveForRollback(
              fence,
              preservation,
              'current',
              verifyPreparedInputs: () async {
                await appTree!.verify(appBefore, nativeMetadata: true);
                if (publishedTree != null) {
                  await publishedTree.verify(
                    candidateBefore!,
                    nativeMetadata: true,
                  );
                }
                await stateTree!.verify(stateBefore, nativeMetadata: true);
              },
            );
            lease.close();
            await preserved.verify();
            expect(host.admissions, admissions);
            expect(await state.exists(), false);
            expect(preserved.toJson()['service_actions_performed'], false);
            expect(preserved.toJson()['committed'], false);
            retainedTree = await MaintenanceTree.open(
              Directory(preserved.path),
            );
            await retainedTree.verify(stateBefore, nativeMetadata: true);
            await appTree.verify(appBefore, nativeMetadata: true);
            if (publishedTree != null) {
              await publishedTree.verify(
                candidateBefore!,
                nativeMetadata: true,
              );
            }
            final actual = await OwnedImageDirectory.open(
              Directory(preserved.path),
            );
            try {
              final contender = await actual.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              try {
                expect(contender, isNull);
              } finally {
                contender?.close();
              }
            } finally {
              actual.close();
            }
            for (final target in [state, Directory(preserved.path)]) {
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            }
            final retainedPath = preserved.path;
            preserved.close();
            preserved = null;
            fence.close();
            fence = await MaintenanceStateFence.open(state);
            recoveryTree = await MaintenanceTree.open(temporary);
            final recoveryBefore = await recoveryTree.capture(
              nativeMetadata: true,
            );
            final destinationFence = await MaintenanceStateFence.open(
              Directory(retainedPath),
            );
            late MacOsColdStateHost recovered;
            Future<MacOsColdStateHost> reopenPreserved(
              MaintenanceStateFence? origin,
            ) async {
              if (published) {
                final publication = await OwnedImageDirectory.open(
                  Directory('${temporary.path}/publications'),
                );
                try {
                  return await MacOsColdStateHost.openPublished(
                    app,
                    Directory(retainedPath),
                    destinationFence,
                    storage,
                    'old',
                    publication,
                    'upgrade',
                    bundleIdentifier: 'org.gaovm.tests.Release',
                    oldVersion: '0.1.0',
                    newVersion: '0.1.0',
                    teamIdentifier: 'ABCDEFGHIJ',
                    retiredCatalogSchema: 0,
                    catalogSchema: 0,
                    preservedOriginal: origin,
                    host: host,
                    observer: observer(),
                    inventory: inventory,
                  );
                } finally {
                  publication.close();
                }
              } else {
                return await MacOsColdStateHost.openRetired(
                  app,
                  Directory(retainedPath),
                  destinationFence,
                  storage,
                  'old',
                  bundleIdentifier: 'org.gaovm.tests.Release',
                  version: '0.1.0',
                  teamIdentifier: 'ABCDEFGHIJ',
                  catalogSchema: 0,
                  preservedOriginal: origin,
                  host: host,
                  observer: observer(),
                  inventory: inventory,
                );
              }
            }

            try {
              final executions = host.executedRoles.length;
              for (final invalid in <MaintenanceStateFence?>[
                null,
                destinationFence,
              ]) {
                await expectLater(
                  reopenPreserved(invalid),
                  throwsFormatException,
                );
                expect(host.executedRoles.length, executions);
                await recoveryTree.verify(recoveryBefore, nativeMetadata: true);
              }
              recovered = await reopenPreserved(fence);
              recoveredHosts.add(recovered);
            } finally {
              destinationFence.close();
            }
            preserved = await PreservedColdState.open(
              state,
              fence,
              preservation,
              'current',
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: recovered,
            );
            await preserved.verify();
            await recoveryTree.verify(recoveryBefore, nativeMetadata: true);
            await retainedTree.verify(stateBefore, nativeMetadata: true);
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            preserved?.close();
            recoveryTree?.close();
            retainedTree?.close();
            stateTree?.close();
            publishedTree?.close();
            appTree?.close();
            preservation.close();
            parent.close();
          }
        }),
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final published in [false, true]) {
      test(
        'native ${published ? 'published' : 'retired'} app provenance remains valid while the old whole state is restored behind both fences',
        () => check(() async {
          ColdStateLease? oldLease;
          MacOsColdStateHost? oldHost;
          PreservedColdState? preserved;
          ColdStateRestoration? restored;
          MaintenanceTree? oldTree, restoredTree, retainedTree, recoveryTree;
          final parent = await OwnedImageDirectory.open(temporary);
          final work = parent.createDirectory('state-restoration');
          try {
            await retire();
            if (published) await publish();
            final oldApp = Directory('${temporary.path}/OldRestore.app');
            await _fixture(oldApp);
            final oldState = parent.createDirectory('old-state');
            try {
              final data = oldState.createFile('old-generation');
              try {
                final writer = await data.openWrite();
                try {
                  await writer.writeFrom([1, 0, 255]);
                  await writer.flush();
                } finally {
                  await writer.close();
                }
              } finally {
                data.close();
              }
            } finally {
              oldState.close();
            }
            oldHost = await MacOsColdStateHost.open(
              oldApp,
              bundleIdentifier: 'org.gaovm.tests.Release',
              version: '0.1.0',
              teamIdentifier: 'ABCDEFGHIJ',
              catalogSchema: 0,
              host: host,
              observer: observer(),
              inventory: inventory,
            );
            oldLease = await ColdStateLease.acquire(
              Directory('${temporary.path}/old-state'),
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: oldHost,
            );
            oldTree = await MaintenanceTree.open(
              Directory('${temporary.path}/old-state'),
            );
            final oldBefore = await oldTree.capture(nativeMetadata: true);
            preserved = await lease.preserveForRollback(
              fence,
              work,
              'retained-current',
              verifyPreparedInputs: () async {},
            );
            retainedTree = await MaintenanceTree.open(
              Directory(preserved.path),
            );
            final retainedBefore = await retainedTree.capture(
              nativeMetadata: true,
            );
            final admissions = host.admissions;
            restored = await oldLease.restoreForRollback(
              preserved,
              work,
              'restore-old-state',
              verifyPreparedInputs: () async {
                await oldTree!.verify(oldBefore, nativeMetadata: true);
                await retainedTree!.verify(
                  retainedBefore,
                  nativeMetadata: true,
                );
              },
            );
            oldLease.close();
            preserved.close();
            await restored.verify();
            restoredTree = await MaintenanceTree.open(state);
            await restoredTree.verify(oldBefore, nativeMetadata: true);
            await retainedTree.verify(retainedBefore, nativeMetadata: true);
            expect(host.admissions, admissions);
            expect(await app.exists(), published);
            expect(restored.toJson()['installed_pair_restored'], false);
            expect(restored.toJson()['startup_allowed'], false);
            for (final path in [state.path, preserved.path]) {
              final actual = await OwnedImageDirectory.open(Directory(path));
              try {
                final contender = await actual.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                try {
                  expect(contender, isNull);
                } finally {
                  contender?.close();
                }
              } finally {
                actual.close();
              }
              await expectLater(
                MaintenanceStateFence.requireUnfenced(Directory(path)),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            }
            final retainedApp = Directory(lease.appPath);
            restored.close();
            oldHost.close();
            oldHost = null;
            recoveryTree = await MaintenanceTree.open(temporary);
            final recoveryBefore = await recoveryTree.capture(
              nativeMetadata: true,
            );
            final recoveryProbes = <String>[];
            final probeState =
                '${temporary.path}/publications/upgrade/probe/state';
            host.onAdmission = (executable, arguments) async {
              expect(executable, '${app.path}/Contents/MacOS/gaovmd');
              expect(arguments, [
                '--state-dir',
                probeState,
                '--socket-path',
                '$probeState/run/gaovmd.sock',
                '--driver-bin',
                '${app.path}/Contents/Helpers/gaovm-driver-vz',
                '--openapi-path',
                '${app.path}/Contents/Resources/schemas/openapi/gaovm-v1.yaml',
              ]);
              recoveryProbes.add(probeState);
              return null;
            };
            restored = await ColdStateRestoration.open(
              work,
              'restore-old-state',
              stagedOldState: Directory('${temporary.path}/old-state'),
              oldApp: oldApp,
              retainedApp: retainedApp,
              installationApp: app,
              original: fence,
              preservation: (storage: work, name: 'retained-current'),
              bundleIdentifier: 'org.gaovm.tests.Release',
              verifyPreparedInputs: () async {
                await restoredTree!.verify(oldBefore, nativeMetadata: true);
                await retainedTree!.verify(
                  retainedBefore,
                  nativeMetadata: true,
                );
              },
              openOldHost: (_) => MacOsColdStateHost.open(
                oldApp,
                bundleIdentifier: 'org.gaovm.tests.Release',
                version: '0.1.0',
                teamIdentifier: 'ABCDEFGHIJ',
                catalogSchema: 0,
                host: host,
                observer: observer(),
                inventory: inventory,
              ),
              openCurrentHost: (proof, retainedFence) async {
                Future<MacOsColdStateHost> recover(
                  ColdStateRestoration? context,
                ) async {
                  if (!published) {
                    return MacOsColdStateHost.openRetired(
                      app,
                      Directory(preserved!.path),
                      retainedFence,
                      storage,
                      'old',
                      bundleIdentifier: 'org.gaovm.tests.Release',
                      version: '0.1.0',
                      teamIdentifier: 'ABCDEFGHIJ',
                      catalogSchema: 0,
                      preservedOriginal: fence,
                      stateRestoration: context,
                      host: host,
                      observer: observer(),
                      inventory: inventory,
                    );
                  }
                  final publication = await OwnedImageDirectory.open(
                    Directory('${temporary.path}/publications'),
                  );
                  try {
                    return await MacOsColdStateHost.openPublished(
                      app,
                      Directory(preserved!.path),
                      retainedFence,
                      storage,
                      'old',
                      publication,
                      'upgrade',
                      bundleIdentifier: 'org.gaovm.tests.Release',
                      oldVersion: '0.1.0',
                      newVersion: '0.1.0',
                      teamIdentifier: 'ABCDEFGHIJ',
                      retiredCatalogSchema: 0,
                      catalogSchema: 0,
                      preservedOriginal: fence,
                      stateRestoration: context,
                      host: host,
                      observer: observer(),
                      inventory: inventory,
                    );
                  } finally {
                    publication.close();
                  }
                }

                final roles = host.executedRoles.length;
                final statuses = host.statusCalls;
                final probes = host.admissions;
                await expectLater(recover(null), throwsFormatException);
                expect(host.executedRoles.length, roles);
                expect(host.statusCalls, statuses);
                expect(host.admissions, probes);
                return recover(proof);
              },
            );
            await restored.verify();
            await recoveryTree.verify(recoveryBefore, nativeMetadata: true);
            expect(restored.toJson()['startup_allowed'], false);
            expect(recoveryProbes, published ? [probeState] : isEmpty);
            expect(host.admissions, admissions + (published ? 1 : 0));
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            restored?.close();
            preserved?.close();
            oldLease?.close();
            oldHost?.close();
            recoveryTree?.close();
            retainedTree?.close();
            restoredTree?.close();
            oldTree?.close();
            work.close();
            parent.close();
          }
        }),
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'candidate publication requires explicit old-app retirement first',
      () => check(() async {
        await expectLater(publish(), throwsStateError);
        expect(await Directory(app.path).exists(), true);
        expect(
          await File(
            '${temporary.path}/publications/upgrade/intent.json',
          ).exists(),
          false,
        );
        await assertStateOwner();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'candidate publication retains the original app, state owner and startup fence',
      () => check(() async {
        await retire();
        final oldPath = lease.appPath;
        final oldRoot = await OwnedImageDirectory.open(Directory(oldPath));
        final oldIdentity = await oldRoot.maintenanceIdentity();
        oldRoot.close();
        final candidate = Directory('${temporary.path}/Candidate.app');
        await _fixture(candidate);
        await File(
          '${candidate.path}/Contents/Resources/candidate-only',
        ).writeAsString('new candidate');
        imageFileMode(
          '${candidate.path}/Contents/Resources/candidate-only',
          0x180,
        );
        final tree = await MaintenanceTree.open(candidate);
        final stateTree = await MaintenanceTree.open(state);
        final output = await Directory(
          '${temporary.path}/publications',
        ).create();
        imageFileMode(output.path, 0x1c0);
        final publicationStorage = await OwnedImageDirectory.open(output);
        try {
          final manifest = await tree.capture(nativeMetadata: true);
          final before = await stateTree.capture(nativeMetadata: true);
          host.realAdmission = true;
          final result = await lease.publishCandidate(
            fence,
            publicationStorage,
            'upgrade',
            candidate,
            version: '0.1.0',
            catalogSchema: 0,
            candidateManifest: manifest,
            verifyPreparedInputs: () =>
                stateTree.verify(before, nativeMetadata: true),
          );
          expect(result['phase'], 'candidate_published');
          expect(result['installed_candidate_published'], true);
          expect(result['activation_authorized'], false);
          expect(result['rollback_authorized'], false);
          expect(host.admissions, 2);
          expect(lease.appPath, oldPath);
          expect(
            await File(
              '${app.path}/Contents/Resources/candidate-only',
            ).readAsString(),
            'new candidate',
          );
          expect(
            await File(
              '${candidate.path}/Contents/Resources/candidate-only',
            ).readAsString(),
            'new candidate',
          );
          expect(
            await File('${output.path}/upgrade/prepared/record.json').exists(),
            true,
          );
          expect(
            await File(
              '${output.path}/upgrade/candidate/receipt.json',
            ).exists(),
            true,
          );
          expect(
            await Directory(
              '${output.path}/upgrade/candidate/payload.app',
            ).exists(),
            false,
          );
          final retained = await OwnedImageDirectory.open(Directory(oldPath));
          try {
            expect(await retained.maintenanceIdentity(), oldIdentity);
          } finally {
            retained.close();
          }
          await lease.verify();
          await assertStateOwner();
          await stateTree.verify(before, nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          publicationStorage.close();
          stateTree.close();
          tree.close();
        }
      }),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'candidate publication keeps ownership until an unconfirmed owned child actually exits',
      () => check(() async {
        await retire();
        final entered = Completer<void>();
        final exit = Completer<int>();
        host.onAdmission = (_, _) async {
          entered.complete();
          throw MaintenanceCommandFailure(
            'fixture exit is pending',
            pid + 80,
            exitConfirmed: false,
            ownedExit: exit.future,
          );
        };
        final result = publish().then<Object>(
          (value) => value,
          onError: (Object error) => error,
        );
        try {
          await entered.future;
          final settled = await Future.any([
            result.then((_) => true),
            Future<bool>.delayed(const Duration(milliseconds: 30), () => false),
          ]);
          expect(settled, false);
          expect(() => lease.close(), throwsStateError);
          await assertStateOwner();
        } finally {
          if (!exit.isCompleted) exit.complete(-9);
          expect(
            await result,
            isA<MaintenanceCommandFailure>().having(
              (e) => e.exitConfirmed,
              'terminal exit confirmed',
              true,
            ),
          );
        }
        await assertStateOwner();
        expect(maintenancePathEntryExists(app.path), false);
        expect(
          await Directory(
            '${temporary.path}/publications/upgrade/candidate/payload.app',
          ).exists(),
          true,
        );
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'published candidate recovery binds both apps before reacquiring original state ownership',
      () => check(() async {
        await retire();
        await publish();
        lease.close();
        fence.close();
        original.close();
        fence = await MaintenanceStateFence.open(state);
        final output = await OwnedImageDirectory.open(
          Directory('${temporary.path}/publications'),
        );
        try {
          final recovered = await MacOsColdStateHost.openPublished(
            app,
            state,
            fence,
            storage,
            'old',
            output,
            'upgrade',
            bundleIdentifier: 'org.gaovm.tests.Release',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            retiredCatalogSchema: 0,
            catalogSchema: 0,
            host: host,
            observer: observer(),
            inventory: inventory,
          );
          recoveredHosts.add(recovered);
          lease = await ColdStateLease.acquire(
            state,
            bundleIdentifier: 'org.gaovm.tests.Release',
            host: recovered,
            maintenanceFence: fence,
          );
          expect(recovered.publicationEvidence['phase'], 'candidate_published');
          expect(recovered.publicationEvidence['committed'], false);
          expect(lease.appPath, '${storage.path}/old/GaoVM.app');
          inventoryPaths.clear();
          await lease.verify();
          expect(
            inventoryPaths,
            contains(
              '${output.path}/upgrade/candidate/payload.app/Contents/MacOS/gaovmd',
            ),
          );
          await assertStateOwner();
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          output.close();
        }
      }),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final fault in [
      'wrong error',
      'successful startup',
      'scratch write',
    ]) {
      test(
        'candidate publication refuses $fault without moving an app',
        () => check(() async {
          await retire();
          host.onAdmission = (_, arguments) async {
            if (fault == 'wrong error')
              return ProcessResult(pid, 1, '', 'unrelated startup failure\n');
            if (fault == 'successful startup')
              return ProcessResult(pid, 0, 'ready\n', '');
            final probeState = arguments[arguments.indexOf('--state-dir') + 1];
            await File(
              '$probeState/gaovm.db',
            ).writeAsString('unexpected initialization');
            imageFileMode('$probeState/gaovm.db', 0x180);
            return null;
          };
          await expectLater(publish(), throwsA(isA<FormatException>()));
          expect(host.admissions, 1);
          expect(maintenancePathEntryExists(app.path), false);
          expect(
            await Directory(
              '${temporary.path}/publications/upgrade/candidate/payload.app',
            ).exists(),
            true,
          );
          expect(
            await Directory(
              '${temporary.path}/publications/upgrade/prepared',
            ).exists(),
            false,
          );
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'keep original state',
          );
          await assertStateOwner();
          await lease.verify();
          if (fault == 'wrong error') {
            lease.close();
            fence.close();
            original.close();
            fence = await MaintenanceStateFence.open(state);
            final executions = host.executedRoles.length;
            await expectLater(
              reopenPublished(),
              throwsA(isA<FileSystemException>()),
            );
            expect(host.executedRoles.length, executions);
          }
        }),
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    test(
      'last native publication callback cannot hide an unknown state write',
      () => check(() async {
        await retire();
        host.onStatus = () async {
          if (await File(
            '${temporary.path}/publications/upgrade/prepared/record.json',
          ).exists()) {
            await File(
              '${state.path}/unknown-data',
            ).writeAsString('late native write');
          }
        };
        await expectLater(publish(), throwsA(isA<FormatException>()));
        expect(maintenancePathEntryExists(app.path), false);
        expect(
          await Directory(
            '${temporary.path}/publications/upgrade/candidate/payload.app',
          ).exists(),
          true,
        );
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'late native write',
        );
        await assertStateOwner();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'publication never overwrites a foreign app appearing at the final boundary',
      () => check(() async {
        await retire();
        await expectLater(
          publish(
            verifyInputs: () async {
              await app.create();
              imageFileMode(app.path, 0x1c0);
              await File(
                '${app.path}/foreign',
              ).writeAsString('preserve foreign target');
              imageFileMode('${app.path}/foreign', 0x180);
            },
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          await File('${app.path}/foreign').readAsString(),
          'preserve foreign target',
        );
        expect(
          await Directory(
            '${temporary.path}/publications/upgrade/candidate/payload.app',
          ).exists(),
          true,
        );
        await assertStateOwner();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    for (final driver in [false, true]) {
      test(
        'publication retains unresolved staged ${driver ? 'driver' : 'daemon'} PIDs',
        () => check(() async {
          await retire();
          unresolvedExecutable =
              '${temporary.path}/publications/upgrade/candidate/payload.app/${driver ? 'Contents/Helpers/gaovm-driver-vz' : 'Contents/MacOS/gaovmd'}';
          await expectLater(
            publish(),
            throwsA(
              isA<ColdStateFailure>().having(
                (e) => e.stage,
                'stage',
                driver ? 'driver_processes' : 'daemon_processes',
              ),
            ),
          );
          expect(inventoryPaths, contains(unresolvedExecutable));
          expect(maintenancePathEntryExists(app.path), false);
          expect(
            await Directory(
              '${temporary.path}/publications/upgrade/candidate/payload.app',
            ).exists(),
            true,
          );
          await assertStateOwner();
        }),
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    test(
      'post-publication inspection failure retains owners for explicit in-process resume',
      () => check(() async {
        await retire();
        host.onProbe = () async {
          if (maintenancePathEntryExists(app.path) &&
              await File(
                '${temporary.path}/publications/upgrade/prepared/record.json',
              ).exists()) {
            throw StateError('injected installed inspection failure');
          }
        };
        await expectLater(
          publish(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'injected installed inspection failure',
            ),
          ),
        );
        host.onProbe = null;
        await assertStateOwner();
        await lease.verify();
        expect(
          await Directory(
            '${temporary.path}/publications/upgrade/candidate/payload.app',
          ).exists(),
          false,
        );
        expect(await Directory(app.path).exists(), true);
        final output = await OwnedImageDirectory.open(
          Directory('${temporary.path}/publications'),
        );
        try {
          expect(
            await output.tryAcquireMaintenanceLock(
              '.gaovm-candidate-publication.lock',
            ),
            isNull,
          );
        } finally {
          output.close();
        }
        final result = await publish(resume: true);
        expect(result['phase'], 'candidate_published');
        expect(result['committed'], false);
        await assertStateOwner();
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
      }),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'staged candidate recovery resumes only after a fresh original-state owner',
      () => check(() async {
        await retire();
        await expectLater(
          publish(
            verifyInputs: () async {
              throw StateError('operator stopped before publication');
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(maintenancePathEntryExists(app.path), false);
        final sourcePath = '${temporary.path}/Candidate.app';
        final source = await MaintenanceTree.open(Directory(sourcePath));
        final manifest = await source.capture(nativeMetadata: true);
        source.close();
        await Directory(
          sourcePath,
        ).rename('${temporary.path}/Candidate-retained.app');
        lease.close();
        fence.close();
        original.close();
        fence = await MaintenanceStateFence.open(state);
        final recovered = await reopenPublished();
        expect(recovered.publicationEvidence['phase'], 'candidate_staged');
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Release',
          host: recovered,
          maintenanceFence: fence,
        );
        await assertStateOwner();
        final output = await OwnedImageDirectory.open(
          Directory('${temporary.path}/publications'),
        );
        final stateTree = await MaintenanceTree.open(state);
        try {
          final before = await stateTree.capture(nativeMetadata: true);
          final result = await lease.publishCandidate(
            fence,
            output,
            'upgrade',
            Directory(sourcePath),
            version: '0.1.0',
            catalogSchema: 0,
            candidateManifest: manifest,
            verifyPreparedInputs: () =>
                stateTree.verify(before, nativeMetadata: true),
          );
          expect(result['phase'], 'candidate_published');
          expect(result['committed'], false);
          expect(await Directory(sourcePath).exists(), false);
          await stateTree.verify(before, nativeMetadata: true);
          await assertStateOwner();
        } finally {
          output.close();
          stateTree.close();
        }
      }),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final fault in [
      'record',
      'substituted inode',
      'unknown entry',
      'missing lock',
      'both locations',
      'neither location',
      'lock contents',
      'wrong version',
    ]) {
      test(
        'publication recovery rejects $fault before executing any helper',
        () => check(() async {
          await retire();
          await publish();
          lease.close();
          fence.close();
          original.close();
          fence = await MaintenanceStateFence.open(state);
          final root = '${temporary.path}/publications/upgrade';
          switch (fault) {
            case 'record':
              final path = '$root/prepared/record.json';
              imageFileMode(path, 0x180);
              await File(path).writeAsString('malformed record\n');
              imageFileMode(path, 0x100);
            case 'substituted inode':
              await app.rename('${temporary.path}/Published-retained.app');
              await _fixture(app);
            case 'unknown entry':
              await File(
                '$root/unknown',
              ).writeAsString('preserve unknown evidence');
              imageFileMode('$root/unknown', 0x180);
            case 'missing lock':
              await File(
                '${temporary.path}/publications/.gaovm-candidate-publication.lock',
              ).delete();
            case 'both locations':
              await Directory('$root/candidate/payload.app').create();
              imageFileMode('$root/candidate/payload.app', 0x1c0);
            case 'neither location':
              await app.rename('${temporary.path}/Published-retained.app');
            case 'lock contents':
              await File(
                '${temporary.path}/publications/.gaovm-candidate-publication.lock',
              ).writeAsString('preserve unexpected lock bytes');
            case 'wrong version':
              break;
          }
          final executions = host.executedRoles.length;
          await expectLater(
            reopenPublished(
              version: fault == 'wrong version' ? '0.2.0' : '0.1.0',
            ),
            throwsA(
              fault == 'missing lock'
                  ? isA<FileSystemException>()
                  : isA<FormatException>(),
            ),
          );
          expect(host.executedRoles.length, executions);
          expect(
            await Directory(app.path).exists(),
            fault != 'neither location',
          );
          expect(
            await Directory('${storage.path}/old/GaoVM.app').exists(),
            true,
          );
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'keep original state',
          );
          expect(await File('$root/intent.json').exists(), true);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }),
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'retired app recovery reacquires the original state lock under its fence',
      () => check(() async {
        await retire();
        lease.close();
        fence.close();
        original.close();
        fence = await MaintenanceStateFence.open(state);
        final recovered = await MacOsColdStateHost.openRetired(
          app,
          state,
          fence,
          storage,
          'old',
          bundleIdentifier: 'org.gaovm.tests.Release',
          version: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          catalogSchema: 0,
          host: host,
          observer: observer(),
          inventory: inventory,
        );
        recoveredHosts.add(recovered);
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Release',
          host: recovered,
          maintenanceFence: fence,
        );
        expect(lease.installationPath, app.path);
        expect(lease.appPath, '${storage.path}/old/GaoVM.app');
        inventoryPaths.clear();
        await lease.verify();
        expect(inventoryPaths.toSet(), {
          '${app.path}/Contents/MacOS/gaovmd',
          '${app.path}/Contents/Helpers/gaovm-driver-vz',
          '${lease.appPath}/Contents/MacOS/gaovmd',
          '${lease.appPath}/Contents/Helpers/gaovm-driver-vz',
        });
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(
            await DaemonOwnership.tryAcquireForMaintenance(root, fence),
            isNull,
          );
        } finally {
          root.close();
        }
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'keep original state',
        );
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'last cold callback changing persistent state refuses retirement before app movement',
      () => check(() async {
        var changed = false;
        host.onStatus = () async {
          if (!changed &&
              await File('${storage.path}/old/intent.json').exists()) {
            changed = true;
            await File(
              '${state.path}/unknown-data',
            ).writeAsString('late unknown state');
          }
        };
        await expectLater(retire(), throwsA(isA<FormatException>()));
        expect(changed, true);
        expect(maintenancePathEntryExists(app.path), true);
        expect(
          maintenancePathEntryExists('${storage.path}/old/GaoVM.app'),
          false,
        );
        expect(await File('${storage.path}/old/intent.json').exists(), true);
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'late unknown state',
        );
        await lease.verify();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a retired app reference refuses cold verification without releasing state ownership',
      () => check(() async {
        await retire();
        referencedApp = lease.appPath;
        await expectLater(
          lease.verify(),
          throwsA(
            isA<ColdStateFailure>().having(
              (e) => e.stage,
              'stage',
              'app_references',
            ),
          ),
        );
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(
            await DaemonOwnership.tryAcquireForMaintenance(root, fence),
            isNull,
          );
        } finally {
          root.close();
        }
        referencedApp = null;
        await lease.verify();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a pending app retirement refuses close before its final native callback settles',
      () => check(() async {
        final reached = Completer<void>(), finish = Completer<void>();
        host.onProbe = () async {
          if (!maintenancePathEntryExists(app.path) && !reached.isCompleted) {
            reached.complete();
            await finish.future;
          }
        };
        final moving = retire();
        try {
          await reached.future;
          expect(lease.close, throwsStateError);
          final root = await OwnedImageDirectory.open(state);
          try {
            expect(
              await DaemonOwnership.tryAcquireForMaintenance(root, fence),
              isNull,
            );
          } finally {
            root.close();
          }
        } finally {
          finish.complete();
          await moving;
        }
        await lease.verify();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'post-move inspection failure retains the state lock for typed in-process recovery',
      () => check(() async {
        host.onProbe = () async {
          if (!maintenancePathEntryExists(app.path))
            throw StateError('injected after app move');
        };
        await expectLater(retire(), throwsStateError);
        expect(maintenancePathEntryExists(app.path), false);
        expect(await File('${storage.path}/old/intent.json').exists(), true);
        expect(
          await File(
            '${storage.path}/old/GaoVM.app/Contents/MacOS/gaovmd',
          ).exists(),
          true,
        );
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(
            await DaemonOwnership.tryAcquireForMaintenance(root, fence),
            isNull,
          );
        } finally {
          root.close();
        }
        host.onProbe = null;
        final recovered = await MacOsColdStateHost.openRetired(
          app,
          state,
          fence,
          storage,
          'old',
          bundleIdentifier: 'org.gaovm.tests.Release',
          version: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          catalogSchema: 0,
          host: host,
          observer: observer(),
          inventory: inventory,
        );
        recoveredHosts.add(recovered);
        await lease.adoptRetiredApp(recovered, fence);
        await lease.verify();
        expect(lease.installationPath, app.path);
        expect(lease.appPath, recovered.appPath);
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'keep original state',
        );
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    for (final retiredPath in [false, true]) {
      for (final driver in [false, true]) {
        test(
          'unresolved ${driver ? 'driver' : 'daemon'} at ${retiredPath ? 'retired app' : 'missing original slot'} blocks verification',
          () => check(() async {
            await retire();
            final path = retiredPath ? lease.appPath : lease.installationPath;
            unresolvedExecutable = driver
                ? '$path/Contents/Helpers/gaovm-driver-vz'
                : '$path/Contents/MacOS/gaovmd';
            await expectLater(
              lease.verify(),
              throwsA(
                isA<ColdStateFailure>().having(
                  (e) => e.stage,
                  'stage',
                  driver ? 'driver_processes' : 'daemon_processes',
                ),
              ),
            );
            await assertStateOwner();
            unresolvedExecutable = null;
            await lease.verify();
          }),
          timeout: const Timeout(Duration(minutes: 2)),
        );
      }
    }

    test(
      'an occupied original slot is retained and never treated as a published candidate',
      () => check(() async {
        await retire();
        await app.create();
        imageFileMode(app.path, 0x1ed);
        await File('${app.path}/foreign-data').writeAsString('do not replace');
        final foreign = await OwnedImageDirectory.open(app);
        try {
          final identity = await foreign.maintenanceIdentity();
          await expectLater(lease.verify(), throwsA(isA<FormatException>()));
          await assertStateOwner();
          lease.close();
          final executions = host.executedRoles.length;
          await expectLater(reopen(), throwsA(isA<FormatException>()));
          expect(host.executedRoles.length, executions);
          expect(await foreign.maintenanceIdentity(), identity);
          expect(
            await File('${app.path}/foreign-data').readAsString(),
            'do not replace',
          );
          expect(
            await File(
              '${storage.path}/old/GaoVM.app/Contents/MacOS/gaovmd',
            ).exists(),
            true,
          );
        } finally {
          foreign.close();
        }
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );

    for (final mutation in [
      'unknown_entry',
      'intent_mode',
      'intent_target',
      'lock_content',
      'missing_lock',
      'workspace_mode',
      'app_inode',
    ]) {
      test(
        'retirement recovery refuses $mutation before executing any helper',
        () => check(() async {
          await retire();
          final journal = '${storage.path}/old';
          switch (mutation) {
            case 'unknown_entry':
              await File('$journal/foreign').writeAsString('keep me');
            case 'intent_mode':
              imageFileMode('$journal/intent.json', 0x180);
            case 'intent_target':
              final file = File('$journal/intent.json');
              final value = jsonDecode(await file.readAsString()) as Map;
              value['source_state'] = '/test-only/never-follow-journal-paths';
              imageFileMode(file.path, 0x180);
              await file.writeAsString('${jsonEncode(value)}\n');
              imageFileMode(file.path, 0x100);
            case 'lock_content':
              await File(
                '${storage.path}/.gaovm-app-retirement.lock',
              ).writeAsString('unknown owner');
            case 'missing_lock':
              await File(
                '${storage.path}/.gaovm-app-retirement.lock',
              ).rename('${storage.path}/retained-lock');
            case 'workspace_mode':
              imageFileMode(journal, 0x1ed);
            case 'app_inode':
              await Directory(
                '$journal/GaoVM.app',
              ).rename('${storage.path}/retained-original.app');
              await _fixture(Directory('$journal/GaoVM.app'));
          }
          await expectLater(
            lease.verify(),
            throwsA(
              mutation == 'missing_lock'
                  ? isA<FileSystemException>()
                  : isA<FormatException>(),
            ),
          );
          await assertStateOwner();
          lease.close();
          final executions = host.executedRoles.length;
          await expectLater(
            reopen(),
            throwsA(
              mutation == 'missing_lock'
                  ? isA<FileSystemException>()
                  : isA<FormatException>(),
            ),
          );
          expect(host.executedRoles.length, executions);
          expect(await File('$journal/intent.json').exists(), true);
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'keep original state',
          );
          expect(maintenancePathEntryExists(app.path), false);
          if (mutation == 'missing_lock') {
            expect(
              maintenancePathEntryExists(
                '${storage.path}/.gaovm-app-retirement.lock',
              ),
              false,
            );
            expect(await File('${storage.path}/retained-lock').exists(), true);
          }
          if (mutation == 'app_inode')
            expect(
              await Directory('${storage.path}/retained-original.app').exists(),
              true,
            );
        }),
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    for (final mismatch in ['version', 'bundle', 'team', 'catalog']) {
      test(
        'retirement recovery requires explicit matching $mismatch',
        () => check(() async {
          await retire();
          lease.close();
          final executions = host.executedRoles.length;
          await expectLater(
            reopen(
              version: mismatch == 'version' ? '0.2.0' : '0.1.0',
              bundle: mismatch == 'bundle'
                  ? 'org.foreign.Release'
                  : 'org.gaovm.tests.Release',
              team: mismatch == 'team' ? 'KLMNOPQRST' : 'ABCDEFGHIJ',
              schema: mismatch == 'catalog' ? 1 : 0,
            ),
            throwsA(isA<FormatException>()),
          );
          expect(host.executedRoles.length, executions);
          final recovered = await reopen();
          expect(recovered.installationPath, app.path);
        }),
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    test(
      'retirement recovery cannot share a live namespace lock',
      () => check(() async {
        await retire();
        await expectLater(reopen(), throwsStateError);
        await assertStateOwner();
        await lease.verify();
      }),
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: !Platform.isMacOS);

  group('cold publication command', () {
    test(
      'cold commit command requires explicit startup acknowledgement',
      () async {
        final roles = host.executedRoles.length;
        for (final arguments in [
          ['commit-upgrade'],
          ['commit-upgrade', '--allow-startup', '--allow-startup'],
          ['commit-upgrade', '--allow-startup=false'],
          ['resume-commit'],
          ['resume-commit', '--allow-startup', '--allow-startup'],
          ['resume-commit', '--allow-startup=false'],
        ]) {
          await expectLater(
            runMacOsColdPublication(arguments, host: host),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'explicit acknowledgement',
                contains('--allow-startup'),
              ),
            ),
          );
        }
        expect(host.executedRoles.length, roles);
      },
    );

    late Directory state, candidate, work, scratch;
    setUp(() async {
      state = await Directory('${temporary.path}/command-state').create();
      candidate = Directory('${temporary.path}/Candidate.app');
      work = await Directory('${temporary.path}/command-work').create();
      scratch = await Directory(
        '${temporary.path}/command-inspection',
      ).create();
      for (final directory in [state, work, scratch]) {
        imageFileMode(directory.path, 0x1c0);
      }
      final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      database.close();
      imageFileMode('${state.path}/gaovm.db', 0x180);
      await File('${state.path}/unknown-data').writeAsString('retain me');
      imageFileMode('${state.path}/unknown-data', 0x180);
      await _fixture(candidate);
      await File(
        '${candidate.path}/Contents/Resources/new-only',
      ).writeAsString('candidate');
      imageFileMode('${candidate.path}/Contents/Resources/new-only', 0x180);
    });

    List<String> arguments({String? from, int schema = 21}) => [
      from == null ? 'publish-upgrade' : 'resume-publication',
      '--app',
      app.path,
      '--state-dir',
      state.path,
      if (from == null) ...['--candidate-app', candidate.path],
      '--work-dir',
      work.path,
      '--inspection-dir',
      scratch.path,
      '--bundle-id',
      'org.gaovm.tests.Release',
      '--old-version',
      '0.1.0',
      '--new-version',
      '0.1.0',
      '--team-id',
      'ABCDEFGHIJ',
      if (from != null) ...['--from', from, '--catalog-schema', '$schema'],
    ];

    Future<Map<String, Object?>> command(List<String> args) async {
      activeRetirementChecks++;
      try {
        return await runMacOsColdPublication(
          args,
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
          inventory: (_) async =>
              DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
        );
      } finally {
        activeRetirementChecks--;
      }
    }

    Future<void> freshInspection(String name) async {
      scratch = await Directory('${temporary.path}/$name').create();
      imageFileMode(scratch.path, 0x1c0);
    }

    test(
      'outside-app launcher verifies and validates the candidate without ordinary startup',
      () async {
        activeRetirementChecks++;
        MaintenanceTree? pair;
        Directory? shortState;
        var retain = false;
        try {
          shortState = Directory(
            await (await Directory(
              '/private/tmp',
            ).createTemp('gvm-launch-')).resolveSymbolicLinks(),
          );
          imageFileMode(shortState.path, 0x1c0);
          // Keep every copied source/destination in the same private parent.
          // Darwin inherits /private/tmp's group, unlike the system temp tree.
          app = Directory('${shortState.path}/GaoVM.app');
          candidate = Directory('${shortState.path}/Candidate.app');
          await _fixture(app);
          await _fixture(candidate);
          work = await Directory('${shortState.path}/work').create();
          scratch = await Directory(
            '${shortState.path}/publication-inspection',
          ).create();
          for (final directory in [work, scratch]) {
            imageFileMode(directory.path, 0x1c0);
          }
          state = await Directory('${shortState.path}/state').create();
          imageFileMode(state.path, 0x1c0);
          final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
          database.close();
          imageFileMode('${state.path}/gaovm.db', 0x180);
          await command(arguments());
          pair = await MaintenanceTree.open(
            Directory('${work.path}/preparation'),
          );
          final original = await pair.capture(nativeMetadata: true);
          scratch = await Directory(
            '${shortState.path}/launch-inspection',
          ).create();
          imageFileMode(scratch.path, 0x1c0);
          final args = arguments(from: 'publication')..[0] = 'validate-upgrade';
          args.removeRange(args.indexOf('--from'), args.indexOf('--from') + 2);
          ValidationLaunchGrant? observedGrant;
          final result = await runMacOsColdPublication(
            args,
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
            candidateLauncher: (executable, childArguments, nonce) async {
              expect(childArguments.take(2), [
                '--validate-upgrade',
                '--launch-grant-stdin',
              ]);
              expect(childArguments, isNot(contains(nonce)));
              final identity = DriverProcessIdentity(
                pid: pid,
                uid: 501,
                executablePath: executable,
                startedAtMicroseconds: 1,
                pidVersion: 1,
              );
              final grant = ValidationLaunchGrant(
                nonce: nonce,
                process: identity,
              );
              observedGrant = grant;
              final validated = await runMacOsCandidateValidation(
                ['validate-upgrade', ...childArguments.skip(2)],
                host: host,
                observer: MacOsOpenReferences(
                  command: (_, _) async => ProcessResult(pid, 1, '', ''),
                ),
                inventory: (path) async => DriverInventorySnapshot(
                  processes: path == executable ? [identity] : [],
                  unresolvedProcessIds: [],
                ),
                currentExecutable: () async => executable,
                doctorHost: _ValidationDoctorHost(() async {}),
                launchGrant: grant,
              );
              return OwnedCandidateValidationResult(
                ProcessResult(pid, 0, jsonEncode(validated), ''),
                grant,
              );
            },
          );
          expect(observedGrant, isNotNull);
          final intentBytes = await File(
            '${work.path}/validation/intent.json',
          ).readAsString();
          expect(intentBytes, isNot(contains(observedGrant!.nonce)));
          expect(
            (jsonDecode(intentBytes) as Map)['launch_grant_digest'],
            observedGrant!.digest,
          );
          expect(result['phase'], 'candidate_validated');
          expect(result['candidate_exit_confirmed'], true);
          expect(result['post_exit_reverified'], true);
          expect(result['ordinary_ready'], false);
          expect(result['background_workers_started'], false);
          expect(result['driver_sessions_started'], false);
          expect(result['committed'], false);
          expect(result['activation_authorized'], false);
          expect(result['rollback_authorized'], false);
          await pair.verify(original, nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } catch (_) {
          retainInputs = true;
          retain = true;
          rethrow;
        } finally {
          pair?.close();
          activeRetirementChecks--;
          if (retain && shortState != null) {
            print('retain candidate launch state: ${shortState.path}');
          } else {
            await shortState?.delete(recursive: true);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );

    test(
      'validation handoff releases parent app and state references before child creation',
      () async {
        activeRetirementChecks++;
        MaintenanceTree? retainedWork;
        try {
          await command(arguments());
          retainedWork = await MaintenanceTree.open(work);
          final workBefore = await retainedWork.capture(nativeMetadata: true);
          final stateBefore = await File(
            '${state.path}/gaovm.db',
          ).readAsBytes();
          await freshInspection('handoff-references-inspection');
          final args = arguments(from: 'publication')..[0] = 'validate-upgrade';
          args.removeRange(args.indexOf('--from'), args.indexOf('--from') + 2);
          var observed = false;
          await expectLater(
            runMacOsColdPublication(
              args,
              host: host,
              observer: MacOsOpenReferences(
                command: (_, _) async => ProcessResult(pid, 1, '', ''),
              ),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
              candidateLauncher: (_, _, _) async {
                // A separate native observer selects only THIS parent process.
                // Unlike directory(), it opens no observer target in the parent.
                for (final path in [
                  app.path,
                  state.path,
                  '${work.path}/retirement/GaoVM.app',
                  '${work.path}/preparation/candidate-app/payload.app',
                ]) {
                  final references = await runMaintenanceCommand(
                    '/usr/sbin/lsof',
                    ['-nP', '-a', '-p', '$pid', '-F0p', '+D', path],
                  );
                  expect(references.stderr, isEmpty);
                  expect(
                    references.exitCode,
                    1,
                    reason: 'parent still references $path',
                  );
                  expect(
                    references.stdout,
                    isEmpty,
                    reason: 'parent still references $path',
                  );
                }
                final process = await Process.start(
                  Platform.resolvedExecutable,
                  [
                    '--packages=${Directory.current.path}/.dart_tool/package_config.json',
                    '${Directory.current.path}/test/fixtures/candidate_handoff_ownership_probe.dart',
                    state.path,
                    work.path,
                  ],
                  includeParentEnvironment: false,
                  environment: const {'PATH': '/usr/bin:/bin'},
                );
                final probe = OwnedTestProcess(process);
                try {
                  await process.stdin.close();
                  final result = await probe.result(
                    timeout: const Duration(seconds: 30),
                  );
                  expect(result.exitCode, 0, reason: '${result.stderr}');
                  expect(result.stderr, isEmpty);
                  expect(jsonDecode(result.stdout as String), {
                    'state_owned': true,
                    'namespace_locks': 4,
                  });
                } finally {
                  if (!await probe.terminate()) {
                    retainInputs = true;
                    throw StateError(
                      'retain unconfirmed handoff ownership probe',
                    );
                  }
                }
                observed = true;
                throw const FormatException(
                  'controlled refusal after native reference check',
                );
              },
            ),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (failure) => failure.cause,
                'owned handoff boundary',
                isA<FormatException>().having(
                  (error) => error.message,
                  'controlled refusal',
                  'controlled refusal after native reference check',
                ),
              ),
            ),
          );
          expect(observed, true);
          await retainedWork.verify(workBefore, nativeMetadata: true);
          expect(
            await File('${state.path}/gaovm.db').readAsBytes(),
            stateBefore,
          );
          expect(await Directory('${work.path}/validation').exists(), false);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          retainedWork?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );

    for (final failure in [
      'untrusted-signature',
      'live-daemon',
      'unresolved-daemon',
      'live-driver',
      'wrong-schema',
      'partial-validation',
    ]) {
      test(
        'verified validation launch admission refuses $failure before child creation',
        () async {
          activeRetirementChecks++;
          MaintenanceTree? retainedWork, retainedState;
          try {
            await command(arguments());
            if (failure == 'partial-validation') {
              final partial = await Directory(
                '${work.path}/.validation.partial',
              ).create();
              imageFileMode(partial.path, 0x1c0);
            }
            retainedWork = await MaintenanceTree.open(work);
            retainedState = await MaintenanceTree.open(state);
            final workBefore = await retainedWork.capture(nativeMetadata: true);
            final stateBefore = await retainedState.capture(
              nativeMetadata: true,
            );
            await freshInspection('launch-refusal-inspection');
            final args = arguments(
              from: 'publication',
              schema: failure == 'wrong-schema' ? 20 : 21,
            )..[0] = 'validate-upgrade';
            args.removeRange(
              args.indexOf('--from'),
              args.indexOf('--from') + 2,
            );
            host.rejectSignature = failure == 'untrusted-signature';
            var launched = false;
            final executions = host.executedRoles.length;
            await expectLater(
              runMacOsColdPublication(
                args,
                host: host,
                observer: MacOsOpenReferences(
                  command: (_, _) async => ProcessResult(pid, 1, '', ''),
                ),
                inventory: (path) async {
                  final daemon = path == '${app.path}/Contents/MacOS/gaovmd';
                  final driver =
                      path == '${app.path}/Contents/Helpers/gaovm-driver-vz';
                  return DriverInventorySnapshot(
                    processes:
                        (failure == 'live-daemon' && daemon ||
                            failure == 'live-driver' && driver)
                        ? [
                            DriverProcessIdentity(
                              pid: 123,
                              uid: 501,
                              executablePath: path,
                              startedAtMicroseconds: 1,
                              pidVersion: 1,
                            ),
                          ]
                        : [],
                    unresolvedProcessIds:
                        failure == 'unresolved-daemon' && daemon ? [123] : [],
                  );
                },
                candidateLauncher: (_, _, _) async {
                  launched = true;
                  throw StateError(
                    'untrusted or non-cold candidate must never launch',
                  );
                },
              ),
              throwsA(isA<ColdPublicationFailure>()),
            );
            expect(launched, false);
            if ({
              'untrusted-signature',
              'partial-validation',
            }.contains(failure)) {
              expect(host.executedRoles.length, executions);
            }
            expect(await scratch.list().toList(), isEmpty);
            await retainedWork.verify(workBefore, nativeMetadata: true);
            await retainedState.verify(stateBefore, nativeMetadata: true);
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            retainedState?.close();
            retainedWork?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }

    test(
      'candidate validation refuses a different executable before native helpers or state admission',
      () async {
        final before = await File('${state.path}/gaovm.db').readAsBytes();
        final args = arguments(from: 'publication')..[0] = 'validate-upgrade';
        args.removeRange(args.indexOf('--from'), args.indexOf('--from') + 2);
        await expectLater(
          runMacOsCandidateValidation(args, host: host),
          throwsA(
            isA<ColdPublicationFailure>()
                .having((error) => error.stage, 'stage', 'candidate_admission')
                .having(
                  (error) => error.cause,
                  'cause',
                  isA<FormatException>().having(
                    (error) => error.message,
                    'reason',
                    'validation must execute the installed candidate daemon',
                  ),
                ),
          ),
        );
        expect(host.executedRoles, isEmpty);
        expect(await File('${state.path}/gaovm.db').readAsBytes(), before);
        await MaintenanceStateFence.requireUnfenced(state);
        expect(await work.list().toList(), isEmpty);
      },
    );

    for (final invalidNetwork in [false, true]) {
      group(
        'pre-catalog candidate validation ${invalidNetwork ? "invalid-network" : "successful"}',
        () {
          late Directory legacyTemporary,
              legacyApp,
              legacyState,
              legacyWork,
              legacyInspection;
          final legacyHost = _NativeBoundary();
          late Map<String, String> originals;
          late List<String> selectors;
          late File kernel, initrd, disk;
          var active = 0;
          var retain = false;
          var enteredDoctor = false;
          setUpAll(() async {
            active++;
            activeRetirementChecks++;
            try {
              legacyTemporary = Directory(
                await (await Directory(
                  '/private/tmp',
                ).createTemp('gvm-legacy-validation-')).resolveSymbolicLinks(),
              );
              imageFileMode(legacyTemporary.path, 0x1c0);
              legacyApp = Directory('${legacyTemporary.path}/GaoVM.app');
              final candidate = Directory(
                '${legacyTemporary.path}/Candidate.app',
              );
              await _fixture(legacyApp);
              await _fixture(candidate);
              legacyState = await Directory(
                '${legacyTemporary.path}/state',
              ).create();
              legacyWork = await Directory(
                '${legacyTemporary.path}/work',
              ).create();
              final inspection = await Directory(
                '${legacyTemporary.path}/publication-inspection',
              ).create();
              legacyInspection = await Directory(
                '${legacyTemporary.path}/validation-inspection',
              ).create();
              for (final directory in [
                legacyState,
                legacyWork,
                inspection,
                legacyInspection,
              ])
                imageFileMode(directory.path, 0x1c0);
              kernel = await File(
                '${legacyTemporary.path}/kernel',
              ).writeAsString('original kernel bytes');
              initrd = await File(
                '${legacyTemporary.path}/initrd',
              ).writeAsString('original initrd bytes');
              disk = await File(
                '${legacyTemporary.path}/disk.raw',
              ).writeAsString('original guest-mutated disk');
              for (final file in [kernel, initrd, disk]) {
                imageFileMode(file.path, 0x180);
              }
              final config = {
                'cpu': 2,
                'memory': 268435456,
                'boot': {
                  'loader': 'linux',
                  'kernelPath': kernel.path,
                  'initrdPath': initrd.path,
                  'commandLine': 'console=hvc0',
                },
                'disk': {'path': disk.path, 'sizeMiB': 8192},
                'network': {'mode': invalidNetwork ? 'unsupported' : 'shared'},
                'graphics': {'enabled': false, 'width': 1280, 'height': 800},
              };
              originals = {
                'config.json': jsonEncode(config),
                'pending_config.json': jsonEncode({...config, 'cpu': 3}),
                'desired_state.json': jsonEncode({'desired': 'stopped'}),
                'daemon_state.json': jsonEncode({'actual': 'stopped'}),
                'unknown-data': 'retain original legacy bytes',
              };
              for (final entry in originals.entries) {
                final file = await File(
                  '${legacyState.path}/${entry.key}',
                ).writeAsString(entry.value);
                imageFileMode(file.path, 0x180);
              }
              selectors = [
                '--app',
                legacyApp.path,
                '--state-dir',
                legacyState.path,
                '--work-dir',
                legacyWork.path,
                '--bundle-id',
                'org.gaovm.tests.Release',
                '--old-version',
                '0.1.0',
                '--new-version',
                '0.1.0',
                '--team-id',
                'ABCDEFGHIJ',
              ];
              final published = await runMacOsColdPublication(
                [
                  'publish-upgrade',
                  ...selectors,
                  '--candidate-app',
                  candidate.path,
                  '--inspection-dir',
                  inspection.path,
                ],
                host: legacyHost,
                observer: MacOsOpenReferences(
                  command: (_, _) async => ProcessResult(pid, 1, '', ''),
                ),
                inventory: (_) async => DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [],
                ),
              );
              expect(published['observed_catalog_schema'], isNull);
              expect(
                await File('${legacyState.path}/gaovm.db').exists(),
                false,
              );
            } catch (_) {
              retain = true;
              rethrow;
            } finally {
              activeRetirementChecks--;
              active--;
            }
          });
          tearDownAll(() async {
            if (retain || active != 0 || legacyHost.retainInputs) {
              throw StateError(
                'retain legacy validation fixture ${legacyTemporary.path}',
              );
            }
            await legacyTemporary.delete(recursive: true);
          });
          Future<Map<String, Object?>> validate({Directory? inspection}) =>
              runMacOsCandidateValidation(
                [
                  'validate-upgrade',
                  ...selectors,
                  '--inspection-dir',
                  (inspection ?? legacyInspection).path,
                  '--catalog-schema',
                  '0',
                ],
                host: legacyHost,
                currentExecutable: () async =>
                    '${legacyApp.path}/Contents/MacOS/gaovmd',
                doctorHost: _ValidationDoctorHost(() async {
                  enteredDoctor = true;
                }),
                observer: MacOsOpenReferences(
                  command: (_, _) async => ProcessResult(pid, 1, '', ''),
                ),
                inventory: (path) async => DriverInventorySnapshot(
                  processes: path == '${legacyApp.path}/Contents/MacOS/gaovmd'
                      ? [
                          DriverProcessIdentity(
                            pid: pid,
                            uid: 501,
                            executablePath: path,
                            startedAtMicroseconds: 1,
                            pidVersion: 1,
                          ),
                        ]
                      : [],
                  unresolvedProcessIds: [],
                ),
              );
          if (!invalidNetwork)
            test(
              'migrates legacy inputs without changing the retained rollback pair',
              () async {
                active++;
                activeRetirementChecks++;
                MaintenanceTree? pair;
                try {
                  pair = await MaintenanceTree.open(
                    Directory('${legacyWork.path}/preparation'),
                  );
                  final originalPair = await pair.capture(nativeMetadata: true);
                  final report = await validate();
                  expect(enteredDoctor, true);
                  expect(report['phase'], 'candidate_validated');
                  expect(report['applied_catalog_schema'], 21);
                  final ids = report['catalog_identity'] as Map;
                  expect(ids['vm_ids'], hasLength(1));
                  expect(ids['image_ids'], hasLength(2));
                  expect(ids['operation_ids'], hasLength(1));
                  final reader = await GaoVmDatabase.openReadOnly(
                    '${legacyState.path}/gaovm.db',
                  );
                  try {
                    final vm = (await SqliteVmRepository(reader).list()).single;
                    expect(
                      vm.metadata.id.value,
                      (ids['vm_ids'] as List).single,
                    );
                    expect(vm.metadata.name, 'migrated-default');
                    expect(vm.spec.cpu, 3);
                    expect(vm.status.desiredState, DesiredState.stopped);
                    expect(vm.status.phase, VmPhase.stopped);
                    expect(
                      vm.spec.disks.single.source,
                      ExternalDiskSource(disk.path),
                    );
                  } finally {
                    reader.close();
                  }
                  await pair.verify(originalPair, nativeMetadata: true);
                  for (final entry in originals.entries) {
                    expect(
                      await File(
                        '${legacyState.path}/${entry.key}',
                      ).readAsString(),
                      entry.value,
                    );
                    expect(
                      await File(
                        '${legacyWork.path}/preparation/original-state/payload/${entry.key}',
                      ).readAsString(),
                      entry.value,
                    );
                    if (entry.key != 'unknown-data') {
                      expect(
                        await File(
                          '${legacyState.path}/legacy-v1-backup/${entry.key}',
                        ).readAsString(),
                        entry.value,
                      );
                    }
                  }
                  expect(
                    await File(
                      '${legacyWork.path}/preparation/original-state/payload/gaovm.db',
                    ).exists(),
                    false,
                  );
                  expect(await kernel.readAsString(), 'original kernel bytes');
                  expect(await initrd.readAsString(), 'original initrd bytes');
                  expect(
                    await disk.readAsString(),
                    'original guest-mutated disk',
                  );
                  expect(report['background_workers_started'], false);
                  expect(report['driver_sessions_started'], false);
                  expect(report['committed'], false);
                  await expectLater(
                    MaintenanceStateFence.requireUnfenced(legacyState),
                    throwsA(isA<MaintenanceFenceActive>()),
                  );
                } catch (_) {
                  retain = true;
                  rethrow;
                } finally {
                  pair?.close();
                  activeRetirementChecks--;
                  active--;
                }
              },
              timeout: const Timeout(Duration(minutes: 8)),
            );
          if (invalidNetwork)
            test(
              'retains a real migration failure and refuses a blind repeat',
              () async {
                active++;
                activeRetirementChecks++;
                MaintenanceTree? pair, changedState, retainedWork;
                try {
                  pair = await MaintenanceTree.open(
                    Directory('${legacyWork.path}/preparation'),
                  );
                  final originalPair = await pair.capture(nativeMetadata: true);
                  await expectLater(
                    validate(),
                    throwsA(
                      isA<ColdPublicationFailure>()
                          .having(
                            (error) => error.stage,
                            'stage',
                            'controlled_validation',
                          )
                          .having(
                            (error) => error.cause,
                            'cause',
                            isA<FormatException>().having(
                              (error) => error.message,
                              'reason',
                              'unsupported legacy network mode',
                            ),
                          ),
                    ),
                  );
                  expect(enteredDoctor, false);
                  expect(
                    await File(
                      '${legacyWork.path}/validation/intent.json',
                    ).exists(),
                    true,
                  );
                  expect(
                    await FileSystemEntity.type(
                      '${legacyWork.path}/validation/completed',
                      followLinks: false,
                    ),
                    FileSystemEntityType.notFound,
                  );
                  expect(
                    await FileSystemEntity.type(
                      '${legacyState.path}/run/api.sock',
                      followLinks: false,
                    ),
                    FileSystemEntityType.notFound,
                  );
                  final reader = await GaoVmDatabase.openReadOnly(
                    '${legacyState.path}/gaovm.db',
                  );
                  try {
                    expect(await SqliteVmRepository(reader).list(), isEmpty);
                    expect(
                      await ImageStore(
                        reader,
                        Directory('${legacyState.path}/images'),
                      ).list(),
                      hasLength(2),
                    );
                  } finally {
                    reader.close();
                  }
                  await pair.verify(originalPair, nativeMetadata: true);
                  for (final entry in originals.entries) {
                    expect(
                      await File(
                        '${legacyState.path}/${entry.key}',
                      ).readAsString(),
                      entry.value,
                    );
                  }
                  expect(await kernel.readAsString(), 'original kernel bytes');
                  expect(await initrd.readAsString(), 'original initrd bytes');
                  expect(
                    await disk.readAsString(),
                    'original guest-mutated disk',
                  );
                  await expectLater(
                    MaintenanceStateFence.requireUnfenced(legacyState),
                    throwsA(isA<MaintenanceFenceActive>()),
                  );
                  changedState = await MaintenanceTree.open(legacyState);
                  retainedWork = await MaintenanceTree.open(legacyWork);
                  final stateBeforeRetry = await changedState.capture(
                    nativeMetadata: true,
                  );
                  final workBeforeRetry = await retainedWork.capture(
                    nativeMetadata: true,
                  );
                  final fresh = await Directory(
                    '${legacyTemporary.path}/repeat-inspection',
                  ).create();
                  imageFileMode(fresh.path, 0x1c0);
                  final executions = legacyHost.executedRoles.length;
                  await expectLater(
                    validate(inspection: fresh),
                    throwsA(
                      isA<ColdPublicationFailure>()
                          .having(
                            (error) => error.stage,
                            'stage',
                            'candidate_admission',
                          )
                          .having(
                            (error) => error.cause,
                            'cause',
                            isA<FormatException>().having(
                              (error) => error.message,
                              'reason',
                              'unknown, missing or partial maintenance work; retain for investigation',
                            ),
                          ),
                    ),
                  );
                  expect(legacyHost.executedRoles.length, executions);
                  expect(enteredDoctor, false);
                  expect(await fresh.list().toList(), isEmpty);
                  await changedState.verify(
                    stateBeforeRetry,
                    nativeMetadata: true,
                  );
                  await retainedWork.verify(
                    workBeforeRetry,
                    nativeMetadata: true,
                  );
                } catch (_) {
                  retain = true;
                  rethrow;
                } finally {
                  retainedWork?.close();
                  changedState?.close();
                  pair?.close();
                  activeRetirementChecks--;
                  active--;
                }
              },
              timeout: const Timeout(Duration(minutes: 8)),
            );
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }

    group('validation recovery', () {
      late Directory recoveryTemporary, recoveryState, recoveryWork;
      late List<String> recoveryArguments;
      late Map<String, Object?> validated;
      final recoveryHost = _NativeBoundary();
      var retain = false;
      var active = 0;
      MacOsOpenReferences references() => MacOsOpenReferences(
        command: (_, _) async => ProcessResult(pid, 1, '', ''),
      );
      setUpAll(() async {
        active++;
        activeRetirementChecks++;
        try {
          recoveryTemporary = Directory(
            await (await Directory(
              '/private/tmp',
            ).createTemp('gvm-recover-validation-')).resolveSymbolicLinks(),
          );
          imageFileMode(recoveryTemporary.path, 0x1c0);
          final app = Directory('${recoveryTemporary.path}/GaoVM.app');
          final candidate = Directory(
            '${recoveryTemporary.path}/Candidate.app',
          );
          await _fixture(app);
          await _fixture(candidate);
          recoveryState = await Directory(
            '${recoveryTemporary.path}/state',
          ).create();
          recoveryWork = await Directory(
            '${recoveryTemporary.path}/work',
          ).create();
          final publicationInspection = await Directory(
            '${recoveryTemporary.path}/publication-inspection',
          ).create();
          final validationInspection = await Directory(
            '${recoveryTemporary.path}/validation-inspection',
          ).create();
          for (final directory in [
            recoveryState,
            recoveryWork,
            publicationInspection,
            validationInspection,
          ]) {
            imageFileMode(directory.path, 0x1c0);
          }
          final kernel = await File(
            '${recoveryTemporary.path}/kernel',
          ).writeAsString('original recovery kernel');
          final disk = await File(
            '${recoveryTemporary.path}/disk.raw',
          ).writeAsString('original recovery disk');
          for (final file in [kernel, disk]) imageFileMode(file.path, 0x180);
          final inputs = {
            'config.json': jsonEncode({
              'cpu': 2,
              'memory': 268435456,
              'boot': {
                'loader': 'linux',
                'kernelPath': kernel.path,
                'commandLine': 'console=hvc0',
              },
              'disk': {'path': disk.path, 'sizeMiB': 8192},
              'network': {'mode': 'shared'},
              'graphics': {'enabled': false, 'width': 1280, 'height': 800},
            }),
            'desired_state.json': jsonEncode({'desired': 'stopped'}),
            'unknown-data': 'retained before migration',
          };
          for (final entry in inputs.entries) {
            final file = await File(
              '${recoveryState.path}/${entry.key}',
            ).writeAsString(entry.value);
            imageFileMode(file.path, 0x180);
          }
          final selectors = [
            '--app',
            app.path,
            '--state-dir',
            recoveryState.path,
            '--work-dir',
            recoveryWork.path,
            '--bundle-id',
            'org.gaovm.tests.Release',
            '--old-version',
            '0.1.0',
            '--new-version',
            '0.1.0',
            '--team-id',
            'ABCDEFGHIJ',
          ];
          await runMacOsColdPublication(
            [
              'publish-upgrade',
              ...selectors,
              '--candidate-app',
              candidate.path,
              '--inspection-dir',
              publicationInspection.path,
            ],
            host: recoveryHost,
            observer: references(),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          validated = await runMacOsCandidateValidation(
            [
              'validate-upgrade',
              ...selectors,
              '--inspection-dir',
              validationInspection.path,
              '--catalog-schema',
              '0',
            ],
            host: recoveryHost,
            currentExecutable: () async => '${app.path}/Contents/MacOS/gaovmd',
            doctorHost: _ValidationDoctorHost(() async {}),
            observer: references(),
            inventory: (path) async => DriverInventorySnapshot(
              processes: path == '${app.path}/Contents/MacOS/gaovmd'
                  ? [
                      DriverProcessIdentity(
                        pid: pid,
                        uid: 501,
                        executablePath: path,
                        startedAtMicroseconds: 1,
                        pidVersion: 1,
                      ),
                    ]
                  : [],
              unresolvedProcessIds: [],
            ),
          );
          recoveryArguments = [
            'resume-validation',
            ...selectors,
            '--catalog-schema',
            '0',
          ];
        } catch (_) {
          retain = true;
          rethrow;
        } finally {
          activeRetirementChecks--;
          active--;
        }
      });
      tearDownAll(() async {
        if (retain || active != 0 || recoveryHost.retainInputs) {
          throw StateError(
            'retain validation recovery fixture ${recoveryTemporary.path}',
          );
        }
        await recoveryTemporary.delete(recursive: true);
      });

      Future<T> withRecoveredCheckpoint<T>(
        String name,
        Future<T> Function(ColdValidationCheckpoint, OwnedImageDirectory)
        action,
      ) async {
        active++;
        activeRetirementChecks++;
        OwnedImageDirectory? work, inspection;
        MaintenanceStateFence? fence;
        ColdValidationCheckpoint? checkpoint;
        MacOsColdStateHost? coldHost;
        ColdStateLease? lease;
        ColdStateSnapshot? snapshot;
        try {
          final directory = await Directory(
            '${recoveryTemporary.path}/$name',
          ).create();
          imageFileMode(directory.path, 0x1c0);
          inspection = await OwnedImageDirectory.open(directory);
          work = await OwnedImageDirectory.open(recoveryWork);
          fence = await MaintenanceStateFence.open(recoveryState);
          final app = Directory('${recoveryTemporary.path}/GaoVM.app');
          checkpoint = await ColdValidationCheckpoint.open(
            work,
            fence,
            appPath: app.path,
            statePath: recoveryState.path,
            bundleIdentifier: 'org.gaovm.tests.Release',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            sourceCatalogSchema: 0,
          );
          coldHost = await MacOsColdStateHost.openPublished(
            app,
            recoveryState,
            fence,
            work,
            'retirement',
            work,
            'publication',
            bundleIdentifier: 'org.gaovm.tests.Release',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            retiredCatalogSchema: 0,
            catalogSchema: 0,
            host: recoveryHost,
            observer: references(),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          lease = await ColdStateLease.acquire(
            recoveryState,
            bundleIdentifier: 'org.gaovm.tests.Release',
            host: coldHost,
            maintenanceFence: fence,
          );
          snapshot = await ColdStateSnapshot.prepare(
            lease,
            inspection,
            observer: references(),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          await checkpoint.recover(
            snapshot,
            work,
            coldHost,
            inspectionHost: recoveryHost,
            observer: references(),
          );
          return await action(checkpoint, work);
        } catch (_) {
          retain = true;
          rethrow;
        } finally {
          checkpoint?.close();
          snapshot?.close();
          lease?.close();
          coldHost?.close();
          fence?.close();
          inspection?.close();
          work?.close();
          activeRetirementChecks--;
          active--;
        }
      }

      Future<void> restoreSuccessfulTestCommit(OwnedImageDirectory work) async {
        // Test-only restoration after every expected assertion passed. This
        // shared disposable fixture is not a product rollback or failure path.
        final marker = validated['fence_path'] as String;
        final checkpoint = work.directory('commit');
        final parent = await OwnedImageDirectory.open(Directory(marker).parent);
        final retired = checkpoint.directory('retired-fence');
        try {
          final restored = await retired.moveForMaintenanceTo(
            checkpoint,
            parent,
            marker.substring(parent.path.length + 1),
          );
          restored.close();
        } finally {
          retired.close();
          parent.close();
          checkpoint.close();
        }
        await Directory('${work.path}/commit').delete(recursive: true);
        await File('${work.path}/.gaovm-cold-commit.lock').delete();
      }

      test(
        'cold commit preparation seals the validated generation while preserving both states and the fence',
        () async {
          await withRecoveredCheckpoint('commit-preparation-inspection', (
            validation,
            work,
          ) async {
            final current = await MaintenanceTree.open(recoveryState);
            final pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            ColdCommitCheckpoint? commit;
            try {
              final stateBefore = await current.capture(nativeMetadata: true);
              final pairBefore = await pair.capture(nativeMetadata: true);
              commit = await ColdCommitCheckpoint.prepare(
                validation,
                work,
                observer: references(),
              );
              final result = commit.toJson();
              expect(result['format'], 'gaovm.cold-commit-preparation.v1');
              expect(result['phase'], 'cold_commit_prepared');
              expect(result['checkpoint_path'], '${recoveryWork.path}/commit');
              expect(result['ordinary_startup_fenced'], true);
              expect(result['activation_authorized'], false);
              expect(result['committed'], false);
              expect(result['state_unchanged'], true);
              expect(result['public_api_rerun'], false);
              expect(
                result['validation_record_digest'],
                'sha256:${sha256.convert(utf8.encode('${jsonEncode(validated)}\n'))}',
              );
              final sealed = await File(
                '${recoveryWork.path}/commit/prepared/record.json',
              ).readAsString();
              expect(jsonDecode(sealed), result);
              final contender = await work.tryAcquireMaintenanceLock(
                '.gaovm-cold-commit.lock',
                create: false,
              );
              try {
                expect(contender, isNull);
              } finally {
                contender?.close();
              }
              expect(
                await Directory(
                  '${recoveryWork.path}/.commit.partial',
                ).exists(),
                false,
              );
              await current.verify(stateBefore, nativeMetadata: true);
              await pair.verify(pairBefore, nativeMetadata: true);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              commit.close();
              commit = null;
              // Only this proven successful test-owned output is removed so
              // the shared disposable validation fixture remains unchanged.
              await Directory(
                '${recoveryWork.path}/commit',
              ).delete(recursive: true);
              await File(
                '${recoveryWork.path}/.gaovm-cold-commit.lock',
              ).delete();
            } finally {
              commit?.close();
              pair.close();
              current.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      for (final recordPartial in [false, true]) {
        test(
          'cold commit recovery publishes a complete sealed ${recordPartial ? "record" : "directory"} under the fresh cold owner',
          () async {
            await withRecoveredCheckpoint(
              'commit-recovery-${recordPartial ? "record" : "directory"}-inspection',
              (validation, work) async {
                final state = await MaintenanceTree.open(recoveryState);
                final pair = await MaintenanceTree.open(
                  Directory('${recoveryWork.path}/preparation'),
                );
                ColdCommitCheckpoint? commit;
                try {
                  final current = await state.capture(nativeMetadata: true);
                  final original = await pair.capture(nativeMetadata: true);
                  commit = await ColdCommitCheckpoint.prepare(
                    validation,
                    work,
                    observer: references(),
                  );
                  final expected = commit.toJson();
                  final bytes = await File(
                    '${recoveryWork.path}/commit/prepared/record.json',
                  ).readAsBytes();
                  commit.close();
                  commit = null;
                  // Model a fully sealed crash position, not a process-kill E2E.
                  await work.renameDirectoryNoReplace(
                    'commit',
                    '.commit.partial',
                  );
                  if (recordPartial) {
                    final staging = work.directory('.commit.partial');
                    try {
                      await staging.renameDirectoryNoReplace(
                        'prepared',
                        '.prepared.partial',
                      );
                    } finally {
                      staging.close();
                    }
                  }
                  commit = await ColdCommitCheckpoint.open(
                    validation,
                    work,
                    observer: references(),
                  );
                  expect(commit.toJson(), expected);
                  expect(
                    await File(
                      '${recoveryWork.path}/commit/prepared/record.json',
                    ).readAsBytes(),
                    bytes,
                  );
                  expect(
                    await Directory(
                      '${recoveryWork.path}/.commit.partial',
                    ).exists(),
                    false,
                  );
                  await state.verify(current, nativeMetadata: true);
                  await pair.verify(original, nativeMetadata: true);
                  await expectLater(
                    MaintenanceStateFence.requireUnfenced(recoveryState),
                    throwsA(isA<MaintenanceFenceActive>()),
                  );
                  commit.close();
                  commit = null;
                  await Directory(
                    '${recoveryWork.path}/commit',
                  ).delete(recursive: true);
                  await File(
                    '${recoveryWork.path}/.gaovm-cold-commit.lock',
                  ).delete();
                } finally {
                  commit?.close();
                  pair.close();
                  state.close();
                }
              },
            );
          },
          timeout: const Timeout(Duration(minutes: 8)),
        );
      }
      test(
        'cold commit retains its owner until the original native observation exits',
        () async {
          await withRecoveredCheckpoint('commit-owned-exit-inspection', (
            validation,
            work,
          ) async {
            final state = await MaintenanceTree.open(recoveryState);
            final pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            ColdCommitCheckpoint? commit;
            OwnedTestProcess? owned;
            Process? child;
            Future<void>? pending;
            OwnedImageLock? contender;
            Object? failure;
            var settled = false;
            try {
              final current = await state.capture(nativeMetadata: true);
              final original = await pair.capture(nativeMetadata: true);
              child = await Process.start('/bin/cat', []);
              final originalExit = child.exitCode;
              owned = OwnedTestProcess(child);
              final observed = Completer<void>();
              recoveryHost.onStatus = () async {
                recoveryHost.onStatus = null;
                observed.complete();
                throw MaintenanceCommandFailure(
                  'injected pending native observation',
                  child!.pid,
                  exitConfirmed: false,
                  ownedExit: originalExit,
                );
              };
              pending =
                  ColdCommitCheckpoint.prepare(
                    validation,
                    work,
                    observer: references(),
                  ).then<void>(
                    (value) {
                      commit = value;
                      settled = true;
                    },
                    onError: (Object error, StackTrace _) {
                      failure = error;
                      settled = true;
                    },
                  );
              await Future.any([
                observed.future,
                pending.then((_) {
                  throw StateError('commit settled before native observation');
                }),
              ]);
              await Future<void>.delayed(Duration.zero);
              expect(owned.exitConfirmed, false);
              expect(settled, false);
              contender = await work.tryAcquireMaintenanceLock(
                '.gaovm-cold-commit.lock',
                create: false,
              );
              expect(contender, isNull);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              await child.stdin.close();
              expect((await owned.result()).exitCode, 0);
              await pending;
              expect(
                failure,
                isA<MaintenanceCommandFailure>()
                    .having((e) => e.exitConfirmed, 'exit confirmed', true)
                    .having((e) => e.pid, 'original owned PID', child.pid),
              );
              expect(commit, isNull);
              expect(
                await Directory('${work.path}/.commit.partial').exists(),
                false,
              );
              expect(await Directory('${work.path}/commit').exists(), false);
              await state.verify(current, nativeMetadata: true);
              await pair.verify(original, nativeMetadata: true);
              await File('${work.path}/.gaovm-cold-commit.lock').delete();
            } finally {
              recoveryHost.onStatus = null;
              contender?.close();
              await child?.stdin.close();
              if (owned != null && !await owned.terminate()) {
                recoveryHost.retainInputs = true;
              }
              await pending;
              commit?.close();
              pair.close();
              state.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'cold commit rejects a late forged authorization and retains the published output',
        () async {
          await withRecoveredCheckpoint('commit-late-record-inspection', (
            validation,
            work,
          ) async {
            final state = await MaintenanceTree.open(recoveryState);
            final pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            final retained = await MaintenanceTree.open(recoveryWork);
            var changed = false;
            try {
              final current = await state.capture(nativeMetadata: true);
              final original = await pair.capture(nativeMetadata: true);
              final record = File('${work.path}/commit/prepared/record.json');
              recoveryHost.onStatus = () async {
                if (!record.existsSync() || changed) return;
                changed = true;
                final forged =
                    Map<String, Object?>.from(
                        jsonDecode(await record.readAsString()) as Map,
                      )
                      ..['activation_authorized'] = true
                      ..['committed'] = true;
                imageFileMode(record.path, 0x180);
                await record.writeAsString(
                  '${jsonEncode(forged)}\n',
                  flush: true,
                );
                imageFileMode(record.path, 0x100);
              };
              await expectLater(
                ColdCommitCheckpoint.prepare(
                  validation,
                  work,
                  observer: references(),
                ),
                throwsFormatException,
              );
              recoveryHost.onStatus = null;
              expect(changed, true);
              expect(
                (jsonDecode(await record.readAsString()) as Map)['committed'],
                true,
              );
              final outputs = await retained.capture(nativeMetadata: true);
              final roles = recoveryHost.executedRoles.length;
              await expectLater(
                ColdCommitCheckpoint.open(
                  validation,
                  work,
                  observer: references(),
                ),
                throwsFormatException,
              );
              expect(recoveryHost.executedRoles.length, roles);
              await retained.verify(outputs, nativeMetadata: true);
              await state.verify(current, nativeMetadata: true);
              await pair.verify(original, nativeMetadata: true);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              // Product refusal retains this output. Only the now-verified
              // negative test removes its own disposable commit namespace.
              await Directory('${work.path}/commit').delete(recursive: true);
              await File('${work.path}/.gaovm-cold-commit.lock').delete();
            } finally {
              recoveryHost.onStatus = null;
              retained.close();
              pair.close();
              state.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'cold commit rejects a late forged terminal candidate before retiring the fence',
        () async {
          await withRecoveredCheckpoint('commit-terminal-tamper-inspection', (
            validation,
            work,
          ) async {
            final state = await MaintenanceTree.open(recoveryState);
            final pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            final retained = await MaintenanceTree.open(recoveryWork);
            ColdCommitCheckpoint? commit;
            var changed = false;
            try {
              final current = await state.capture(nativeMetadata: true);
              final original = await pair.capture(nativeMetadata: true);
              commit = await ColdCommitCheckpoint.prepare(
                validation,
                work,
                observer: references(),
              );
              final record = File(
                '${work.path}/commit/.completed.partial/record.json',
              );
              recoveryHost.onStatus = () async {
                if (!record.existsSync() || changed) return;
                changed = true;
                final forged = Map<String, Object?>.from(
                  jsonDecode(await record.readAsString()) as Map,
                )..['startup_allowed'] = false;
                imageFileMode(record.path, 0x180);
                await record.writeAsString(
                  '${jsonEncode(forged)}\n',
                  flush: true,
                );
                imageFileMode(record.path, 0x100);
              };
              await expectLater(
                commit.commit(allowStartup: true, observer: references()),
                throwsFormatException,
              );
              recoveryHost.onStatus = null;
              expect(changed, true);
              expect(await record.exists(), true);
              expect(
                await Directory('${work.path}/commit/retired-fence').exists(),
                false,
              );
              expect(
                await Directory('${work.path}/commit/completed').exists(),
                false,
              );
              commit.close();
              commit = null;
              final outputs = await retained.capture(nativeMetadata: true);
              final roles = recoveryHost.executedRoles.length;
              await expectLater(
                ColdCommitCheckpoint.open(
                  validation,
                  work,
                  observer: references(),
                ),
                throwsFormatException,
              );
              expect(recoveryHost.executedRoles.length, roles);
              await retained.verify(outputs, nativeMetadata: true);
              await state.verify(current, nativeMetadata: true);
              await pair.verify(original, nativeMetadata: true);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              // Only this successful negative test removes its own output.
              await Directory('${work.path}/commit').delete(recursive: true);
              await File('${work.path}/.gaovm-cold-commit.lock').delete();
            } finally {
              recoveryHost.onStatus = null;
              commit?.close();
              retained.close();
              pair.close();
              state.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      for (final missing in [false, true]) {
        test(
          'cold commit recovery retains ${missing ? "incomplete" : "unknown"} partial output without promotion',
          () async {
            await withRecoveredCheckpoint(
              'commit-${missing ? "missing" : "unknown"}-inspection',
              (validation, work) async {
                final state = await MaintenanceTree.open(recoveryState);
                final pair = await MaintenanceTree.open(
                  Directory('${recoveryWork.path}/preparation'),
                );
                final retained = await MaintenanceTree.open(recoveryWork);
                ColdCommitCheckpoint? commit;
                try {
                  final current = await state.capture(nativeMetadata: true);
                  final original = await pair.capture(nativeMetadata: true);
                  commit = await ColdCommitCheckpoint.prepare(
                    validation,
                    work,
                    observer: references(),
                  );
                  commit.close();
                  commit = null;
                  await work.renameDirectoryNoReplace(
                    'commit',
                    '.commit.partial',
                  );
                  final partial = '${work.path}/.commit.partial';
                  if (missing) {
                    await File('$partial/prepared/record.json').delete();
                  } else {
                    await File('$partial/unknown').writeAsString('retain me\n');
                    imageFileMode('$partial/unknown', 0x180);
                  }
                  final outputs = await retained.capture(nativeMetadata: true);
                  final roles = recoveryHost.executedRoles.length;
                  await expectLater(
                    ColdCommitCheckpoint.open(
                      validation,
                      work,
                      observer: references(),
                    ),
                    throwsFormatException,
                  );
                  expect(recoveryHost.executedRoles.length, roles);
                  expect(await Directory(partial).exists(), true);
                  expect(
                    await Directory('${work.path}/commit').exists(),
                    false,
                  );
                  await retained.verify(outputs, nativeMetadata: true);
                  await state.verify(current, nativeMetadata: true);
                  await pair.verify(original, nativeMetadata: true);
                  await expectLater(
                    MaintenanceStateFence.requireUnfenced(recoveryState),
                    throwsA(isA<MaintenanceFenceActive>()),
                  );
                  await Directory(partial).delete(recursive: true);
                  await File('${work.path}/.gaovm-cold-commit.lock').delete();
                } finally {
                  commit?.close();
                  retained.close();
                  pair.close();
                  state.close();
                }
              },
            );
          },
          timeout: const Timeout(Duration(minutes: 8)),
        );
      }
      test(
        'cold commit refuses a closed recovered validation before creating output',
        () async {
          await withRecoveredCheckpoint('commit-closed-owner-inspection', (
            validation,
            work,
          ) async {
            final state = await MaintenanceTree.open(recoveryState);
            final retained = await MaintenanceTree.open(recoveryWork);
            try {
              final current = await state.capture(nativeMetadata: true);
              final outputs = await retained.capture(nativeMetadata: true);
              final roles = recoveryHost.executedRoles.length;
              validation.close();
              await expectLater(
                ColdCommitCheckpoint.prepare(
                  validation,
                  work,
                  observer: references(),
                ),
                throwsFormatException,
              );
              expect(recoveryHost.executedRoles.length, roles);
              await retained.verify(outputs, nativeMetadata: true);
              await state.verify(current, nativeMetadata: true);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            } finally {
              retained.close();
              state.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'cold commit allows manual startup only after explicit acknowledgement and full verification',
        () async {
          await withRecoveredCheckpoint('commit-final-inspection', (
            validation,
            work,
          ) async {
            final state = await MaintenanceTree.open(recoveryState);
            final pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            ColdCommitCheckpoint? commit;
            try {
              final current = await state.capture(nativeMetadata: true);
              final original = await pair.capture(nativeMetadata: true);
              final marker = validated['fence_path'] as String;
              final markerBytes = await File(
                '$marker/intent.json',
              ).readAsBytes();
              commit = await ColdCommitCheckpoint.prepare(
                validation,
                work,
                observer: references(),
              );
              final roles = recoveryHost.executedRoles.length;
              await expectLater(
                commit.commit(allowStartup: false, observer: references()),
                throwsFormatException,
              );
              expect(recoveryHost.executedRoles.length, roles);
              await expectLater(
                MaintenanceStateFence.requireUnfenced(recoveryState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              final result = await commit.commit(
                allowStartup: true,
                observer: references(),
              );
              expect(result['format'], 'gaovm.cold-upgrade-commit.v1');
              expect(result['phase'], 'upgrade_committed');
              expect(result['committed'], true);
              expect(result['startup_allowed'], true);
              expect(result['service_actions_performed'], false);
              expect(result['ordinary_ready'], false);
              expect(result['state_unchanged'], true);
              expect(await Directory(marker).exists(), false);
              expect(
                await File(
                  '${work.path}/commit/retired-fence/intent.json',
                ).readAsBytes(),
                markerBytes,
              );
              expect(
                jsonDecode(
                  await File(
                    '${work.path}/commit/completed/record.json',
                  ).readAsString(),
                ),
                result,
              );
              commit.close();
              commit = null;
              // A fully sealed post-retirement placement, not process-kill E2E.
              final checkpoint = work.directory('commit');
              try {
                await checkpoint.renameDirectoryNoReplace(
                  'completed',
                  '.completed.partial',
                );
              } finally {
                checkpoint.close();
              }
              commit = await ColdCommitCheckpoint.open(
                validation,
                work,
                observer: references(),
              );
              expect(
                await commit.commit(allowStartup: true, observer: references()),
                result,
              );
              expect(
                await Directory(
                  '${work.path}/commit/.completed.partial',
                ).exists(),
                false,
              );
              await MaintenanceStateFence.requireUnfenced(recoveryState);
              final root = await OwnedImageDirectory.open(recoveryState);
              DaemonOwnership? contender;
              try {
                contender = await DaemonOwnership.tryAcquire(root);
                expect(contender, isNull);
              } finally {
                contender?.close();
                root.close();
              }
              await state.verify(current, nativeMetadata: true);
              await pair.verify(original, nativeMetadata: true);
              commit.close();
              commit = null;
              await restoreSuccessfulTestCommit(work);
            } finally {
              commit?.close();
              pair.close();
              state.close();
            }
          });
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'cold commit operator preserves both states and refuses a blind repeated commit',
        () async {
          active++;
          activeRetirementChecks++;
          final state = await MaintenanceTree.open(recoveryState);
          final pair = await MaintenanceTree.open(
            Directory('${recoveryWork.path}/preparation'),
          );
          final outputs = await MaintenanceTree.open(recoveryWork);
          OwnedImageDirectory? work;
          try {
            final current = await state.capture(nativeMetadata: true);
            final original = await pair.capture(nativeMetadata: true);
            final inspection = await Directory(
              '${recoveryTemporary.path}/commit-operator-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            final result = await runMacOsColdPublication(
              [
                'commit-upgrade',
                '--allow-startup',
                ...recoveryArguments.skip(1),
                '--inspection-dir',
                inspection.path,
              ],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(result['format'], 'gaovm.cold-upgrade-commit.v1');
            expect(result['action'], 'commit-upgrade');
            expect(result['status'], 'observed');
            expect(result['committed'], true);
            expect(result['startup_allowed'], true);
            expect(result['service_actions_performed'], false);
            expect(result['ordinary_ready'], false);
            expect(result['applied_catalog_schema'], 21);
            await MaintenanceStateFence.requireUnfenced(recoveryState);
            final retained = await outputs.capture(nativeMetadata: true);
            final repeated = await Directory(
              '${recoveryTemporary.path}/commit-blind-retry-inspection',
            ).create();
            imageFileMode(repeated.path, 0x1c0);
            final roles = recoveryHost.executedRoles.length;
            await expectLater(
              runMacOsColdPublication(
                [
                  'commit-upgrade',
                  '--allow-startup',
                  ...recoveryArguments.skip(1),
                  '--inspection-dir',
                  repeated.path,
                ],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async =>
                    throw StateError('no native census on blind retry'),
              ),
              throwsA(
                isA<ColdPublicationFailure>().having(
                  (error) => error.stage,
                  'refusal before native work',
                  'inputs',
                ),
              ),
            );
            expect(recoveryHost.executedRoles.length, roles);
            expect(await repeated.list().toList(), isEmpty);
            await outputs.verify(retained, nativeMetadata: true);
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            final blockedInspection = await Directory(
              '${recoveryTemporary.path}/commit-unresolved-resume-inspection',
            ).create();
            imageFileMode(blockedInspection.path, 0x1c0);
            await expectLater(
              runMacOsColdPublication(
                [
                  'resume-commit',
                  '--allow-startup',
                  ...recoveryArguments.skip(1),
                  '--inspection-dir',
                  blockedInspection.path,
                ],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async => DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [pid + 500],
                ),
              ),
              throwsA(
                isA<ColdPublicationFailure>().having(
                  (error) => error.stage,
                  'unresolved process refusal before state inspection',
                  'cold',
                ),
              ),
            );
            expect(await blockedInspection.list().toList(), isEmpty);
            await outputs.verify(retained, nativeMetadata: true);
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            final resumeInspection = await Directory(
              '${recoveryTemporary.path}/commit-operator-resume-inspection',
            ).create();
            imageFileMode(resumeInspection.path, 0x1c0);
            final recovered = await runMacOsColdPublication(
              [
                'resume-commit',
                '--allow-startup',
                ...recoveryArguments.skip(1),
                '--inspection-dir',
                resumeInspection.path,
              ],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(recovered['committed'], true);
            expect(recovered['startup_allowed'], true);
            expect(recovered['service_actions_performed'], false);
            expect(recovered['action'], 'resume-commit');
            expect(
              recovered['validation_record_digest'],
              result['validation_record_digest'],
            );
            await outputs.verify(retained, nativeMetadata: true);
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            work = await OwnedImageDirectory.open(recoveryWork);
            await restoreSuccessfulTestCommit(work);
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            work?.close();
            outputs.close();
            pair.close();
            state.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'cold commit resumes a sealed terminal candidate retained before fence retirement',
        () async {
          active++;
          activeRetirementChecks++;
          final state = await MaintenanceTree.open(recoveryState);
          final pair = await MaintenanceTree.open(
            Directory('${recoveryWork.path}/preparation'),
          );
          OwnedImageDirectory? work;
          var interrupted = false;
          try {
            final current = await state.capture(nativeMetadata: true);
            final original = await pair.capture(nativeMetadata: true);
            final inspection = await Directory(
              '${recoveryTemporary.path}/commit-before-retirement-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            final record = File(
              '${recoveryWork.path}/commit/.completed.partial/record.json',
            );
            recoveryHost.onStatus = () async {
              if (!record.existsSync() || interrupted) return;
              interrupted = true;
              throw StateError(
                'injected observation failure before retirement',
              );
            };
            await expectLater(
              runMacOsColdPublication(
                [
                  'commit-upgrade',
                  '--allow-startup',
                  ...recoveryArguments.skip(1),
                  '--inspection-dir',
                  inspection.path,
                ],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async => DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [],
                ),
              ),
              throwsA(
                isA<ColdPublicationFailure>().having(
                  (error) => error.stage,
                  'injected pre-retirement interruption',
                  'commit',
                ),
              ),
            );
            recoveryHost.onStatus = null;
            expect(interrupted, true);
            expect(await record.exists(), true);
            expect(
              await Directory(
                '${recoveryWork.path}/commit/retired-fence',
              ).exists(),
              false,
            );
            await expectLater(
              MaintenanceStateFence.requireUnfenced(recoveryState),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            final resumeInspection = await Directory(
              '${recoveryTemporary.path}/commit-before-retirement-resume-inspection',
            ).create();
            imageFileMode(resumeInspection.path, 0x1c0);
            final recovered = await runMacOsColdPublication(
              [
                'resume-commit',
                '--allow-startup',
                ...recoveryArguments.skip(1),
                '--inspection-dir',
                resumeInspection.path,
              ],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(recovered['committed'], true);
            expect(recovered['startup_allowed'], true);
            expect(recovered['service_actions_performed'], false);
            expect(recovered['ordinary_ready'], false);
            expect(recovered['action'], 'resume-commit');
            expect(await record.exists(), false);
            await MaintenanceStateFence.requireUnfenced(recoveryState);
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            work = await OwnedImageDirectory.open(recoveryWork);
            await restoreSuccessfulTestCommit(work);
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            recoveryHost.onStatus = null;
            work?.close();
            pair.close();
            state.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'reopens a sealed result after actual legacy migration without changing either state generation',
        () async {
          active++;
          activeRetirementChecks++;
          MaintenanceTree? state, pair;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/resume-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            state = await MaintenanceTree.open(recoveryState);
            pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            final current = await state.capture(nativeMetadata: true);
            final original = await pair.capture(nativeMetadata: true);
            final recovered = await runMacOsColdPublication(
              [...recoveryArguments, '--inspection-dir', inspection.path],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(recovered['phase'], 'candidate_validation_recovered');
            expect(recovered['completion_checkpoint_promoted'], false);
            expect(recovered['public_api_rerun'], false);
            expect(recovered['state_unchanged'], true);
            expect(recovered['applied_catalog_schema'], 21);
            expect(
              recovered['catalog_identity'],
              validated['catalog_identity'],
            );
            expect(recovered['ordinary_startup_fenced'], true);
            expect(recovered['committed'], false);
            expect(recovered['activation_authorized'], false);
            expect(recovered['rollback_authorized'], false);
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            await expectLater(
              MaintenanceStateFence.requireUnfenced(recoveryState),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            pair?.close();
            state?.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'an owned launch cannot adopt a different sealed validation before native helpers',
        () async {
          active++;
          activeRetirementChecks++;
          MaintenanceTree? state, work;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/foreign-launch-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            final intent =
                jsonDecode(
                      await File(
                        '${recoveryWork.path}/validation/intent.json',
                      ).readAsString(),
                    )
                    as Map;
            final publication = Map<String, Object?>.from(
              intent['publication'] as Map,
            );
            final process = publication.remove('executing_process');
            final grant = ValidationLaunchGrant.fromJson({
              'format': 'gaovm.validation-launch-grant.v1',
              'nonce': 'cd' * 32,
              'process': process,
            });
            state = await MaintenanceTree.open(recoveryState);
            work = await MaintenanceTree.open(recoveryWork);
            final current = await state.capture(nativeMetadata: true);
            final retained = await work.capture(nativeMetadata: true);
            final roles = recoveryHost.executedRoles.length;
            await expectLater(
              runMacOsColdValidationRecovery(
                [...recoveryArguments, '--inspection-dir', inspection.path],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async =>
                    throw StateError('no native census before launch binding'),
                expectedLaunch: ValidationLaunchExpectation(
                  grant: grant,
                  preparationDigest: intent['preparation_digest'] as String,
                  publication: publication,
                  record: validated,
                ),
              ),
              throwsA(
                isA<ColdPublicationFailure>()
                    .having(
                      (failure) => failure.stage,
                      'checkpoint refusal',
                      'validation_checkpoint',
                    )
                    .having(
                      (failure) => failure.cause,
                      'launch mismatch',
                      isA<FormatException>(),
                    ),
              ),
            );
            expect(recoveryHost.executedRoles.length, roles);
            expect(await inspection.list().toList(), isEmpty);
            await state.verify(current, nativeMetadata: true);
            await work.verify(retained, nativeMetadata: true);
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            work?.close();
            state?.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'a modeled bound v2 checkpoint remains recoverable without inventing a launch grant',
        () async {
          active++;
          activeRetirementChecks++;
          final intentFile = File(
            '${recoveryWork.path}/validation/intent.json',
          );
          final recordFile = File(
            '${recoveryWork.path}/validation/completed/record.json',
          );
          final originalIntent = await intentFile.readAsString();
          final originalRecord = await recordFile.readAsString();
          var restore = false;
          Future<void> writeSealed(File file, String bytes) async {
            imageFileMode(file.path, 0x180);
            await file.writeAsString(bytes, flush: true);
            imageFileMode(file.path, 0x100);
          }

          try {
            // Model the previous producer's sealed format on this test-owned
            // workspace. This is compatibility evidence, not an old-binary E2E.
            final intent =
                Map<String, Object?>.from(jsonDecode(originalIntent) as Map)
                  ..['format'] = 'gaovm.candidate-validation-intent.v2'
                  ..remove('launch_grant_digest');
            final encoded = '${jsonEncode(intent)}\n';
            final record =
                Map<String, Object?>.from(jsonDecode(originalRecord) as Map)
                  ..['intent_digest'] =
                      'sha256:${sha256.convert(utf8.encode(encoded))}';
            restore = true;
            await writeSealed(intentFile, encoded);
            await writeSealed(recordFile, '${jsonEncode(record)}\n');
            final inspection = await Directory(
              '${recoveryTemporary.path}/v2-compatibility-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            final recovered = await runMacOsColdPublication(
              [...recoveryArguments, '--inspection-dir', inspection.path],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(recovered['phase'], 'candidate_validation_recovered');
            expect(recovered['public_api_rerun'], false);
            expect(recovered['state_unchanged'], true);
            expect(recovered['committed'], false);
            expect(recovered['activation_authorized'], false);
            expect(recovered['rollback_authorized'], false);
            await writeSealed(intentFile, originalIntent);
            await writeSealed(recordFile, originalRecord);
            restore = false;
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            // A failure retains the modeled checkpoint for diagnosis rather
            // than rewriting uncertain inputs as a teardown side effect.
            if (restore) retain = true;
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'wrong original schema refuses before native helpers or inspection writes',
        () async {
          active++;
          activeRetirementChecks++;
          MaintenanceTree? state, work;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/wrong-schema-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            state = await MaintenanceTree.open(recoveryState);
            work = await MaintenanceTree.open(recoveryWork);
            final current = await state.capture(nativeMetadata: true);
            final retained = await work.capture(nativeMetadata: true);
            final roles = recoveryHost.executedRoles.length;
            final arguments = [...recoveryArguments];
            arguments[arguments.indexOf('--catalog-schema') + 1] = '21';
            await expectLater(
              runMacOsColdPublication(
                [...arguments, '--inspection-dir', inspection.path],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async => throw StateError(
                  'no native census before checkpoint binding',
                ),
              ),
              throwsA(
                isA<ColdPublicationFailure>().having(
                  (failure) => failure.stage,
                  'checkpoint refusal',
                  'validation_checkpoint',
                ),
              ),
            );
            expect(recoveryHost.executedRoles.length, roles);
            expect(await inspection.list().toList(), isEmpty);
            await state.verify(current, nativeMetadata: true);
            await work.verify(retained, nativeMetadata: true);
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            work?.close();
            state?.close();
            activeRetirementChecks--;
            active--;
          }
        },
      );
      test(
        'promotes only a complete sealed completion checkpoint without repeating validation',
        () async {
          active++;
          activeRetirementChecks++;
          MaintenanceTree? state, pair;
          OwnedImageDirectory? journal;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/partial-completion-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            state = await MaintenanceTree.open(recoveryState);
            pair = await MaintenanceTree.open(
              Directory('${recoveryWork.path}/preparation'),
            );
            final current = await state.capture(nativeMetadata: true);
            final original = await pair.capture(nativeMetadata: true);
            final record = await File(
              '${recoveryWork.path}/validation/completed/record.json',
            ).readAsBytes();
            journal = await OwnedImageDirectory.open(
              Directory('${recoveryWork.path}/validation'),
            );
            await journal.renameDirectoryNoReplace(
              'completed',
              '.completed.partial',
            );
            await journal.sync();
            final recovered = await runMacOsColdPublication(
              [...recoveryArguments, '--inspection-dir', inspection.path],
              host: recoveryHost,
              observer: references(),
              inventory: (_) async => DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              ),
            );
            expect(recovered['phase'], 'candidate_validation_recovered');
            expect(recovered['completion_checkpoint_promoted'], true);
            expect(recovered['public_api_rerun'], false);
            expect(recovered['state_unchanged'], true);
            expect(
              recovered['catalog_identity'],
              validated['catalog_identity'],
            );
            expect(recovered['committed'], false);
            expect(recovered['activation_authorized'], false);
            expect(recovered['rollback_authorized'], false);
            expect(
              await File('${journal.path}/completed/record.json').readAsBytes(),
              record,
            );
            expect(
              await Directory('${journal.path}/.completed.partial').exists(),
              false,
            );
            await state.verify(current, nativeMetadata: true);
            await pair.verify(original, nativeMetadata: true);
            await expectLater(
              MaintenanceStateFence.requireUnfenced(recoveryState),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            journal?.close();
            pair?.close();
            state?.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
      test(
        'unknown partial completion is retained before any native helper runs',
        () async {
          active++;
          activeRetirementChecks++;
          OwnedImageDirectory? journal;
          MaintenanceTree? state, work;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/unknown-completion-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            journal = await OwnedImageDirectory.open(
              Directory('${recoveryWork.path}/validation'),
            );
            await journal.renameDirectoryNoReplace(
              'completed',
              '.completed.partial',
            );
            final unknown = await File(
              '${journal.path}/.completed.partial/unknown',
            ).writeAsString('retain unrecognized completion');
            imageFileMode(unknown.path, 0x180);
            state = await MaintenanceTree.open(recoveryState);
            work = await MaintenanceTree.open(recoveryWork);
            final current = await state.capture(nativeMetadata: true);
            final retained = await work.capture(nativeMetadata: true);
            final roles = recoveryHost.executedRoles.length;
            await expectLater(
              runMacOsColdPublication(
                [...recoveryArguments, '--inspection-dir', inspection.path],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async =>
                    throw StateError('no census before sealed checkpoint'),
              ),
              throwsA(
                isA<ColdPublicationFailure>().having(
                  (failure) => failure.stage,
                  'checkpoint refusal',
                  'validation_checkpoint',
                ),
              ),
            );
            expect(recoveryHost.executedRoles.length, roles);
            expect(await inspection.list().toList(), isEmpty);
            await state.verify(current, nativeMetadata: true);
            await work.verify(retained, nativeMetadata: true);
            // Only after the expected refusal is proved, remove our own marker
            // and restore this shared disposable fixture's original namespace.
            await unknown.delete();
            await journal.renameDirectoryNoReplace(
              '.completed.partial',
              'completed',
            );
            await journal.sync();
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            work?.close();
            state?.close();
            journal?.close();
            activeRetirementChecks--;
            active--;
          }
        },
      );
      for (final censusCase in [
        'candidate self',
        'unresolved daemon',
        'live driver',
      ]) {
        test(
          'recovery rejects $censusCase without a validating-self exception',
          () async {
            active++;
            activeRetirementChecks++;
            MaintenanceTree? state, work;
            try {
              final inspection = await Directory(
                '${recoveryTemporary.path}/refused-${censusCase.replaceAll(' ', '-')}-inspection',
              ).create();
              imageFileMode(inspection.path, 0x1c0);
              state = await MaintenanceTree.open(recoveryState);
              work = await MaintenanceTree.open(recoveryWork);
              final current = await state.capture(nativeMetadata: true);
              final retained = await work.capture(nativeMetadata: true);
              final driver = censusCase == 'live driver';
              await expectLater(
                runMacOsColdPublication(
                  [...recoveryArguments, '--inspection-dir', inspection.path],
                  host: recoveryHost,
                  observer: references(),
                  inventory: (path) async {
                    final selected = path.endsWith('gaovm-driver-vz') == driver;
                    return DriverInventorySnapshot(
                      processes: selected && censusCase != 'unresolved daemon'
                          ? [
                              DriverProcessIdentity(
                                pid: pid,
                                uid: 501,
                                executablePath: path,
                                startedAtMicroseconds: 1,
                                pidVersion: 1,
                              ),
                            ]
                          : [],
                      unresolvedProcessIds:
                          selected && censusCase == 'unresolved daemon'
                          ? [pid]
                          : [],
                    );
                  },
                ),
                throwsA(
                  isA<ColdPublicationFailure>()
                      .having(
                        (failure) => failure.stage,
                        'cold refusal',
                        'cold',
                      )
                      .having(
                        (failure) => failure.cause,
                        'zero-process boundary',
                        isA<ColdStateFailure>().having(
                          (error) => error.stage,
                          'native census',
                          driver ? 'driver_processes' : 'daemon_processes',
                        ),
                      ),
                ),
              );
              expect(await inspection.list().toList(), isEmpty);
              await state.verify(current, nativeMetadata: true);
              await work.verify(retained, nativeMetadata: true);
            } catch (_) {
              retain = true;
              rethrow;
            } finally {
              work?.close();
              state?.close();
              activeRetirementChecks--;
              active--;
            }
          },
        );
      }
      test(
        'changed historical kernel blocks recovery even after migration removed its live reference',
        () async {
          active++;
          activeRetirementChecks++;
          MaintenanceTree? state, work;
          try {
            final inspection = await Directory(
              '${recoveryTemporary.path}/changed-original-kernel-inspection',
            ).create();
            imageFileMode(inspection.path, 0x1c0);
            await File('${recoveryTemporary.path}/kernel').writeAsString(
              'changed original kernel after candidate validation',
            );
            state = await MaintenanceTree.open(recoveryState);
            work = await MaintenanceTree.open(recoveryWork);
            final current = await state.capture(nativeMetadata: true);
            final retained = await work.capture(nativeMetadata: true);
            await expectLater(
              runMacOsColdPublication(
                [...recoveryArguments, '--inspection-dir', inspection.path],
                host: recoveryHost,
                observer: references(),
                inventory: (_) async => DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [],
                ),
              ),
              throwsA(
                isA<ColdPublicationFailure>()
                    .having(
                      (failure) => failure.stage,
                      'original evidence check',
                      'retained_validation',
                    )
                    .having(
                      (failure) => failure.cause,
                      'unchanged original dependency required',
                      isA<FormatException>().having(
                        (error) => error.message,
                        'original dependency seal',
                        'original external file changed after validation',
                      ),
                    ),
              ),
            );
            await state.verify(current, nativeMetadata: true);
            await work.verify(retained, nativeMetadata: true);
            await expectLater(
              MaintenanceStateFence.requireUnfenced(recoveryState),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retain = true;
            rethrow;
          } finally {
            work?.close();
            state?.close();
            activeRetirementChecks--;
            active--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }, timeout: const Timeout(Duration(minutes: 8)));

    group('candidate validation', () {
      late Directory publishedTemporary,
          publishedApp,
          publishedState,
          publishedWork,
          validationInspection;
      late _NativeBoundary validationHost;
      late Artifact artifact;
      late Image validationImage;
      late VmId validationVm;
      late TestRun validationRun;
      late List<String> validateArguments;
      const payload = [0, 255, 10, 13, 128, 1];
      var activeValidation = 0;
      setUpAll(() async {
        activeValidation++;
        activeRetirementChecks++;
        try {
          final created = await Directory(
            '/private/tmp',
          ).createTemp('gvm-validation-');
          publishedTemporary = Directory(await created.resolveSymbolicLinks());
          imageFileMode(publishedTemporary.path, 0x1c0);
          publishedApp = Directory('${publishedTemporary.path}/GaoVM.app');
          final candidate = Directory(
            '${publishedTemporary.path}/Candidate.app',
          );
          await _fixture(publishedApp);
          await _fixture(candidate);
          publishedState = await Directory(
            '${publishedTemporary.path}/state',
          ).create();
          publishedWork = await Directory(
            '${publishedTemporary.path}/work',
          ).create();
          final publicationInspection = await Directory(
            '${publishedTemporary.path}/publication-inspection',
          ).create();
          validationInspection = await Directory(
            '${publishedTemporary.path}/validation-inspection',
          ).create();
          for (final directory in [
            publishedState,
            publishedWork,
            publicationInspection,
            validationInspection,
          ]) {
            imageFileMode(directory.path, 0x1c0);
          }
          validationHost = _NativeBoundary();
          final state = publishedState;
          final writer = await GaoVmDatabase.open('${state.path}/gaovm.db');
          imageFileMode('${state.path}/gaovm.db', 0x180);
          await File('${state.path}/unknown-data').writeAsString('retain me');
          imageFileMode('${state.path}/unknown-data', 0x180);
          final artifactDirectory = await Directory(
            '${state.path}/artifacts',
          ).create();
          imageFileMode(artifactDirectory.path, 0x1c0);
          final artifactRoot = await OwnedImageDirectory.open(
            artifactDirectory,
          );
          try {
            validationImage =
                await ImageStore(
                  writer,
                  Directory('${state.path}/images'),
                ).importFile(
                  await File(
                    '${publishedTemporary.path}/seed.raw',
                  ).writeAsString('retained validation disk'),
                  type: ImageType.rawDisk,
                );
            final vmDirectory = await Directory('${state.path}/vms').create();
            imageFileMode(vmDirectory.path, 0x1c0);
            final bundles = await OwnedImageDirectory.open(vmDirectory);
            final images = await OwnedImageDirectory.open(
              Directory('${state.path}/images'),
            );
            try {
              final accepted =
                  await SqliteVmCreateAcceptance(
                    database: writer,
                    idempotencyRetention: const Duration(days: 30),
                  ).create(
                    VmCreateCommand(
                      requestId: RequestId.generate(),
                      idempotencyKey: null,
                      requestBody: const [],
                      name: 'retained-validation-vm',
                      spec: VmSpec(
                        cpu: 1,
                        memoryBytes: 268435456,
                        boot: EfiBoot(),
                        disks: [
                          VmDisk(
                            id: 'root',
                            source: ManagedImageDiskSource(validationImage.id),
                            writable: true,
                          ),
                        ],
                        networks: [DisconnectedNetwork(id: 'net0')],
                        graphics: GraphicsConfig(enabled: false),
                        serial: const SerialConfig(
                          enabled: true,
                          capture: true,
                        ),
                        guestAgent: GuestAgentConfig(
                          enabled: false,
                          requiredForReady: false,
                        ),
                        restartPolicy: RestartPolicy.never,
                      ),
                    ),
                  );
              validationVm = accepted.resourceId as VmId;
              final provisioned = (await VmProvisioningWorker(
                work: SqliteVmProvisioningWorkRepository(writer),
                bundles: VmBundleStore(
                  database: writer,
                  bundles: bundles,
                  images: images,
                ),
                owner: 'candidate-validation-fixture',
              ).dispatchOnce()).single;
              expect(
                provisioned.completion,
                VmProvisioningCompletionKind.succeeded,
              );
            } finally {
              images.close();
              bundles.close();
            }
            final runs = SqliteTestRunRepository(
              writer,
              now: () => DateTime.utc(2000),
            );
            final run = await runs.create(
              spec: TestRunSpec(
                source: ImageTestRunSource(validationImage.id),
                wait: VmWaitSpec(
                  condition: WaitCondition.guestAgentReady,
                  timeoutSeconds: 30,
                ),
                steps: [
                  TestStepRequest(
                    argv: ['must-not-run-in-validation'],
                    timeoutSeconds: 60,
                  ),
                ],
                cleanup: CleanupPolicy.deleteOnSuccess,
                retainOnFailure: true,
              ),
              requestId: RequestId.generate(),
            );
            await runs.transition(
              run.id,
              expectedState: TestRunState.pending,
              nextState: TestRunState.provisioning,
            );
            await runs.requestCancel(run.id);
            await runs.transition(
              run.id,
              expectedState: TestRunState.provisioning,
              nextState: TestRunState.collecting,
              vmId: validationVm,
              outcome: TestRunState.cancelled,
            );
            await SqliteIdempotencyRepository(
              writer,
              retention: const Duration(days: 1),
              now: () => DateTime.utc(2000),
            ).execute(
              scope: 'validation-retention-probe',
              key: 'retain-expired',
              requestBody: const [],
              action: () async => IdempotencyResponse(JsonObjectValue.empty),
            );
            artifact =
                await ArtifactApplicationService(
                  database: writer,
                  directory: artifactRoot,
                ).publish(
                  bytes: Stream.value(payload),
                  kind: ArtifactKind.stdout,
                  contentType: 'application/octet-stream',
                  maxBytes: payload.length,
                  vmId: validationVm,
                  operationId: run.operationId,
                  testRunId: run.id,
                  retentionUntil: DateTime.utc(2000),
                );
            await runs.transition(
              run.id,
              expectedState: TestRunState.collecting,
              nextState: TestRunState.cleaningUp,
              cleanupDecision: 'retain',
            );
            validationRun = await runs.finish(
              run.id,
              outcome: TestRunState.cancelled,
            );
          } finally {
            artifactRoot.close();
            writer.close();
          }
          final selectors = [
            '--app',
            publishedApp.path,
            '--state-dir',
            publishedState.path,
            '--work-dir',
            publishedWork.path,
            '--bundle-id',
            'org.gaovm.tests.Release',
            '--old-version',
            '0.1.0',
            '--new-version',
            '0.1.0',
            '--team-id',
            'ABCDEFGHIJ',
          ];
          await runMacOsColdPublication(
            [
              'publish-upgrade',
              ...selectors,
              '--candidate-app',
              candidate.path,
              '--inspection-dir',
              publicationInspection.path,
            ],
            host: validationHost,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          validateArguments = [
            'validate-upgrade',
            ...selectors,
            '--inspection-dir',
            validationInspection.path,
            '--catalog-schema',
            '21',
          ];
        } finally {
          activeRetirementChecks--;
          activeValidation--;
        }
      });
      tearDownAll(() async {
        if (activeValidation != 0 || validationHost.retainInputs) {
          throw StateError(
            'retain active validation fixture ${publishedTemporary.path}',
          );
        }
        await publishedTemporary.delete(recursive: true);
      });
      for (final refusal in [
        'missing-self',
        'unversioned-self',
        'changed-self',
        'other-daemon',
        'unresolved-daemon',
        'live-driver',
        'unresolved-driver',
      ]) {
        test(
          'refuses $refusal without migrating or writing validation intent',
          () async {
            activeValidation++;
            activeRetirementChecks++;
            try {
              final inspection = await Directory(
                '${publishedTemporary.path}/refuse-$refusal',
              ).create();
              imageFileMode(inspection.path, 0x1c0);
              final arguments = [...validateArguments];
              arguments[arguments.indexOf('--inspection-dir') + 1] =
                  inspection.path;
              final before = await File(
                '${publishedState.path}/gaovm.db',
              ).readAsBytes();
              var selfObservations = 0;
              var enteredDoctor = false;
              final daemon = '${publishedApp.path}/Contents/MacOS/gaovmd';
              final driver =
                  '${publishedApp.path}/Contents/Helpers/gaovm-driver-vz';
              final reason = switch (refusal) {
                'other-daemon' || 'unresolved-daemon' => 'daemon_processes',
                'live-driver' || 'unresolved-driver' => 'driver_processes',
                _ => 'validation_process',
              };
              await expectLater(
                runMacOsCandidateValidation(
                  arguments,
                  host: validationHost,
                  currentExecutable: () async => daemon,
                  doctorHost: _ValidationDoctorHost(() async {
                    enteredDoctor = true;
                  }),
                  observer: MacOsOpenReferences(
                    command: (_, _) async => ProcessResult(pid, 1, '', ''),
                  ),
                  inventory: (path) async {
                    if (path == daemon) selfObservations++;
                    return DriverInventorySnapshot(
                      processes: [
                        if (path == daemon && refusal != 'missing-self')
                          DriverProcessIdentity(
                            pid: pid,
                            uid: 501,
                            executablePath: path,
                            startedAtMicroseconds: 1,
                            pidVersion: refusal == 'unversioned-self'
                                ? null
                                : refusal == 'changed-self' &&
                                      selfObservations > 1
                                ? 2
                                : 1,
                          ),
                        if (path == daemon && refusal == 'other-daemon' ||
                            path == driver && refusal == 'live-driver')
                          DriverProcessIdentity(
                            pid: pid + 1,
                            uid: 501,
                            executablePath: path,
                            startedAtMicroseconds: 2,
                            pidVersion: 2,
                          ),
                      ],
                      unresolvedProcessIds: [
                        if (path == daemon && refusal == 'unresolved-daemon' ||
                            path == driver && refusal == 'unresolved-driver')
                          pid + 1,
                      ],
                    );
                  },
                ),
                throwsA(
                  isA<ColdPublicationFailure>().having(
                    (error) => error.cause,
                    'cold admission reason',
                    isA<ColdStateFailure>().having(
                      (error) => error.stage,
                      'stage',
                      reason,
                    ),
                  ),
                ),
              );
              expect(enteredDoctor, false);
              expect(
                await File('${publishedState.path}/gaovm.db').readAsBytes(),
                before,
              );
              expect(
                await FileSystemEntity.type(
                  '${publishedWork.path}/validation',
                  followLinks: false,
                ),
                FileSystemEntityType.notFound,
              );
              await expectLater(
                MaintenanceStateFence.requireUnfenced(publishedState),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            } finally {
              activeRetirementChecks--;
              activeValidation--;
            }
          },
        );
      }
      test(
        'published candidate validates the populated catalog without workers and retains the fence for explicit commit',
        () async {
          final state = publishedState,
              app = publishedApp,
              work = publishedWork;
          activeValidation++;
          activeRetirementChecks++;
          try {
            var observedRestrictedApi = false;
            final doctor = _ValidationDoctorHost(() async {
              final root = await OwnedImageDirectory.open(state);
              try {
                final competing = await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                try {
                  expect(competing, isNull);
                } finally {
                  competing?.close();
                }
              } finally {
                root.close();
              }
              await expectLater(
                MaintenanceStateFence.requireUnfenced(state),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              final client = HttpClient()
                ..findProxy = ((_) => 'DIRECT')
                ..connectionFactory = (_, _, _) => Socket.startConnect(
                  InternetAddress(
                    '${state.path}/run/api.sock',
                    type: InternetAddressType.unix,
                  ),
                  0,
                );
              try {
                for (final path in [
                  '/v1/vms',
                  '/v1/images',
                  '/v1/operations',
                ]) {
                  final response = await (await client.getUrl(
                    Uri.parse('http://localhost$path'),
                  )).close();
                  expect(response.statusCode, 200);
                  await response.drain<void>();
                }
                final write = await client.postUrl(
                  Uri.parse('http://localhost/v1/vms'),
                );
                write.headers.contentType = ContentType.json;
                write.write('{not-json');
                final refused = await write.close();
                expect(refused.statusCode, 403);
                expect(
                  (jsonDecode(await utf8.decoder.bind(refused).join())
                      as Map)['code'],
                  'INVALID_REQUEST',
                );
                final ready = await (await client.getUrl(
                  Uri.parse('http://localhost/v1/system/ready'),
                )).close();
                expect(ready.statusCode, 503);
                expect(
                  (jsonDecode(await utf8.decoder.bind(ready).join())
                      as Map)['ready'],
                  false,
                );
                final download = await (await client.getUrl(
                  Uri.parse('http://localhost${artifact.downloadUrl}'),
                )).close();
                expect(download.statusCode, 200);
                expect(
                  await download.expand((chunk) => chunk).toList(),
                  payload,
                );
                observedRestrictedApi = true;
              } finally {
                client.close(force: true);
              }
            });
            final report = await runMacOsCandidateValidation(
              validateArguments,
              host: validationHost,
              currentExecutable: () async =>
                  '${app.path}/Contents/MacOS/gaovmd',
              doctorHost: doctor,
              observer: MacOsOpenReferences(
                command: (_, _) async => ProcessResult(pid, 1, '', ''),
              ),
              inventory: (path) async => DriverInventorySnapshot(
                processes: path == '${app.path}/Contents/MacOS/gaovmd'
                    ? [
                        DriverProcessIdentity(
                          pid: pid,
                          uid: 501,
                          executablePath: path,
                          startedAtMicroseconds: 1,
                          pidVersion: 1,
                        ),
                      ]
                    : [],
                unresolvedProcessIds: [],
              ),
            );
            expect(observedRestrictedApi, true);
            expect(report['phase'], 'candidate_validated');
            expect(report['applied_catalog_schema'], 21);
            expect(report['background_workers_started'], false);
            expect(report['ordinary_startup_fenced'], true);
            expect(report['committed'], false);
            final identity = report['catalog_identity'] as Map;
            expect(identity['vm_ids'], [validationVm.value]);
            expect(identity['image_ids'], [validationImage.id.value]);
            expect(identity['operation_ids'], hasLength(2));
            expect(identity['test_run_ids'], [validationRun.id.value]);
            expect(identity['artifact_ids'], [artifact.id.value]);
            expect(identity['event_cursor'], greaterThan(0));
            expect(identity['idempotency_count'], 1);
            final completed =
                jsonDecode(
                      await File(
                        '${work.path}/validation/completed/record.json',
                      ).readAsString(),
                    )
                    as Map;
            expect(completed['phase'], 'candidate_validated');
            expect(
              await File('${state.path}/unknown-data').readAsString(),
              'retain me',
            );
            final reader = await GaoVmDatabase.openReadOnly(
              '${state.path}/gaovm.db',
            );
            try {
              expect(
                await reader.read(
                  (db) => db
                      .select('SELECT key FROM idempotency_keys')
                      .single['key'],
                ),
                'retain-expired',
              );
              expect(
                await ArtifactRepository(reader).get(artifact.id),
                isNotNull,
              );
              expect(
                await SqliteTestRunRepository(reader).get(validationRun.id),
                validationRun,
              );
              expect(
                (await SqliteVmRepository(
                  reader,
                ).get(validationVm))!.status.phase,
                VmPhase.stopped,
              );
            } finally {
              reader.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            final fence = await MaintenanceStateFence.open(state);
            final root = await OwnedImageDirectory.open(state);
            try {
              final owner = await DaemonOwnership.tryAcquireForMaintenance(
                root,
                fence,
              );
              expect(owner, isNotNull);
              owner?.close();
            } finally {
              root.close();
              fence.close();
            }
          } finally {
            activeRetirementChecks--;
            activeValidation--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }, timeout: const Timeout(Duration(minutes: 8)));

    for (final refusal in [
      'overlap',
      'unknown-work',
      'used-inspection',
      'work-privacy',
    ]) {
      test(
        'operator refuses $refusal without fencing or normalizing inputs',
        () async {
          final args = arguments();
          switch (refusal) {
            case 'overlap':
              args[args.indexOf('--work-dir') + 1] = state.path;
            case 'unknown-work':
              await File('${work.path}/unknown').writeAsString('retain work');
            case 'used-inspection':
              await File(
                '${scratch.path}/unknown',
              ).writeAsString('retain inspection');
            case 'work-privacy':
              imageFileMode(work.path, 0x1ed);
          }
          await expectLater(
            command(args),
            throwsA(isA<ColdPublicationFailure>()),
          );
          expect(await File('${state.path}/.gaovmd.lock').exists(), false);
          await MaintenanceStateFence.requireUnfenced(state);
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'retain me',
          );
          if (refusal == 'work-privacy') {
            expect((await work.stat()).mode & 0xfff, 0x1ed);
          }
          if (refusal == 'unknown-work') {
            expect(
              await File('${work.path}/unknown').readAsString(),
              'retain work',
            );
          }
          if (refusal == 'used-inspection') {
            expect(
              await File('${scratch.path}/unknown').readAsString(),
              'retain inspection',
            );
          }
        },
      );
    }

    test(
      'operator cannot fence or replace state owned by an existing daemon',
      () async {
        activeRetirementChecks++;
        final root = await OwnedImageDirectory.open(state);
        final owner = await DaemonOwnership.tryAcquire(root);
        try {
          expect(owner, isNotNull);
          await expectLater(
            command(arguments()),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (error) => error.cause,
                'actual state ownership',
                isA<ColdStateFailure>(),
              ),
            ),
          );
          await owner!.verify();
          await MaintenanceStateFence.requireUnfenced(state);
          expect(await Directory(app.path).exists(), true);
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'retain me',
          );
        } finally {
          owner?.close();
          root.close();
          activeRetirementChecks--;
        }
      },
    );

    test(
      'operator refuses a changed work lock before acquiring original state',
      () async {
        activeRetirementChecks++;
        try {
          host.onProbe = () => File(
            '${work.path}/.gaovm-cold-publication.lock',
          ).writeAsString('foreign lock contents');
          host.onStatus = () async {
            throw StateError(
              'should refuse before querying service with a state lease',
            );
          };
          await expectLater(
            command(arguments()),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (error) => error.cause,
                'strict command lock rejection',
                isA<FormatException>(),
              ),
            ),
          );
          expect(await File('${state.path}/.gaovmd.lock').exists(), false);
          expect(
            await File(
              '${work.path}/.gaovm-cold-publication.lock',
            ).readAsString(),
            'foreign lock contents',
          );
        } finally {
          activeRetirementChecks--;
        }
      },
    );

    test(
      'operator command publishes with an independently observed catalog and retained fence',
      () async {
        activeRetirementChecks++;
        try {
          host.onAdmission = (_, _) async {
            final root = await OwnedImageDirectory.open(state);
            try {
              final competing = await root.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              try {
                expect(competing, isNull, reason: 'original inode stays owned');
              } finally {
                competing?.close();
              }
            } finally {
              root.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            return null;
          };
          final report = await runMacOsColdPublication(
            arguments(),
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          expect(report['phase'], 'candidate_published');
          expect(report['observed_catalog_schema'], 21);
          expect(report['activation_authorized'], false);
          expect(report['committed'], false);
          expect(report['rollback_authorized'], false);
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'retain me',
          );
          expect(
            await File(
              '${app.path}/Contents/Resources/new-only',
            ).readAsString(),
            'candidate',
          );
          expect(
            await Directory('${work.path}/retirement/GaoVM.app').exists(),
            true,
          );
          expect(
            await Directory(
              '${work.path}/preparation/original-state/payload',
            ).exists(),
            true,
          );
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
          final fence = await MaintenanceStateFence.open(state);
          final root = await OwnedImageDirectory.open(state);
          try {
            final owner = await DaemonOwnership.tryAcquireForMaintenance(
              root,
              fence,
            );
            expect(
              owner,
              isNotNull,
              reason: 'terminal command releases ownership only',
            );
            owner?.close();
          } finally {
            root.close();
            fence.close();
          }
          host.onAdmission = null;
          final published = await OwnedImageDirectory.open(app);
          final identity = await published.maintenanceIdentity();
          published.close();
          await candidate.rename('${temporary.path}/retained-source.app');
          await freshInspection('published-recheck-inspection');
          final recheck = await command(arguments(from: 'publication'));
          expect(recheck['phase'], 'candidate_published');
          final current = await OwnedImageDirectory.open(app);
          try {
            expect(await current.maintenanceIdentity(), identity);
          } finally {
            current.close();
          }
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );

    for (final checkpoint in ['preparation', 'retirement', 'publication']) {
      test(
        'operator resumes only the explicit completed $checkpoint checkpoint',
        () async {
          activeRetirementChecks++;
          try {
            host.onStatus = () async {
              final complete = switch (checkpoint) {
                'preparation' => File(
                  '${work.path}/preparation/prepared/record.json',
                ).existsSync(),
                'retirement' => Directory(
                  '${work.path}/retirement/GaoVM.app',
                ).existsSync(),
                _ => File(
                  '${work.path}/publication/prepared/record.json',
                ).existsSync(),
              };
              if (complete) throw StateError('terminal observation refusal');
            };
            await expectLater(
              command(arguments()),
              throwsA(isA<ColdPublicationFailure>()),
            );
            expect(
              await Directory(app.path).exists(),
              checkpoint == 'preparation',
            );
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            host.onStatus = null;
            // The original download is provenance, not a recovery input selector.
            await candidate.rename('${temporary.path}/retained-source.app');
            if (checkpoint == 'preparation') {
              await freshInspection('wrong-schema-inspection');
              await expectLater(
                command(arguments(from: checkpoint, schema: 0)),
                throwsA(
                  isA<ColdPublicationFailure>().having(
                    (error) => error.stage,
                    'independent catalog rejection',
                    'preparation',
                  ),
                ),
              );
              expect(await Directory(app.path).exists(), true);
            }
            await freshInspection('resume-inspection');
            final report = await command(arguments(from: checkpoint));
            expect(report['phase'], 'candidate_published');
            expect(report['observed_catalog_schema'], 21);
            expect(report['activation_authorized'], false);
            expect(report['committed'], false);
            expect(
              await File('${state.path}/unknown-data').readAsString(),
              'retain me',
            );
            expect(
              await File(
                '${app.path}/Contents/Resources/new-only',
              ).readAsString(),
              'candidate',
            );
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } finally {
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }

    test(
      'operator retains original ownership until a preparation child exit is confirmed',
      () async {
        activeRetirementChecks++;
        final entered = Completer<void>(), ownedExit = Completer<int>();
        Object? failure;
        var finished = false;
        Future<void>? settled;
        try {
          host.onProbe = () async {
            if (!entered.isCompleted &&
                File('${work.path}/.gaovm-upgrade.lock').existsSync()) {
              entered.complete();
              throw MaintenanceCommandFailure(
                'injected unconfirmed preparation child',
                pid + 500,
                exitConfirmed: false,
                ownedExit: ownedExit.future,
              );
            }
          };
          settled = command(arguments())
              .then<void>(
                (_) => fail('unconfirmed command must not succeed'),
                onError: (Object error) {
                  failure = error;
                },
              )
              .whenComplete(() {
                finished = true;
              });
          await entered.future;
          for (final (directory, lockName) in [
            (state, '.gaovmd.lock'),
            (work, '.gaovm-cold-publication.lock'),
            (work, '.gaovm-upgrade.lock'),
          ]) {
            final root = await OwnedImageDirectory.open(directory);
            try {
              final competing = await root.tryAcquireMaintenanceLock(
                lockName,
                create: false,
              );
              try {
                expect(competing, isNull);
              } finally {
                competing?.close();
              }
            } finally {
              root.close();
            }
          }
          expect(finished, false);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          if (!ownedExit.isCompleted) ownedExit.complete(1);
          await settled;
          activeRetirementChecks--;
        }
        expect(
          failure,
          isA<ColdPublicationFailure>().having(
            (error) => error.cause,
            'terminal original child failure',
            isA<MaintenanceCommandFailure>().having(
              (error) => error.exitConfirmed,
              'owned exit awaited',
              true,
            ),
          ),
        );
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'retain me',
        );
        expect(await Directory(app.path).exists(), true);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: !Platform.isMacOS);

  group('cold uninstall command', () {
    late Directory state, work, scratch;
    setUp(() async {
      state = await Directory('${temporary.path}/uninstall-state').create();
      work = await Directory('${temporary.path}/uninstall-work').create();
      scratch = await Directory(
        '${temporary.path}/uninstall-inspection',
      ).create();
      for (final directory in [state, work, scratch]) {
        imageFileMode(directory.path, 0x1c0);
      }
      final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      database.close();
      imageFileMode('${state.path}/gaovm.db', 0x180);
      for (final name in ['artifacts', 'logs', 'unknown-stage']) {
        final directory = await Directory('${state.path}/$name').create();
        imageFileMode(directory.path, 0x1c0);
        await File('${directory.path}/keep').writeAsString('retain $name');
        imageFileMode('${directory.path}/keep', 0x180);
      }
      final root = await OwnedImageDirectory.open(state);
      try {
        (await root.tryAcquireLock('.gaovmd.lock'))!.close();
      } finally {
        root.close();
      }
    });

    List<String> arguments({String? from, int schema = 21}) => [
      from == null ? 'uninstall-app' : 'resume-uninstall',
      '--app',
      app.path,
      '--state-dir',
      state.path,
      '--work-dir',
      work.path,
      '--inspection-dir',
      scratch.path,
      '--bundle-id',
      'org.gaovm.tests.Release',
      '--version',
      '0.1.0',
      '--team-id',
      'ABCDEFGHIJ',
      if (from != null) ...['--from', from, '--catalog-schema', '$schema'],
    ];

    Future<void> freshUninstallInspection(String name) async {
      scratch = await Directory('${temporary.path}/$name').create();
      imageFileMode(scratch.path, 0x1c0);
    }

    Future<Map<String, Object?>> command(List<String> args) async {
      activeRetirementChecks++;
      try {
        return await runMacOsColdUninstall(
          args,
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
          inventory: (_) async =>
              DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
        );
      } finally {
        activeRetirementChecks--;
      }
    }

    test(
      'uninstall retires the exact app and retains all state bytes and metadata',
      () async {
        activeRetirementChecks++;
        OwnedImageDirectory? originalApp;
        MaintenanceTree? stateTree;
        try {
          originalApp = await OwnedImageDirectory.open(app);
          stateTree = await MaintenanceTree.open(state);
          final identity = await originalApp.maintenanceIdentity();
          final before = await stateTree.capture(nativeMetadata: true);
          final report = await command(arguments());
          expect(report['phase'], 'uninstalled_data_retained');
          expect(report['uninstall_completed'], true);
          expect(report['observed_catalog_schema'], 21);
          expect(report['state_retained'], true);
          expect(report['data_deleted'], false);
          expect(report['activation_authorized'], false);
          expect(report['rollback_authorized'], false);
          expect(report['committed'], false);
          expect(await app.exists(), false);
          final retired = await OwnedImageDirectory.open(
            Directory('${work.path}/retirement/GaoVM.app'),
          );
          try {
            expect(await retired.maintenanceIdentity(), identity);
          } finally {
            retired.close();
          }
          await stateTree.verify(before, nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          stateTree?.close();
          originalApp?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
    test(
      'uninstall retains pre-catalog data without creating a database or inventing a schema',
      () async {
        await File(
          '${state.path}/gaovm.db',
        ).rename('${temporary.path}/retained-before-uninstall.db');
        final result = await command(arguments());
        expect(result['uninstall_completed'], true);
        expect(result['observed_catalog_schema'], isNull);
        expect(await File('${state.path}/gaovm.db').exists(), false);
        expect(
          await File('${state.path}/unknown-stage/keep').readAsString(),
          'retain unknown-stage',
        );
        await freshUninstallInspection('pre-catalog-uninstall-recovery');
        final recovered = await command(
          arguments(from: 'retirement', schema: 0),
        );
        expect(recovered['uninstall_completed'], true);
        expect(recovered['observed_catalog_schema'], isNull);
        expect(await File('${state.path}/gaovm.db').exists(), false);
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'uninstall refuses durable pending Operations before fencing or retiring the app',
      () async {
        final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
        late OperationId operation;
        try {
          operation = (await SqliteOperationRepository(database).create(
            type: 'image.import',
            resourceType: ResourceType.image,
            resourceId: ImageId.generate(),
            requestId: RequestId.generate(),
            cancellable: true,
            request: JsonObjectValue.empty,
          )).id;
        } finally {
          database.close();
        }
        final source = await MaintenanceTree.open(state);
        try {
          final before = await source.capture(nativeMetadata: true);
          await expectLater(
            command(arguments()),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (error) => error.cause,
                'durable-work refusal',
                isA<ColdStateFailure>().having(
                  (error) => error.stage,
                  'catalog boundary',
                  'catalog',
                ),
              ),
            ),
          );
          await source.verify(before, nativeMetadata: true);
          await MaintenanceStateFence.requireUnfenced(state);
          expect(await app.exists(), true);
          final retained = await GaoVmDatabase.open('${state.path}/gaovm.db');
          try {
            expect(
              (await SqliteOperationRepository(retained).get(operation))!.state,
              OperationState.pending,
            );
          } finally {
            retained.close();
          }
        } finally {
          source.close();
        }
      },
    );

    test(
      'uninstall preserves a failed TestRun VM, external disk and EFI history',
      () async {
        activeRetirementChecks++;
        MaintenanceTree? source;
        OwnedImageDirectory? external;
        OwnedImageFile? heldDisk, heldEfi;
        try {
          final disk = File('${temporary.path}/retained.raw');
          final efi = File('${temporary.path}/retained.efi');
          await disk.writeAsString('failed guest debugging filesystem');
          await efi.writeAsString('failed guest NVRAM');
          imageFileMode(disk.path, 0x180);
          imageFileMode(efi.path, 0x180);
          final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
          late TestRunId runId;
          late VmId vmId;
          try {
            final accepted =
                await SqliteVmCreateAcceptance(
                  database: database,
                  idempotencyRetention: const Duration(days: 30),
                ).create(
                  VmCreateCommand(
                    requestId: RequestId.generate(),
                    idempotencyKey: null,
                    requestBody: const [],
                    name: 'retained-uninstall-failure',
                    spec: VmSpec(
                      cpu: 1,
                      memoryBytes: 268435456,
                      boot: EfiBoot(
                        variableStore: EfiVariableStore.external,
                        variableStorePath: efi.path,
                      ),
                      disks: [
                        VmDisk(
                          id: 'root',
                          source: ExternalDiskSource(disk.path),
                          writable: true,
                        ),
                      ],
                      networks: [DisconnectedNetwork(id: 'net0')],
                      graphics: GraphicsConfig(enabled: false),
                      serial: const SerialConfig(enabled: true, capture: true),
                      guestAgent: GuestAgentConfig(
                        enabled: false,
                        requiredForReady: false,
                      ),
                      restartPolicy: RestartPolicy.never,
                    ),
                  ),
                );
            vmId = accepted.resourceId as VmId;
            for (final name in ['vms', 'images']) {
              final directory = await Directory('${state.path}/$name').create();
              imageFileMode(directory.path, 0x1c0);
            }
            final bundles = await OwnedImageDirectory.open(
              Directory('${state.path}/vms'),
            );
            try {
              final images = await OwnedImageDirectory.open(
                Directory('${state.path}/images'),
              );
              try {
                final result = (await VmProvisioningWorker(
                  work: SqliteVmProvisioningWorkRepository(database),
                  bundles: VmBundleStore(
                    database: database,
                    bundles: bundles,
                    images: images,
                  ),
                  owner: 'uninstall-fixture',
                ).dispatchOnce()).single;
                expect(
                  result.completion,
                  VmProvisioningCompletionKind.succeeded,
                );
              } finally {
                images.close();
              }
            } finally {
              bundles.close();
            }
            final runs = SqliteTestRunRepository(database);
            final run = await runs.create(
              spec: TestRunSpec(
                source: TemplateVmTestRunSource(vmId),
                wait: VmWaitSpec(
                  condition: WaitCondition.guestAgentReady,
                  timeoutSeconds: 1,
                ),
                steps: [
                  TestStepRequest(argv: ['false'], timeoutSeconds: 1),
                ],
                cleanup: CleanupPolicy.retain,
                retainOnFailure: true,
              ),
              requestId: RequestId.generate(),
            );
            runId = run.id;
            await runs.transition(
              runId,
              expectedState: TestRunState.pending,
              nextState: TestRunState.provisioning,
            );
            await runs.transition(
              runId,
              expectedState: TestRunState.provisioning,
              nextState: TestRunState.collecting,
              vmId: vmId,
              outcome: TestRunState.failed,
              error: OperationError(
                code: ErrorCode.internalError,
                message: 'retained failure fixture',
                retryable: false,
                details: JsonObjectValue.empty,
              ),
            );
            await runs.transition(
              runId,
              expectedState: TestRunState.collecting,
              nextState: TestRunState.cleaningUp,
              cleanupDecision: 'retain',
            );
            await runs.finish(runId, outcome: TestRunState.failed);
            await database.transaction(
              (raw) => raw.execute(
                "UPDATE vm_runtime SET phase = 'failed', observed_generation = 1, driver_generation = 1 WHERE vm_id = ?",
                [vmId.value],
              ),
            );
          } finally {
            database.close();
          }
          source = await MaintenanceTree.open(state);
          external = await OwnedImageDirectory.open(temporary);
          heldDisk = external.file('retained.raw');
          heldEfi = external.file('retained.efi');
          final before = await source.capture(nativeMetadata: true);
          final diskIdentity = heldDisk.stat(), efiIdentity = heldEfi.stat();
          final diskMetadata = await heldDisk.maintenanceMetadata(),
              efiMetadata = await heldEfi.maintenanceMetadata();
          final report = await command(arguments());
          expect(report['uninstall_completed'], true);
          await source.verify(before, nativeMetadata: true);
          expect(
            await disk.readAsString(),
            'failed guest debugging filesystem',
          );
          expect(await efi.readAsString(), 'failed guest NVRAM');
          expect(heldDisk.stat(), diskIdentity);
          expect(heldEfi.stat(), efiIdentity);
          expect(await heldDisk.maintenanceMetadata(), diskMetadata);
          expect(await heldEfi.maintenanceMetadata(), efiMetadata);
          final retained = await GaoVmDatabase.open('${state.path}/gaovm.db');
          try {
            expect(
              (await SqliteTestRunRepository(retained).get(runId))!.state,
              TestRunState.failed,
            );
            expect(
              (await SqliteVmRepository(retained).get(vmId))!.status.phase,
              VmPhase.failed,
            );
          } finally {
            retained.close();
          }
        } finally {
          heldEfi?.close();
          heldDisk?.close();
          external?.close();
          source?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final fault in [
      'overlap',
      'unknown-work',
      'used-inspection',
      'work-privacy',
    ]) {
      test(
        'uninstall refuses $fault without changing state or fencing startup',
        () async {
          final args = arguments();
          switch (fault) {
            case 'overlap':
              args[args.indexOf('--work-dir') + 1] = state.path;
            case 'unknown-work':
              await File('${work.path}/unknown').writeAsString('retain work');
            case 'used-inspection':
              await File(
                '${scratch.path}/unknown',
              ).writeAsString('retain scratch');
            case 'work-privacy':
              imageFileMode(work.path, 0x1ed);
          }
          await expectLater(
            command(args),
            throwsA(isA<ColdPublicationFailure>()),
          );
          await MaintenanceStateFence.requireUnfenced(state);
          expect(await app.exists(), true);
          expect(
            await File('${state.path}/unknown-stage/keep').readAsString(),
            'retain unknown-stage',
          );
          if (fault == 'work-privacy')
            expect((await work.stat()).mode & 0xfff, 0x1ed);
          if (fault == 'unknown-work')
            expect(
              await File('${work.path}/unknown').readAsString(),
              'retain work',
            );
          if (fault == 'used-inspection')
            expect(
              await File('${scratch.path}/unknown').readAsString(),
              'retain scratch',
            );
        },
      );
    }

    test(
      'uninstall refuses an actual current state owner without arming a fence',
      () async {
        activeRetirementChecks++;
        OwnedImageDirectory? root;
        DaemonOwnership? owner;
        try {
          root = await OwnedImageDirectory.open(state);
          owner = await DaemonOwnership.tryAcquire(root);
          expect(owner, isNotNull);
          await expectLater(
            command(arguments()),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (error) => error.cause,
                'actual state owner',
                isA<ColdStateFailure>(),
              ),
            ),
          );
          await owner!.verify();
          await MaintenanceStateFence.requireUnfenced(state);
          expect(await app.exists(), true);
        } finally {
          owner?.close();
          root?.close();
          activeRetirementChecks--;
        }
      },
    );

    for (final changed in ['unknown-state', 'command-lock']) {
      test(
        'uninstall refuses a late native $changed change before the app move',
        () async {
          var injected = false;
          host.onStatus = () async {
            if (File('${work.path}/retirement/intent.json').existsSync()) {
              host.onStatus = null;
              injected = true;
              await File(
                changed == 'unknown-state'
                    ? '${state.path}/unknown-stage/keep'
                    : '${work.path}/.gaovm-cold-uninstall.lock',
              ).writeAsString('retain late change');
            }
          };
          await expectLater(
            command(arguments()),
            throwsA(
              isA<ColdPublicationFailure>().having(
                (error) => error.cause,
                'complete final filesystem guard',
                isA<FormatException>(),
              ),
            ),
          );
          expect(injected, true);
          expect(await app.exists(), true);
          expect(
            await Directory('${work.path}/retirement/GaoVM.app').exists(),
            false,
          );
          expect(
            await File(
              changed == 'unknown-state'
                  ? '${state.path}/unknown-stage/keep'
                  : '${work.path}/.gaovm-cold-uninstall.lock',
            ).readAsString(),
            'retain late change',
          );
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'uninstall resumes an explicit complete preparation and checks the actual schema',
      () async {
        host.onStatus = () async {
          if (File('${work.path}/uninstall/record.json').existsSync()) {
            throw StateError('injected terminal prepared refusal');
          }
        };
        await expectLater(
          command(arguments()),
          throwsA(isA<ColdPublicationFailure>()),
        );
        expect(await app.exists(), true);
        host.onStatus = null;
        await freshUninstallInspection('wrong-uninstall-schema');
        await expectLater(
          command(arguments(from: 'preparation', schema: 0)),
          throwsA(
            isA<ColdPublicationFailure>().having(
              (error) => error.stage,
              'independently observed schema',
              'inspection',
            ),
          ),
        );
        expect(await app.exists(), true);
        await freshUninstallInspection('resumed-uninstall-preparation');
        final result = await command(arguments(from: 'preparation'));
        expect(result['uninstall_completed'], true);
        expect(result['observed_catalog_schema'], 21);
        expect(await app.exists(), false);
        expect(
          await File('${state.path}/unknown-stage/keep').readAsString(),
          'retain unknown-stage',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'uninstall recovery refuses changed retained data without promoting the checkpoint',
      () async {
        host.onStatus = () async {
          if (File('${work.path}/uninstall/record.json').existsSync()) {
            throw StateError('injected terminal prepared refusal');
          }
        };
        await expectLater(
          command(arguments()),
          throwsA(isA<ColdPublicationFailure>()),
        );
        host.onStatus = null;
        await File(
          '${state.path}/unknown-stage/keep',
        ).writeAsString('retain intervening write');
        await freshUninstallInspection('changed-uninstall-data');
        await expectLater(
          command(arguments(from: 'preparation')),
          throwsA(
            isA<ColdPublicationFailure>().having(
              (error) => error.cause,
              'sealed retained-data comparison',
              isA<FormatException>(),
            ),
          ),
        );
        expect(await app.exists(), true);
        expect(
          await File('${state.path}/unknown-stage/keep').readAsString(),
          'retain intervening write',
        );
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'uninstall keeps its state and namespace owners until the original native exit settles',
      () async {
        final entered = Completer<void>(), ownedExit = Completer<int>();
        Future<void>? settled;
        Object? failure;
        var finished = false;
        host.onProbe = () async {
          if (!entered.isCompleted &&
              File('${work.path}/.gaovm-uninstall.lock').existsSync()) {
            entered.complete();
            throw MaintenanceCommandFailure(
              'injected pending uninstall child',
              pid + 500,
              exitConfirmed: false,
              ownedExit: ownedExit.future,
            );
          }
        };
        try {
          settled = command(arguments())
              .then<void>(
                (_) => fail('pending command must not succeed'),
                onError: (Object error) {
                  failure = error;
                },
              )
              .whenComplete(() {
                finished = true;
              });
          await entered.future;
          for (final (directory, name) in [
            (state, '.gaovmd.lock'),
            (work, '.gaovm-cold-uninstall.lock'),
            (work, '.gaovm-uninstall.lock'),
          ]) {
            final root = await OwnedImageDirectory.open(directory);
            try {
              final competing = await root.tryAcquireMaintenanceLock(
                name,
                create: false,
              );
              try {
                expect(competing, isNull);
              } finally {
                competing?.close();
              }
            } finally {
              root.close();
            }
          }
          expect(finished, false);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          if (!ownedExit.isCompleted) ownedExit.complete(1);
          await settled;
        }
        expect(
          failure,
          isA<ColdPublicationFailure>().having(
            (error) => error.cause,
            'same terminal native failure',
            isA<MaintenanceCommandFailure>().having(
              (error) => error.exitConfirmed,
              'confirmed original exit',
              true,
            ),
          ),
        );
        expect(await app.exists(), true);
        expect(
          await File('${state.path}/unknown-stage/keep').readAsString(),
          'retain unknown-stage',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'uninstall recovery rechecks an exact retired app after a terminal failure',
      () async {
        activeRetirementChecks++;
        OwnedImageDirectory? original;
        try {
          original = await OwnedImageDirectory.open(app);
          final identity = await original.maintenanceIdentity();
          host.onStatus = () async {
            if (Directory('${work.path}/retirement/GaoVM.app').existsSync()) {
              throw StateError('injected terminal post-retirement refusal');
            }
          };
          await expectLater(
            command(arguments()),
            throwsA(isA<ColdPublicationFailure>()),
          );
          expect(await app.exists(), false);
          host.onStatus = null;
          await freshUninstallInspection('wrong-uninstall-checkpoint');
          final executed = host.executedRoles.length;
          await expectLater(
            command(arguments(from: 'preparation')),
            throwsA(isA<ColdPublicationFailure>()),
          );
          expect(
            host.executedRoles.length,
            executed,
            reason: 'wrong phase refuses before executing a helper',
          );
          await freshUninstallInspection('resume-uninstall-inspection');
          final report = await command(arguments(from: 'retirement'));
          expect(report['phase'], 'uninstalled_data_retained');
          expect(report['action'], 'resume-uninstall');
          final retired = await OwnedImageDirectory.open(
            Directory('${work.path}/retirement/GaoVM.app'),
          );
          try {
            expect(await retired.maintenanceIdentity(), identity);
          } finally {
            retired.close();
          }
          expect(
            await File('${state.path}/unknown-stage/keep').readAsString(),
            'retain unknown-stage',
          );
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
          await app.create();
          await File(
            '${app.path}/foreign',
          ).writeAsString('retain occupied slot');
          await freshUninstallInspection('occupied-uninstall-slot');
          await expectLater(
            command(arguments(from: 'retirement')),
            throwsA(isA<ColdPublicationFailure>()),
          );
          expect(
            await File('${app.path}/foreign').readAsString(),
            'retain occupied slot',
          );
        } finally {
          original?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }, skip: !Platform.isMacOS);

  group('cold paired snapshots', () {
    late Directory state;
    late OwnedImageDirectory inspection;
    late OwnedImageDirectory backups;
    late ColdStateLease lease;
    late _SnapshotHost coldHost;
    final children = <OwnedTestProcess>[];
    setUp(() async {
      await File(
        '${app.path}/Contents/Resources/pair-only',
      ).writeAsString('preserve unknown app resource');
      imageFileMode('${app.path}/Contents/Resources/pair-only', 0x180);
      state = await Directory('${temporary.path}/state').create();
      imageFileMode(state.path, 0x1c0);
      final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      database.close();
      imageFileMode('${state.path}/gaovm.db', 0x180);
      await File('${state.path}/unknown-data').writeAsString('preserve state');
      imageFileMode('${state.path}/unknown-data', 0x180);
      for (final name in ['inspection', 'backups']) {
        final directory = await Directory('${temporary.path}/$name').create();
        imageFileMode(directory.path, 0x1c0);
      }
      inspection = await OwnedImageDirectory.open(
        Directory('${temporary.path}/inspection'),
      );
      backups = await OwnedImageDirectory.open(
        Directory('${temporary.path}/backups'),
      );
      coldHost = _SnapshotHost(app.path);
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Release',
        host: coldHost,
      );
    });
    tearDown(() async {
      if (activeRetirementChecks != 0) {
        retainInputs = true;
        return;
      }
      for (final child in children) {
        if (!await child.terminate()) retainInputs = true;
      }
      children.clear();
      lease.close();
      inspection.close();
      backups.close();
    });

    Future<ProcessResult> command(
      String executable,
      List<String> arguments,
    ) async {
      try {
        return await runMaintenanceCommand(executable, arguments);
      } on MaintenanceCommandFailure catch (error) {
        if (!error.exitConfirmed) retainInputs = true;
        rethrow;
      }
    }

    Future<void> assertOwnership() async {
      await lease.verify();
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(await DaemonOwnership.tryAcquire(root), isNull);
      } finally {
        root.close();
      }
    }

    Future<Map<String, Object?>> snapshot({
      MacOsOpenReferences? observer,
      OwnedImageDirectory? storage,
    }) => ColdUpgradeSnapshot.create(
      lease,
      inspection,
      storage ?? backups,
      'before',
      version: '0.1.0',
      teamIdentifier: 'ABCDEFGHIJ',
      host: host,
      observer:
          observer ??
          MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
      inventory: (_) async =>
          DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
    );

    Future<(ColdStateSnapshot, MaintenanceStateFence)> guardedState() async {
      final fence = await MaintenanceStateFence.begin(lease);
      addTearDown(() {
        if (activeRetirementChecks == 0) fence.close();
      });
      final prepared = await ColdStateSnapshot.prepare(
        lease,
        inspection,
        observer: MacOsOpenReferences(
          command: (_, _) async => ProcessResult(pid, 1, '', ''),
        ),
        inventory: (_) async =>
            DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
      );
      addTearDown(() {
        if (activeRetirementChecks == 0) prepared.close();
      });
      return (prepared, fence);
    }

    Future<(ColdStateSnapshot, MaintenanceStateFence, ColdUpgradePreparation)>
    fencedPreparation() async {
      final candidate = Directory('${temporary.path}/Candidate.app');
      await _fixture(candidate);
      final (prepared, fence) = await guardedState();
      final transaction = await ColdUpgradePreparation.create(
        prepared,
        fence,
        backups,
        'upgrade',
        candidateApp: candidate,
        oldVersion: '0.1.0',
        newVersion: '0.1.0',
        teamIdentifier: 'ABCDEFGHIJ',
        host: host,
        observer: MacOsOpenReferences(
          command: (_, _) async => ProcessResult(pid, 1, '', ''),
        ),
      );
      addTearDown(() {
        if (activeRetirementChecks == 0) transaction.close();
      });
      return (prepared, fence, transaction);
    }

    Future<ColdRollbackPreparation> prepareRollback(
      MaintenanceStateFence fence, {
      bool acceptHistoryRewind = true,
      int? sourceCatalogSchema = 21,
      MacOsOpenReferences? observer,
    }) => ColdRollbackPreparation.prepare(
      lease,
      fence,
      backups,
      'upgrade',
      acceptHistoryRewind: acceptHistoryRewind,
      oldVersion: '0.1.0',
      newVersion: '0.1.0',
      teamIdentifier: 'ABCDEFGHIJ',
      sourceCatalogSchema: sourceCatalogSchema,
      host: host,
      observer:
          observer ??
          MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
      inventory: (_) async =>
          DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
    );

    Future<ColdRollbackPreparation> reopenRollback(
      MaintenanceStateFence fence,
      OwnedImageDirectory scratch,
    ) => ColdRollbackPreparation.open(
      lease,
      fence,
      backups,
      'upgrade',
      scratch,
      acceptHistoryRewind: true,
      oldVersion: '0.1.0',
      newVersion: '0.1.0',
      teamIdentifier: 'ABCDEFGHIJ',
      sourceCatalogSchema: 21,
      host: host,
      observer: MacOsOpenReferences(
        command: (_, _) async => ProcessResult(pid, 1, '', ''),
      ),
      inventory: (_) async =>
          DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
    );

    test(
      'rollback preparation preserves the entire failed generation without changing the old pair',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        PreservedColdState? retained;
        MaintenanceTree? oldPair;
        try {
          final (snapshot, fence, upgrade) = await fencedPreparation();
          upgrade.close();
          snapshot.close();
          await File('${state.path}/gaovm.db').writeAsString(
            'preserve the failed migration, not only catalog rows',
            flush: true,
          );
          rollback = await prepareRollback(fence);
          oldPair = await MaintenanceTree.open(Directory(rollback.path));
          final before = await oldPair.capture(nativeMetadata: true);
          retained = await rollback.preserveCurrentState();
          expect(await state.exists(), false);
          expect(
            await File('${retained.path}/gaovm.db').readAsString(),
            'preserve the failed migration, not only catalog rows',
          );
          expect(retained.toJson()['canonical_state_restored'], false);
          expect(retained.toJson()['committed'], false);
          expect(retained.toJson()['startup_allowed'], false);
          await oldPair.verify(before, nativeMetadata: true);
          await expectLater(rollback.verify(), throwsStateError);
          rollback.close();
          await retained.verify();
          lease.close();
          final root = await OwnedImageDirectory.open(Directory(retained.path));
          final contender = await root.tryAcquireMaintenanceLock(
            '.gaovmd.lock',
            create: false,
          );
          try {
            expect(contender, isNull);
          } finally {
            contender?.close();
            root.close();
          }
          for (final target in [state, Directory(retained.path)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          retained?.close();
          rollback?.close();
          oldPair?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'rollback state cutover restores its matching whole old state and transfers both owners without moving either app',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        ColdRollbackStateRestoration? restored;
        MaintenanceTree? originalPair, staged, installedApp, retainedTree;
        try {
          final (snapshot, fence, upgrade) = await fencedPreparation();
          upgrade.close();
          snapshot.close();
          await File('${state.path}/gaovm.db').writeAsString(
            'retain the failed post-upgrade catalog',
            flush: true,
          );
          rollback = await prepareRollback(fence);
          originalPair = await MaintenanceTree.open(
            Directory('${backups.path}/upgrade'),
          );
          final pairBefore = await originalPair.capture(nativeMetadata: true);
          staged = await MaintenanceTree.open(Directory(rollback.statePath));
          final oldBefore = await staged.capture(nativeMetadata: true);
          staged.close();
          staged = null;
          installedApp = await MaintenanceTree.open(app);
          final appBefore = await installedApp.capture(nativeMetadata: true);
          restored = await rollback.restoreOldState();
          expect(restored.path, state.path);
          expect(restored.toJson()['phase'], 'old_state_restored');
          expect(restored.toJson()['canonical_state_restored'], true);
          for (final flag in [
            'installed_pair_restored',
            'committed',
            'startup_allowed',
            'service_actions_performed',
          ]) {
            expect(restored.toJson()[flag], false);
          }
          expect(await Directory(rollback.statePath).exists(), false);
          final installed = await MaintenanceTree.open(state);
          try {
            await installed.verify(oldBefore, nativeMetadata: true);
          } finally {
            installed.close();
          }
          final retained = Directory(restored.retainedStatePath);
          expect(
            await File('${retained.path}/gaovm.db').readAsString(),
            'retain the failed post-upgrade catalog',
          );
          retainedTree = await MaintenanceTree.open(retained);
          final retainedBefore = await retainedTree.capture(
            nativeMetadata: true,
          );
          await expectLater(rollback.verify(), throwsStateError);
          expect(rollback.toJson, throwsStateError);
          rollback.close();
          lease.close();
          await restored.verify();
          await originalPair.verify(pairBefore, nativeMetadata: true);
          await installedApp.verify(appBefore, nativeMetadata: true);
          await retainedTree.verify(retainedBefore, nativeMetadata: true);
          for (final target in [state, retained]) {
            final root = await OwnedImageDirectory.open(target);
            try {
              final competing = await root.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              expect(competing, isNull);
              competing?.close();
            } finally {
              root.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
          restored.close();
          await expectLater(restored.verify(), throwsStateError);
          expect(restored.toJson, throwsStateError);
          for (final (directory, name) in [
            (state, '.gaovmd.lock'),
            (retained, '.gaovmd.lock'),
            (Directory(backups.path), '.gaovm-upgrade.lock'),
            (Directory(backups.path), '.gaovm-cold-rollback.lock'),
            (Directory(backups.path), '.gaovm-state-preservation.lock'),
            (Directory(backups.path), '.gaovm-state-restoration.lock'),
          ]) {
            final root = await OwnedImageDirectory.open(directory);
            try {
              final released = await root.tryAcquireMaintenanceLock(
                name,
                create: false,
              );
              expect(released, isNotNull);
              released?.close();
            } finally {
              root.close();
            }
          }
          for (final target in [state, retained]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          restored?.close();
          rollback?.close();
          retainedTree?.close();
          installedApp?.close();
          staged?.close();
          originalPair?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final changed in [
      'original snapshot',
      'rollback intent',
      'state receipt',
    ]) {
      test(
        'rollback state cutover retains both generations after late $changed mutation',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          var changedOnce = false;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            rollback = await prepareRollback(fence);
            final stagedPath = rollback.statePath;
            final retained = Directory(
              '${backups.path}/retained-current/state',
            );
            late File changedFile;
            coldHost.onStatus = () async {
              if (changedOnce ||
                  !await state.exists() ||
                  await Directory(stagedPath).exists() ||
                  !await retained.exists())
                return;
              changedOnce = true;
              changedFile = File(switch (changed) {
                'original snapshot' =>
                  '${backups.path}/upgrade/original-state/payload/unknown-data',
                'rollback intent' => '${rollback!.path}/intent.json',
                _ => '${rollback!.path}/state/receipt.json',
              });
              final bytes = await changedFile.readAsString();
              imageFileMode(changedFile.path, 0x180);
              await changedFile.writeAsString('$bytes ', flush: true);
              imageFileMode(
                changedFile.path,
                changed == 'original snapshot' ? 0x180 : 0x100,
              );
            };
            await expectLater(
              rollback.restoreOldState(),
              throwsFormatException,
            );
            expect(changedOnce, true);
            coldHost.onStatus = null;
            expect((await changedFile.readAsString()).endsWith(' '), true);
            expect(await state.exists(), true);
            expect(await Directory(stagedPath).exists(), false);
            expect(await retained.exists(), true);
            expect(rollback.toJson, throwsStateError);
            await expectLater(rollback.restoreOldState(), throwsStateError);
            for (final target in [state, retained]) {
              final root = await OwnedImageDirectory.open(target);
              try {
                final competing = await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                expect(competing, isNull);
                competing?.close();
              } finally {
                root.close();
              }
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            coldHost.onStatus = null;
            rollback?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'rollback state cutover keeps both owners while a post-move native observation is pending',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        ColdRollbackStateRestoration? restored;
        final entered = Completer<void>(), release = Completer<void>();
        try {
          final (snapshot, fence, upgrade) = await fencedPreparation();
          upgrade.close();
          snapshot.close();
          rollback = await prepareRollback(fence);
          final stagedPath = rollback.statePath;
          final retained = Directory('${backups.path}/retained-current/state');
          coldHost.onStatus = () async {
            if (!entered.isCompleted &&
                await state.exists() &&
                !await Directory(stagedPath).exists() &&
                await retained.exists()) {
              entered.complete();
              await release.future;
            }
          };
          final pending = rollback.restoreOldState();
          unawaited(
            pending.then<void>(
              (_) {
                if (!entered.isCompleted)
                  entered.completeError(
                    StateError('missing cutover observation'),
                  );
              },
              onError: (Object error, StackTrace stack) {
                if (!entered.isCompleted) entered.completeError(error, stack);
              },
            ),
          );
          try {
            await entered.future;
            expect(rollback.close, throwsStateError);
            expect(rollback.toJson, throwsStateError);
            await expectLater(rollback.verify(), throwsStateError);
            await expectLater(rollback.restoreOldState(), throwsStateError);
            for (final target in [state, retained]) {
              final root = await OwnedImageDirectory.open(target);
              try {
                final competing = await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                expect(competing, isNull);
                competing?.close();
              } finally {
                root.close();
              }
            }
          } finally {
            if (!release.isCompleted) release.complete();
            restored = await pending;
          }
          coldHost.onStatus = null;
          rollback.close();
          await restored.verify();
          final verifying = Completer<void>(), finish = Completer<void>();
          coldHost.onStatus = () async {
            if (!verifying.isCompleted) {
              verifying.complete();
              await finish.future;
            }
          };
          final pendingVerification = restored.verify();
          unawaited(
            pendingVerification.then<void>(
              (_) {
                if (!verifying.isCompleted)
                  verifying.completeError(
                    StateError('missing verification observation'),
                  );
              },
              onError: (Object error, StackTrace stack) {
                if (!verifying.isCompleted)
                  verifying.completeError(error, stack);
              },
            ),
          );
          try {
            await verifying.future;
            expect(restored.close, throwsStateError);
            expect(restored.toJson, throwsStateError);
            await expectLater(restored.verify(), throwsStateError);
            rollback.close(); // Consumed preparation cannot release the owners.
          } finally {
            finish.complete();
            await pendingVerification;
          }
          coldHost.onStatus = null;
          await restored.verify();
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          coldHost.onStatus = null;
          restored?.close();
          rollback?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    Future<(ColdRollbackPreparation, ColdRollbackStateRestoration)>
    restoredNativeRollback({
      MacOsOpenReferences? references,
      Future<DriverInventorySnapshot> Function(String)? processInventory,
      void Function(
        MaintenanceStateFence,
        MacOsColdStateHost,
        OwnedImageDirectory,
      )?
      onPrepared,
    }) async {
      lease.close();
      MacOsOpenReferences observer() => MacOsOpenReferences(
        command: (_, _) async => ProcessResult(pid, 1, '', ''),
      );
      Future<DriverInventorySnapshot> inventory(String path) async =>
          processInventory == null
          ? DriverInventorySnapshot(processes: [], unresolvedProcessIds: [])
          : await processInventory(path);
      final native = await MacOsColdStateHost.open(
        app,
        bundleIdentifier: 'org.gaovm.tests.Release',
        version: '0.1.0',
        teamIdentifier: 'ABCDEFGHIJ',
        catalogSchema: 21,
        host: host,
        observer: observer(),
        inventory: inventory,
      );
      addTearDown(() {
        if (activeRetirementChecks == 0) native.close();
      });
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Release',
        host: native,
      );
      final (snapshot, fence, upgrade) = await fencedPreparation();
      final parent = await OwnedImageDirectory.open(temporary);
      late OwnedImageDirectory retirement;
      try {
        retirement = parent.createDirectory('paired-apps');
      } finally {
        parent.close();
      }
      addTearDown(() {
        if (activeRetirementChecks == 0) retirement.close();
      });
      await upgrade.retireOriginalApp(retirement, 'old');
      await upgrade.publishCandidate(retirement, 'candidate');
      upgrade.close();
      snapshot.close();
      lease.close();
      final currentHost = await MacOsColdStateHost.openPublished(
        app,
        state,
        fence,
        retirement,
        'old',
        retirement,
        'candidate',
        bundleIdentifier: 'org.gaovm.tests.Release',
        oldVersion: '0.1.0',
        newVersion: '0.1.0',
        teamIdentifier: 'ABCDEFGHIJ',
        retiredCatalogSchema: 21,
        catalogSchema: 21,
        host: host,
        observer: observer(),
        inventory: inventory,
      );
      addTearDown(() {
        if (activeRetirementChecks == 0) currentHost.close();
      });
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Release',
        host: currentHost,
        maintenanceFence: fence,
      );
      await File(
        '${state.path}/failed-generation',
      ).writeAsString('retain the failed generation', flush: true);
      final rollback = await prepareRollback(fence, observer: references);
      addTearDown(() {
        if (activeRetirementChecks == 0) rollback.close();
      });
      final restored = await rollback.restoreOldState();
      addTearDown(() {
        if (activeRetirementChecks == 0) restored.close();
      });
      onPrepared?.call(fence, currentHost, retirement);
      return (rollback, restored);
    }

    Future<
      ({
        MaintenanceStateFence fence,
        OwnedImageDirectory native,
        Map<String, Object?> facts,
      })
    >
    pairedCheckpoint() async {
      late MaintenanceStateFence original;
      late MacOsColdStateHost native;
      late OwnedImageDirectory storage;
      final (_, restored) = await restoredNativeRollback(
        onPrepared: (fence, host, parent) {
          original = fence;
          native = host;
          storage = parent;
        },
      );
      try {
        await restored.restoreOldApp();
        final facts = restored.toJson();
        restored.close();
        native.close();
        original.close();
        lease.close();
        final recovered = await MaintenanceStateFence.open(state);
        addTearDown(() {
          if (activeRetirementChecks == 0) recovered.close();
        });
        return (fence: recovered, native: storage, facts: facts);
      } finally {
        restored.close();
      }
    }

    Future<ColdRollbackStateRestoration> reopenPair(
      MaintenanceStateFence fence,
      OwnedImageDirectory native, {
      bool acceptHistoryRewind = true,
      MacOsOpenReferences? references,
      Future<DriverInventorySnapshot> Function(String)? inventory,
    }) => ColdRollbackStateRestoration.open(
      backups,
      'upgrade',
      fence,
      installationApp: app,
      retirement: (storage: native, name: 'old'),
      publication: (storage: native, name: 'candidate'),
      bundleIdentifier: 'org.gaovm.tests.Release',
      acceptHistoryRewind: acceptHistoryRewind,
      oldVersion: '0.1.0',
      newVersion: '0.1.0',
      teamIdentifier: 'ABCDEFGHIJ',
      sourceCatalogSchema: 21,
      host: host,
      observer:
          references ??
          MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
      inventory:
          inventory ??
          (_) async =>
              DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
    );

    for (final fault in [
      'original pair bytes',
      'retained app bytes',
      'foreign installed app',
      'unknown staged app',
      'incomplete completion',
      'missing state lock',
      'changed native lock',
    ]) {
      test(
        'paired recovery refuses $fault before native helpers without repair',
        () async {
          activeRetirementChecks++;
          MaintenanceTree? tree;
          try {
            final inputs = await pairedCheckpoint();
            final checkpoint = '${backups.path}/restored-old-app';
            switch (fault) {
              case 'original pair bytes':
                final file = File(
                  '${backups.path}/upgrade/original-state/payload/unknown-data',
                );
                imageFileMode(file.path, 0x180);
                await file.writeAsString(
                  'retain changed original bytes',
                  flush: true,
                );
              case 'retained app bytes':
                final file = File(
                  '${inputs.facts['retained_app']}/Contents/Resources/retain-evidence',
                );
                await file.writeAsString(
                  'retain changed failed app',
                  flush: true,
                );
                imageFileMode(file.path, 0x180);
              case 'foreign installed app':
                await app.rename('${temporary.path}/retained-old.app');
                await app.create();
                imageFileMode(app.path, 0x1c0);
                await File(
                  '${app.path}/foreign',
                ).writeAsString('retain foreign installation');
                imageFileMode('${app.path}/foreign', 0x180);
              case 'unknown staged app':
                final directory = await Directory(
                  '${backups.path}/rollback/app/payload.app',
                ).create();
                imageFileMode(directory.path, 0x1c0);
              case 'incomplete completion':
                await Directory(
                  '$checkpoint/completed',
                ).rename('${temporary.path}/retained-completion');
                final directory = await Directory(
                  '$checkpoint/.completed.partial',
                ).create();
                imageFileMode(directory.path, 0x1c0);
                await File('${directory.path}/record.json').writeAsString('{');
                imageFileMode('${directory.path}/record.json', 0x180);
              case 'missing state lock':
                await File(
                  '${state.path}/.gaovmd.lock',
                ).rename('${temporary.path}/retained-owner-lock');
              case 'changed native lock':
                await File(
                  '${inputs.native.path}/.gaovm-app-retirement.lock',
                ).writeAsString('retain changed namespace lock', flush: true);
            }
            tree = await MaintenanceTree.open(temporary);
            final before = await tree.capture(nativeMetadata: true);
            final roles = host.executedRoles.length;
            final status = host.statusCalls;
            final admissions = host.admissions;
            await expectLater(
              reopenPair(inputs.fence, inputs.native),
              throwsFormatException,
            );
            expect(host.executedRoles.length, roles);
            expect(host.statusCalls, status);
            expect(host.admissions, admissions);
            await tree.verify(before, nativeMetadata: true);
            for (final target in [
              state,
              Directory(inputs.facts['retained_state'] as String),
            ]) {
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              if (fault != 'missing state lock' || target.path != state.path) {
                final root = await OwnedImageDirectory.open(target);
                try {
                  final released = await root.tryAcquireMaintenanceLock(
                    '.gaovmd.lock',
                    create: false,
                  );
                  expect(released, isNotNull);
                  released?.close();
                } finally {
                  root.close();
                }
              }
            }
            if (fault == 'missing state lock')
              expect(await File('${state.path}/.gaovmd.lock').exists(), false);
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            tree?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    for (final observation in ['snapshot writer', 'unresolved staged driver']) {
      test(
        'paired recovery keeps a missing completion after a fresh $observation refusal',
        () async {
          activeRetirementChecks++;
          MaintenanceTree? tree;
          try {
            final inputs = await pairedCheckpoint();
            final checkpoint = '${backups.path}/restored-old-app';
            await Directory(
              '$checkpoint/completed',
            ).rename('${temporary.path}/retained-completion');
            tree = await MaintenanceTree.open(temporary);
            final before = await tree.capture(nativeMetadata: true);
            var observed = false;
            final status = host.statusCalls, admissions = host.admissions;
            final references = MacOsOpenReferences(
              command: (_, arguments) async {
                if (observation == 'snapshot writer' &&
                    arguments.last ==
                        '${backups.path}/upgrade/original-state/payload') {
                  observed = true;
                  return ProcessResult(pid, 0, 'p${pid + 7}\x00f7\x00\n', '');
                }
                return ProcessResult(pid, 1, '', '');
              },
            );
            final stagedDriver =
                '${inputs.native.path}/candidate/candidate/payload.app/Contents/Helpers/gaovm-driver-vz';
            await expectLater(
              reopenPair(
                inputs.fence,
                inputs.native,
                references: references,
                inventory: (path) async {
                  if (observation == 'unresolved staged driver' &&
                      path == stagedDriver) {
                    observed = true;
                    return DriverInventorySnapshot(
                      processes: [],
                      unresolvedProcessIds: [pid + 7],
                    );
                  }
                  return DriverInventorySnapshot(
                    processes: [],
                    unresolvedProcessIds: [],
                  );
                },
              ),
              throwsA(
                isA<ColdStateFailure>().having(
                  (error) => error.stage,
                  'fresh refusal',
                  observation == 'snapshot writer'
                      ? 'rollback_snapshot_references'
                      : 'restored_processes',
                ),
              ),
            );
            expect(observed, true);
            expect(host.statusCalls, greaterThan(status));
            expect(host.admissions, admissions);
            expect(await Directory('$checkpoint/completed').exists(), false);
            expect(
              await Directory('$checkpoint/.completed.partial').exists(),
              false,
            );
            await tree.verify(before, nativeMetadata: true);
            for (final target in [
              state,
              Directory(inputs.facts['retained_state'] as String),
            ]) {
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
              final root = await OwnedImageDirectory.open(target);
              try {
                final released = await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                expect(released, isNotNull);
                released?.close();
              } finally {
                root.close();
              }
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            tree?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    for (final checkpoint in ['missing', 'sealed partial']) {
      test(
        'paired recovery completes only the $checkpoint final app checkpoint',
        () async {
          activeRetirementChecks++;
          ColdRollbackStateRestoration? recovered;
          final trees = <(MaintenanceTree, Map<String, Object?>)>[];
          try {
            final inputs = await pairedCheckpoint();
            final path = '${backups.path}/restored-old-app';
            final bytes = await File(
              '$path/completed/record.json',
            ).readAsBytes();
            final completed = await OwnedImageDirectory.open(
              Directory('$path/completed'),
            );
            final identity = await completed.maintenanceIdentity();
            completed.close();
            await Directory('$path/completed').rename(
              checkpoint == 'missing'
                  ? '${temporary.path}/retained-completion'
                  : '$path/.completed.partial',
            );
            for (final target in {
              state.path,
              app.path,
              inputs.facts['retained_state'] as String,
              inputs.facts['retained_app'] as String,
              '${backups.path}/upgrade/original-app',
              '${backups.path}/upgrade/original-state',
              '${backups.path}/restored-old-state',
              '${inputs.native.path}/old',
              '${inputs.native.path}/candidate',
            }) {
              final tree = await MaintenanceTree.open(Directory(target));
              trees.add((tree, await tree.capture(nativeMetadata: true)));
            }
            final admissions = host.admissions;
            recovered = await reopenPair(inputs.fence, inputs.native);
            expect(recovered.toJson(), inputs.facts);
            expect(host.admissions, admissions);
            expect(
              await File('$path/completed/record.json').readAsBytes(),
              bytes,
            );
            expect(await Directory('$path/.completed.partial').exists(), false);
            if (checkpoint == 'sealed partial') {
              final promoted = await OwnedImageDirectory.open(
                Directory('$path/completed'),
              );
              try {
                expect(await promoted.maintenanceIdentity(), identity);
              } finally {
                promoted.close();
              }
            } else {
              expect(
                await File(
                  '${temporary.path}/retained-completion/record.json',
                ).readAsBytes(),
                bytes,
              );
            }
            for (final (tree, manifest) in trees) {
              await tree.verify(manifest, nativeMetadata: true);
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            recovered?.close();
            for (final (tree, _) in trees) tree.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    for (final lateClosure in [false, true]) {
      test(
        'paired recovery cannot report completion while its ${lateClosure ? "input closure" : "native factory"} is pending',
        () async {
          activeRetirementChecks++;
          ColdStateRestoration? recovered;
          try {
            final inputs = await pairedCheckpoint();
            Future<Map<String, Object?>> record(String path) async =>
                jsonDecode(await File(path).readAsString())
                    as Map<String, Object?>;
            final upgrade = await record(
              '${backups.path}/upgrade/prepared/record.json',
            );
            final retirement = await record(
              '${inputs.native.path}/old/intent.json',
            );
            final publication = await record(
              '${inputs.native.path}/candidate/prepared/record.json',
            );
            final entered = Completer<void>(), release = Completer<void>();
            late ColdStateRestoration borrowed;
            late ColdAppRestoration borrowedApp;
            var closures = 0;
            final pending = ColdStateRestoration.openPair(
              backups,
              'restored-old-state',
              stagedOldState: Directory(
                '${backups.path}/rollback/state/payload',
              ),
              oldApp: Directory('${backups.path}/rollback/app/payload.app'),
              retainedApp: Directory('${inputs.native.path}/old/GaoVM.app'),
              installationApp: app,
              original: inputs.fence,
              preservation: (storage: backups, name: 'retained-current'),
              appRestoration: (storage: backups, name: 'restored-old-app'),
              provenancePaths: {
                '${inputs.native.path}/old',
                '${inputs.native.path}/candidate',
              },
              bundleIdentifier: 'org.gaovm.tests.Release',
              observePreparedInputs: () async {},
              verifyPreparedInputs: (state, app) async {
                borrowed = state;
                borrowedApp = app;
                if (lateClosure && ++closures == 2) {
                  entered.complete();
                  await release.future;
                }
              },
              openAppHosts: (proof) async {
                borrowedApp = proof;
                if (!lateClosure) {
                  entered.complete();
                  await release.future;
                }
                return MacOsColdStateHost.openRollbackObservers(
                  proof,
                  releases: {
                    '${backups.path}/rollback/app/payload.app':
                        upgrade['original_release'] as Map<String, Object?>,
                    '${inputs.native.path}/old/GaoVM.app':
                        retirement['release'] as Map<String, Object?>,
                    app.path: publication['release'] as Map<String, Object?>,
                  },
                  publicationPaths: {
                    '${inputs.native.path}/candidate/candidate/payload.app',
                    app.path,
                  },
                  host: host,
                  observer: MacOsOpenReferences(
                    command: (_, _) async => ProcessResult(pid, 1, '', ''),
                  ),
                  inventory: (_) async => DriverInventorySnapshot(
                    processes: [],
                    unresolvedProcessIds: [],
                  ),
                );
              },
            );
            unawaited(
              pending.then<void>(
                (_) {
                  if (!entered.isCompleted)
                    entered.completeError(StateError('missing paired factory'));
                },
                onError: (Object error, StackTrace stack) {
                  if (!entered.isCompleted) entered.completeError(error, stack);
                },
              ),
            );
            try {
              await entered.future;
              expect(borrowed.close, throwsStateError);
              expect(borrowed.toJson, throwsStateError);
              expect(borrowedApp.toJson, throwsStateError);
              await expectLater(borrowed.verify(), throwsStateError);
              await expectLater(
                reopenPair(inputs.fence, inputs.native),
                throwsStateError,
              );
              for (final target in [
                state,
                Directory(inputs.facts['retained_state'] as String),
              ]) {
                final root = await OwnedImageDirectory.open(target);
                try {
                  expect(
                    await root.tryAcquireMaintenanceLock(
                      '.gaovmd.lock',
                      create: false,
                    ),
                    isNull,
                  );
                } finally {
                  root.close();
                }
              }
            } finally {
              release.complete();
              recovered = await pending;
            }
            expect(recovered.restoredApp.toJson(), inputs.facts);
            await recovered.verify();
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            recovered?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    test(
      'paired rollback recovery reopens the installed old pair under both real owners without startup',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        ColdRollbackStateRestoration? restored, recovered;
        MaintenanceStateFence? fence, recoveredFence;
        MacOsColdStateHost? currentHost;
        OwnedImageDirectory? nativeStorage;
        try {
          (rollback, restored) = await restoredNativeRollback(
            onPrepared: (original, native, storage) {
              fence = original;
              currentHost = native;
              nativeStorage = storage;
            },
          );
          await restored.restoreOldApp();
          final before = restored.toJson();
          final componentRecord = File(
            '${backups.path}/restored-old-state/completed/record.json',
          );
          final componentBytes = await componentRecord.readAsBytes();
          restored.close();
          currentHost!.close();
          fence!.close();
          lease.close();
          recoveredFence = await MaintenanceStateFence.open(state);
          final admissions = host.admissions;
          recovered = await ColdRollbackStateRestoration.open(
            backups,
            'upgrade',
            recoveredFence,
            installationApp: app,
            retirement: (storage: nativeStorage!, name: 'old'),
            publication: (storage: nativeStorage!, name: 'candidate'),
            bundleIdentifier: 'org.gaovm.tests.Release',
            acceptHistoryRewind: true,
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            sourceCatalogSchema: 21,
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          expect(recovered.toJson(), before);
          await recovered.verify();
          expect(await componentRecord.readAsBytes(), componentBytes);
          expect(host.admissions, admissions);
          for (final target in [
            state,
            Directory(recovered.retainedStatePath),
          ]) {
            final directory = await OwnedImageDirectory.open(target);
            try {
              expect(
                await directory.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                ),
                isNull,
              );
            } finally {
              directory.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
          expect(
            await File(
              '${recovered.retainedStatePath}/failed-generation',
            ).readAsString(),
            'retain the failed generation',
          );
          recovered.close();
          for (final target in [
            state,
            Directory(recovered.retainedStatePath),
          ]) {
            final directory = await OwnedImageDirectory.open(target);
            try {
              final released = await directory.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              expect(released, isNotNull);
              released?.close();
            } finally {
              directory.close();
            }
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          recovered?.close();
          recoveredFence?.close();
          restored?.close();
          rollback?.close();
          currentHost?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'rollback app cutover restores the matching installed pair and retains the published failed app',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        ColdRollbackStateRestoration? restored;
        try {
          (rollback, restored) = await restoredNativeRollback();
          final staged = await OwnedImageDirectory.open(
            Directory(rollback.appPath),
          );
          late Map<String, Object?> oldIdentity;
          try {
            oldIdentity = await staged.maintenanceIdentity();
          } finally {
            staged.close();
          }
          final candidate = await OwnedImageDirectory.open(app);
          late Map<String, Object?> candidateIdentity;
          try {
            candidateIdentity = await candidate.maintenanceIdentity();
          } finally {
            candidate.close();
          }
          final stateRecord = File(
            '${backups.path}/restored-old-state/completed/record.json',
          );
          final stateRecordBefore = await stateRecord.readAsBytes();
          final probes = host.admissions;
          await restored.restoreOldApp();
          await restored.verify();
          final facts = restored.toJson();
          expect(facts['phase'], 'old_pair_restored');
          expect(facts['app_path'], app.path);
          expect(facts['canonical_state_restored'], true);
          expect(facts['installed_pair_restored'], true);
          for (final flag in [
            'committed',
            'startup_allowed',
            'service_actions_performed',
          ]) {
            expect(facts[flag], false);
          }
          expect(host.admissions, probes);
          expect(await stateRecord.readAsBytes(), stateRecordBefore);
          expect(
            await File(
              '${app.path}/Contents/Resources/pair-only',
            ).readAsString(),
            'preserve unknown app resource',
          );
          expect(await Directory(rollback.appPath).exists(), false);
          for (final (path, identity) in [
            (app.path, oldIdentity),
            (facts['retained_app'] as String, candidateIdentity),
          ]) {
            final directory = await OwnedImageDirectory.open(Directory(path));
            try {
              expect(await directory.maintenanceIdentity(), identity);
            } finally {
              directory.close();
            }
          }
          expect(
            await File(
              '${restored.retainedStatePath}/failed-generation',
            ).readAsString(),
            'retain the failed generation',
          );
          expect(await File('${state.path}/failed-generation').exists(), false);
          rollback.close();
          lease.close();
          await restored.verify();
          for (final target in [state, Directory(restored.retainedStatePath)]) {
            final directory = await OwnedImageDirectory.open(target);
            try {
              expect(
                await directory.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                ),
                isNull,
              );
            } finally {
              directory.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
          await expectLater(restored.restoreOldApp(), throwsStateError);
          restored.close();
          for (final target in [state, Directory(restored.retainedStatePath)]) {
            final directory = await OwnedImageDirectory.open(target);
            try {
              final released = await directory.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              expect(released, isNotNull);
              released?.close();
            } finally {
              directory.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
          final released = await backups.tryAcquireMaintenanceLock(
            '.gaovm-app-restoration.lock',
            create: false,
          );
          expect(released, isNotNull);
          released?.close();
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          restored?.close();
          rollback?.close();
          lease.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'rollback app cutover rejects a late snapshot writer before completing the installed pair',
      () async {
        activeRetirementChecks++;
        ColdRollbackStateRestoration? restored;
        var late = false;
        try {
          final (rollback, result) = await restoredNativeRollback(
            references: MacOsOpenReferences(
              command: (_, arguments) async =>
                  late &&
                      arguments.last ==
                          '${backups.path}/upgrade/original-app/payload.app'
                  ? ProcessResult(pid, 0, 'p${pid + 1}\x00f3\x00\n', '')
                  : ProcessResult(pid, 1, '', ''),
            ),
          );
          restored = result;
          host.onStatus = () async {
            if (!await Directory(rollback.appPath).exists()) late = true;
          };
          await expectLater(
            restored.restoreOldApp(),
            throwsA(isA<ColdStateFailure>()),
          );
          expect(late, true);
          expect(restored.toJson, throwsStateError);
          await expectLater(restored.restoreOldApp(), throwsStateError);
          expect(
            await Directory(
              '${backups.path}/restored-old-app/completed',
            ).exists(),
            false,
          );
          expect(await app.exists(), true);
          expect(await Directory(rollback.appPath).exists(), false);
          expect(
            await Directory(
              '${backups.path}/restored-old-app/retained.app',
            ).exists(),
            true,
          );
          for (final target in [state, Directory(restored.retainedStatePath)]) {
            final root = await OwnedImageDirectory.open(target);
            try {
              expect(
                await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                ),
                isNull,
              );
            } finally {
              root.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          host.onStatus = null;
          restored?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'rollback app cutover refuses a foreign installation target before native helpers or app moves',
      () async {
        activeRetirementChecks++;
        ColdRollbackStateRestoration? restored;
        try {
          final (rollback, result) = await restoredNativeRollback();
          restored = result;
          final candidate = '${temporary.path}/kept-candidate.app';
          await app.rename(candidate);
          await app.create();
          await File(
            '${app.path}/foreign',
          ).writeAsString('keep foreign app', flush: true);
          final calls = host.statusCalls;
          await expectLater(restored.restoreOldApp(), throwsFormatException);
          expect(
            host.statusCalls,
            calls,
            reason: 'complete placement checks precede native observers',
          );
          expect(
            await File('${app.path}/foreign').readAsString(),
            'keep foreign app',
          );
          expect(await Directory(candidate).exists(), true);
          expect(await Directory(rollback.appPath).exists(), true);
          expect(
            await Directory('${backups.path}/restored-old-app').exists(),
            false,
          );
          for (final target in [state, Directory(restored.retainedStatePath)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          restored?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    for (final mutation in ['placement journal', 'retained app']) {
      test(
        'rollback app cutover refuses late changed $mutation without undo or completion',
        () async {
          activeRetirementChecks++;
          ColdRollbackStateRestoration? restored;
          var changed = false;
          try {
            final (rollback, result) = await restoredNativeRollback();
            restored = result;
            final path = mutation == 'placement journal'
                ? '${backups.path}/restored-old-app/intent.json'
                : '${backups.path}/restored-old-app/retained.app/Contents/Info.plist';
            final file = File(path);
            host.onStatus = () async {
              if (!changed && !await Directory(rollback.appPath).exists()) {
                changed = true;
                if (mutation == 'placement journal') {
                  imageFileMode(file.path, 0x180);
                }
                await file.writeAsString(
                  'retain late $mutation bytes',
                  flush: true,
                );
              }
            };
            await expectLater(restored.restoreOldApp(), throwsFormatException);
            expect(changed, true);
            expect(await file.readAsString(), 'retain late $mutation bytes');
            expect(await app.exists(), true);
            expect(await Directory(rollback.appPath).exists(), false);
            expect(
              await Directory(
                '${backups.path}/restored-old-app/completed',
              ).exists(),
              false,
            );
            expect(restored.toJson, throwsStateError);
            await expectLater(restored.verify(), throwsStateError);
            await expectLater(restored.restoreOldApp(), throwsStateError);
            for (final target in [
              state,
              Directory(restored.retainedStatePath),
            ]) {
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            host.onStatus = null;
            restored?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    test(
      'rollback app cutover retains original publication paths in post-move unresolved-process checks',
      () async {
        activeRetirementChecks++;
        ColdRollbackStateRestoration? restored;
        var moved = false, observed = false;
        final stagedExecutable =
            '${temporary.path}/paired-apps/candidate/candidate/payload.app/Contents/MacOS/gaovmd';
        try {
          final (rollback, result) = await restoredNativeRollback(
            processInventory: (path) async {
              if (moved && path == stagedExecutable) {
                observed = true;
                return DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [pid + 1],
                );
              }
              return DriverInventorySnapshot(
                processes: [],
                unresolvedProcessIds: [],
              );
            },
          );
          restored = result;
          host.onStatus = () async {
            if (!await Directory(rollback.appPath).exists()) moved = true;
          };
          await expectLater(
            restored.restoreOldApp(),
            throwsA(isA<ColdStateFailure>()),
          );
          expect(moved, true);
          expect(observed, true);
          expect(restored.toJson, throwsStateError);
          expect(
            await Directory(
              '${backups.path}/restored-old-app/completed',
            ).exists(),
            false,
          );
          expect(await app.exists(), true);
          expect(
            await Directory(
              '${backups.path}/restored-old-app/retained.app',
            ).exists(),
            true,
          );
          for (final target in [state, Directory(restored.retainedStatePath)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          host.onStatus = null;
          restored?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'rollback app cutover and later verification retain owners through pending native callbacks',
      () async {
        activeRetirementChecks++;
        ColdRollbackStateRestoration? restored;
        try {
          final (rollback, result) = await restoredNativeRollback();
          restored = result;
          for (final verification in [false, true]) {
            final entered = Completer<void>();
            final release = Completer<void>();
            host.onStatus = () async {
              if (!entered.isCompleted &&
                  !await Directory(rollback.appPath).exists()) {
                entered.complete();
                await release.future;
              }
            };
            var settled = false;
            final pending =
                (verification ? restored.verify() : restored.restoreOldApp())
                    .whenComplete(() => settled = true);
            try {
              await entered.future;
              expect(settled, false);
              expect(restored.close, throwsStateError);
              expect(restored.toJson, throwsStateError);
              await expectLater(restored.verify(), throwsStateError);
              await expectLater(restored.restoreOldApp(), throwsStateError);
              rollback.close();
              for (final target in [
                state,
                Directory(restored.retainedStatePath),
              ]) {
                final root = await OwnedImageDirectory.open(target);
                try {
                  expect(
                    await root.tryAcquireMaintenanceLock(
                      '.gaovmd.lock',
                      create: false,
                    ),
                    isNull,
                  );
                } finally {
                  root.close();
                }
              }
            } finally {
              release.complete();
              await pending;
            }
            expect(settled, true);
            expect(restored.toJson()['installed_pair_restored'], true);
            expect(restored.toJson()['startup_allowed'], false);
          }
          host.onStatus = null;
          await restored.verify();
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          host.onStatus = null;
          restored?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    for (final published in [false, true]) {
      test(
        'rollback state cutover composes native ${published ? 'published' : 'retired'} current-app provenance',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          ColdRollbackStateRestoration? restored;
          MacOsColdStateHost? native, currentHost;
          OwnedImageDirectory? retirement;
          try {
            lease.close();
            MacOsOpenReferences observer() => MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            );
            Future<DriverInventorySnapshot> inventory(String _) async =>
                DriverInventorySnapshot(
                  processes: [],
                  unresolvedProcessIds: [],
                );
            native = await MacOsColdStateHost.open(
              app,
              bundleIdentifier: 'org.gaovm.tests.Release',
              version: '0.1.0',
              teamIdentifier: 'ABCDEFGHIJ',
              catalogSchema: 21,
              host: host,
              observer: observer(),
              inventory: inventory,
            );
            lease = await ColdStateLease.acquire(
              state,
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: native,
            );
            final (snapshot, fence, upgrade) = await fencedPreparation();
            final parent = await OwnedImageDirectory.open(temporary);
            try {
              retirement = parent.createDirectory('cutover-apps');
            } finally {
              parent.close();
            }
            await upgrade.retireOriginalApp(retirement, 'old');
            if (published)
              await upgrade.publishCandidate(retirement, 'candidate');
            upgrade.close();
            snapshot.close();
            if (published) {
              lease.close();
              currentHost = await MacOsColdStateHost.openPublished(
                app,
                state,
                fence,
                retirement,
                'old',
                retirement,
                'candidate',
                bundleIdentifier: 'org.gaovm.tests.Release',
                oldVersion: '0.1.0',
                newVersion: '0.1.0',
                teamIdentifier: 'ABCDEFGHIJ',
                retiredCatalogSchema: 21,
                catalogSchema: 21,
                host: host,
                observer: observer(),
                inventory: inventory,
              );
              lease = await ColdStateLease.acquire(
                state,
                bundleIdentifier: 'org.gaovm.tests.Release',
                host: currentHost,
                maintenanceFence: fence,
              );
            }
            rollback = await prepareRollback(fence);
            final probes = host.admissions;
            restored = await rollback.restoreOldState();
            rollback.close();
            await restored.verify();
            expect(
              host.admissions,
              probes,
              reason:
                  'cutover never activates an actual state or reruns publication',
            );
            expect(restored.toJson()['startup_allowed'], false);
            expect(
              await Directory('${retirement.path}/old/GaoVM.app').exists(),
              true,
            );
            expect(await app.exists(), published);
            if (!published) {
              await restored.restoreOldApp();
              await restored.verify();
              expect(restored.toJson()['installed_pair_restored'], true);
              expect(restored.toJson()['retained_app'], isNull);
              expect(restored.toJson()['startup_allowed'], false);
              expect(await app.exists(), true);
              expect(host.admissions, probes);
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            restored?.close();
            rollback?.close();
            lease.close();
            currentHost?.close();
            native?.close();
            retirement?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }

    for (final condition in [
      'unchanged external files',
      'late external writer',
      'late external bytes',
    ]) {
      test(
        'rollback state cutover checks pre-catalog $condition without initializing the old catalog',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          ColdRollbackStateRestoration? restored;
          var late = false;
          try {
            lease.close();
            await File(
              '${state.path}/gaovm.db',
            ).rename('${temporary.path}/retained-modern.db');
            final kernel = await File(
              '${temporary.path}/rollback-kernel',
            ).writeAsString('original kernel', flush: true);
            final disk = await File(
              '${temporary.path}/rollback-disk',
            ).writeAsString('original external disk', flush: true);
            for (final file in [kernel, disk]) imageFileMode(file.path, 0x180);
            await File('${state.path}/config.json').writeAsString(
              jsonEncode({
                'boot': {'loader': 'linux', 'kernelPath': kernel.path},
                'disk': {'path': disk.path},
              }),
              flush: true,
            );
            imageFileMode('${state.path}/config.json', 0x180);
            lease = await ColdStateLease.acquire(
              state,
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: coldHost,
            );
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            await File(
              '${state.path}/gaovm.db',
            ).writeAsString('retain failed first migration', flush: true);
            imageFileMode('${state.path}/gaovm.db', 0x180);
            rollback = await prepareRollback(
              fence,
              sourceCatalogSchema: null,
              observer: MacOsOpenReferences(
                command: (_, arguments) async =>
                    late &&
                        condition == 'late external writer' &&
                        arguments.last == disk.path
                    ? ProcessResult(pid, 0, 'p${pid + 1}\x00f3\x00\n', '')
                    : ProcessResult(pid, 1, '', ''),
              ),
            );
            final stagedPath = rollback.statePath;
            coldHost.onStatus = () async {
              if (!late &&
                  condition != 'unchanged external files' &&
                  await state.exists() &&
                  !await Directory(stagedPath).exists()) {
                late = true;
                if (condition == 'late external bytes')
                  await disk.writeAsString(
                    'retain late external disk mutation',
                    flush: true,
                  );
              }
            };
            if (condition == 'unchanged external files') {
              restored = await rollback.restoreOldState();
              await restored.verify();
              expect(restored.toJson()['startup_allowed'], false);
            } else {
              await expectLater(
                rollback.restoreOldState(),
                throwsA(anyOf(isA<FormatException>(), isA<ColdStateFailure>())),
              );
              expect(late, true);
            }
            expect(await File('${state.path}/gaovm.db').exists(), false);
            expect(await Directory(stagedPath).exists(), false);
            expect(
              await File(
                '${backups.path}/retained-current/state/gaovm.db',
              ).readAsString(),
              'retain failed first migration',
            );
            expect(await kernel.readAsString(), 'original kernel');
            expect(
              await disk.readAsString(),
              condition == 'late external bytes'
                  ? 'retain late external disk mutation'
                  : 'original external disk',
            );
            for (final target in [
              state,
              Directory('${backups.path}/retained-current/state'),
            ]) {
              final root = await OwnedImageDirectory.open(target);
              try {
                final competing = await root.tryAcquireMaintenanceLock(
                  '.gaovmd.lock',
                  create: false,
                );
                expect(competing, isNull);
                competing?.close();
              } finally {
                root.close();
              }
              await expectLater(
                MaintenanceStateFence.requireUnfenced(target),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            }
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            coldHost.onStatus = null;
            restored?.close();
            rollback?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final condition in [
      'unchanged external files',
      'changed external bytes',
      'external writer',
    ]) {
      test(
        'rollback preparation handles pre-catalog $condition without initializing a catalog',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          MaintenanceTree? current;
          try {
            lease.close();
            await File(
              '${state.path}/gaovm.db',
            ).rename('${temporary.path}/retained-modern.db');
            final kernel = await File(
              '${temporary.path}/rollback-kernel',
            ).writeAsString('original kernel', flush: true);
            final disk = await File(
              '${temporary.path}/rollback-disk',
            ).writeAsString('original external disk', flush: true);
            for (final file in [kernel, disk]) imageFileMode(file.path, 0x180);
            await File('${state.path}/config.json').writeAsString(
              jsonEncode({
                'boot': {'loader': 'linux', 'kernelPath': kernel.path},
                'disk': {'path': disk.path},
              }),
              flush: true,
            );
            imageFileMode('${state.path}/config.json', 0x180);
            lease = await ColdStateLease.acquire(
              state,
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: coldHost,
            );
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            await File(
              '${state.path}/gaovm.db',
            ).writeAsString('retain failed first migration', flush: true);
            imageFileMode('${state.path}/gaovm.db', 0x180);
            if (condition == 'changed external bytes') {
              await disk.writeAsString('external disk changed', flush: true);
            }
            current = await MaintenanceTree.open(state);
            final before = await current.capture(nativeMetadata: true);
            final references = MacOsOpenReferences(
              command: (_, arguments) async =>
                  condition == 'external writer' && arguments.last == disk.path
                  ? ProcessResult(pid, 0, 'p${pid + 1}\x00f3\x00\n', '')
                  : ProcessResult(pid, 1, '', ''),
            );
            Future<void> prepare() async {
              rollback = await prepareRollback(
                fence,
                sourceCatalogSchema: null,
                observer: references,
              );
            }

            if (condition == 'unchanged external files') {
              await prepare();
              expect(rollback!.toJson()['catalog_schema'], isNull);
              expect(
                await FileSystemEntity.type(
                  '${rollback!.statePath}/gaovm.db',
                  followLinks: false,
                ),
                FileSystemEntityType.notFound,
              );
              await rollback!.verify();
            } else {
              await expectLater(
                prepare(),
                condition == 'external writer'
                    ? throwsA(isA<ColdStateFailure>())
                    : throwsFormatException,
              );
            }
            await current.verify(before, nativeMetadata: true);
            expect(await kernel.readAsString(), 'original kernel');
            expect(
              await disk.readAsString(),
              condition == 'changed external bytes'
                  ? 'external disk changed'
                  : 'original external disk',
            );
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            rollback?.close();
            current?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final lateWriter in [false, true]) {
      test(
        'rollback preparation refuses an original-state reference ${lateWriter ? "after checkpoint" : "before copying"}',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          MaintenanceTree? current;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            current = await MaintenanceTree.open(state);
            final before = await current.capture(nativeMetadata: true);
            final references = MacOsOpenReferences(
              command: (_, arguments) async =>
                  arguments.last ==
                          '${backups.path}/upgrade/original-state/payload' &&
                      (!lateWriter ||
                          maintenancePathEntryExists(
                            '${backups.path}/rollback/prepared/record.json',
                          ))
                  ? ProcessResult(pid, 0, 'p${pid + 1}\x00f3\x00\n', '')
                  : ProcessResult(pid, 1, '', ''),
            );
            await expectLater(() async {
              rollback = await prepareRollback(fence, observer: references);
            }, throwsA(isA<ColdStateFailure>()));
            if (!lateWriter) {
              for (final name in ['app', 'state']) {
                expect(
                  maintenancePathEntryExists('${backups.path}/rollback/$name'),
                  isFalse,
                );
              }
            }
            await current.verify(before, nativeMetadata: true);
            await lease.verify();
            final root = await OwnedImageDirectory.open(state);
            final contender = await root.tryAcquireMaintenanceLock(
              '.gaovmd.lock',
              create: false,
            );
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
              root.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            rollback?.close();
            current?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'rollback preparation requires history rewind acceptance before writing output',
      () async {
        activeRetirementChecks++;
        try {
          final (_, fence, _) = await fencedPreparation();
          final tree = await MaintenanceTree.open(temporary);
          try {
            final before = await tree.capture(nativeMetadata: true);
            await expectLater(
              prepareRollback(fence, acceptHistoryRewind: false),
              throwsFormatException,
            );
            await tree.verify(before, nativeMetadata: true);
          } finally {
            tree.close();
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'rollback preparation retains both owners until pending verification settles',
      () async {
        activeRetirementChecks++;
        ColdRollbackPreparation? rollback;
        Future<void>? observed;
        final entered = Completer<void>(), release = Completer<void>();
        Object? failure;
        try {
          final (snapshot, fence, upgrade) = await fencedPreparation();
          upgrade.close();
          snapshot.close();
          rollback = await prepareRollback(fence);
          coldHost.onStatus = () async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
          observed = rollback.verify().then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              failure = error;
            },
          );
          await entered.future;
          expect(rollback.close, throwsStateError);
          await expectLater(rollback.verify(), throwsStateError);
          for (final path in [state.path, rollback.statePath]) {
            final root = await OwnedImageDirectory.open(Directory(path));
            final contender = await root.tryAcquireMaintenanceLock(
              '.gaovmd.lock',
              create: false,
            );
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
              root.close();
            }
          }
          release.complete();
          await observed;
          expect(failure, isNull);
          rollback.close();
          final root = await OwnedImageDirectory.open(
            Directory(rollback.statePath),
          );
          final next = await DaemonOwnership.tryAcquire(root);
          try {
            expect(next, isNotNull);
            await next!.verify();
          } finally {
            next?.close();
            root.close();
          }
          await lease.verify();
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          if (!release.isCompleted) release.complete();
          await observed;
          coldHost.onStatus = null;
          rollback?.close();
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'rollback preparation uses the complete old pair without opening a damaged current catalog',
      () async {
        activeRetirementChecks++;
        try {
          final (snapshot, fence, upgrade) = await fencedPreparation();
          upgrade.close();
          snapshot.close();
          await File('${state.path}/gaovm.db').writeAsString(
            'incomplete migration; preserve for investigation',
            flush: true,
          );
          await File(
            '${state.path}/unknown-data',
          ).writeAsString('post-upgrade data must survive', flush: true);
          final current = await MaintenanceTree.open(state);
          final pair = await MaintenanceTree.open(
            Directory('${backups.path}/upgrade'),
          );
          ColdRollbackPreparation? rollback;
          try {
            final currentBefore = await current.capture(nativeMetadata: true);
            final pairBefore = await pair.capture(nativeMetadata: true);
            rollback = await prepareRollback(fence);
            final report = rollback.toJson();
            expect(report['phase'], 'rollback_prepared');
            expect(report['catalog_schema'], 21);
            expect(report['ordinary_startup_fenced'], true);
            expect(report['installed_pair_restored'], false);
            expect(report['committed'], false);
            expect(report['startup_allowed'], false);
            expect(
              await File('${rollback.statePath}/unknown-data').readAsString(),
              'preserve state',
            );
            expect(
              await File(
                '${rollback.appPath}/Contents/Resources/pair-only',
              ).readAsString(),
              'preserve unknown app resource',
            );
            final root = await OwnedImageDirectory.open(
              Directory(rollback.statePath),
            );
            final contender = await DaemonOwnership.tryAcquire(root);
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
              root.close();
            }
            for (final entry in {
              '${backups.path}/upgrade/original-app/payload.app':
                  rollback.appPath,
              '${backups.path}/upgrade/original-state/payload':
                  rollback.statePath,
            }.entries) {
              final original = await MaintenanceTree.open(Directory(entry.key));
              final restored = await MaintenanceTree.open(
                Directory(entry.value),
              );
              try {
                await restored.verify(
                  await original.capture(nativeMetadata: true),
                  nativeMetadata: true,
                );
              } finally {
                restored.close();
                original.close();
              }
            }
            final process = await Process.start(Platform.resolvedExecutable, [
              '--packages=${Directory.current.path}/.dart_tool/package_config.json',
              '${Directory.current.path}/test/fixtures/hold_daemon_ownership.dart',
              rollback.statePath,
            ]);
            final child = OwnedTestProcess(process);
            children.add(child);
            await process.stdin.close();
            final probe = await child.result();
            expect(probe.exitCode, 3);
            expect((probe.stdout as String).trim(), 'busy');
            expect(child.exitConfirmed, true);
            await rollback.verify();
            await current.verify(currentBefore, nativeMetadata: true);
            await pair.verify(pairBefore, nativeMetadata: true);
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } finally {
            rollback?.close();
            pair.close();
            current.close();
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    for (final target in {
      'original snapshot': 'upgrade',
      'restoration storage': 'rollback',
    }.entries) {
      test(
        'rollback preparation refuses a late changed ${target.key} namespace lock',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            var changed = false;
            final lock = File(
              '${backups.path}/${target.value}/.gaovm-maintenance.lock',
            );
            coldHost.onStatus = () async {
              if (!changed &&
                  File(
                    '${backups.path}/rollback/prepared/record.json',
                  ).existsSync()) {
                changed = true;
                await lock.writeAsString(
                  'foreign namespace bytes',
                  flush: true,
                );
              }
            };
            await expectLater(() async {
              rollback = await prepareRollback(fence);
            }(), throwsFormatException);
            expect(changed, true);
            expect(await lock.readAsString(), 'foreign namespace bytes');
            await lease.verify();
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            coldHost.onStatus = null;
            rollback?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final partial in [false, true]) {
      test(
        'rollback preparation reopens a complete ${partial ? "sealed partial" : "checkpoint"} under fresh real ownership',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          MaintenanceStateFence? recoveredFence;
          OwnedImageDirectory? scratch;
          MaintenanceTree? retained;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            await File(
              '${state.path}/gaovm.db',
            ).writeAsString('retain interrupted migration', flush: true);
            rollback = await prepareRollback(fence);
            final before = rollback.toJson();
            retained = await MaintenanceTree.open(Directory(rollback.path));
            final manifest = await retained.capture(nativeMetadata: true);
            rollback.close();
            if (partial) {
              await Directory(
                '${rollback.path}/prepared',
              ).rename('${rollback.path}/.prepared.partial');
            }
            fence.close();
            lease.close();
            recoveredFence = await MaintenanceStateFence.open(state);
            lease = await ColdStateLease.acquire(
              state,
              bundleIdentifier: 'org.gaovm.tests.Release',
              host: coldHost,
              maintenanceFence: recoveredFence,
            );
            final directory = await Directory(
              '${temporary.path}/rollback-recovery-inspection',
            ).create();
            imageFileMode(directory.path, 0x1c0);
            scratch = await OwnedImageDirectory.open(directory);
            rollback = await reopenRollback(recoveredFence, scratch);
            expect(rollback.toJson(), before);
            await rollback.verify();
            if (partial) {
              Map<String, Object?> normalized(Map<String, Object?> value) {
                final copy =
                    jsonDecode(jsonEncode(value)) as Map<String, Object?>;
                // Only the journal root mtime changes when its fixed completion
                // entry moves; every payload's complete native manifest stays exact.
                ((copy[''] as Map)['metadata'] as Map).remove('modified');
                return copy;
              }

              expect(
                normalized(await retained.capture(nativeMetadata: true)),
                normalized(manifest),
              );
              expect(
                await Directory('${rollback.path}/.prepared.partial').exists(),
                false,
              );
              expect(
                await Directory('${rollback.path}/prepared').exists(),
                true,
              );
            } else {
              await retained.verify(manifest, nativeMetadata: true);
            }
            expect(
              await File('${state.path}/gaovm.db').readAsString(),
              'retain interrupted migration',
            );
            final root = await OwnedImageDirectory.open(
              Directory(rollback.statePath),
            );
            final contender = await DaemonOwnership.tryAcquire(root);
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
              root.close();
            }
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            rollback?.close();
            retained?.close();
            scratch?.close();
            recoveredFence?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final change in [
      'unknown entry',
      'incomplete record',
      'changed current state',
      'substituted state',
      'forged commit',
    ]) {
      test(
        'rollback preparation recovery retains $change without repair or helper execution',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          OwnedImageDirectory? scratch;
          MaintenanceTree? retained;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            rollback = await prepareRollback(fence);
            final path = rollback.path, restored = rollback.statePath;
            rollback.close();
            switch (change) {
              case 'unknown entry':
                final file = await File(
                  '$path/unknown',
                ).writeAsString('retain foreign output');
                imageFileMode(file.path, 0x180);
              case 'incomplete record':
                await Directory(
                  '$path/prepared',
                ).rename('$path/.prepared.partial');
                await File(
                  '$path/.prepared.partial/record.json',
                ).rename('$path/.prepared.partial/incomplete-record');
              case 'changed current state':
                await File(
                  '${state.path}/unknown-data',
                ).writeAsString('retain intervening write', flush: true);
              case 'substituted state':
                final directory = await Directory(
                  '${temporary.path}/replacement',
                ).create();
                imageFileMode(directory.path, 0x1c0);
                final parent = await OwnedImageDirectory.open(directory);
                final original = await MaintenanceTree.open(
                  Directory(restored),
                );
                try {
                  await original.snapshotTo(parent, 'copy');
                } finally {
                  original.close();
                  parent.close();
                }
                await Directory(
                  restored,
                ).rename('${temporary.path}/retained-restoration-inode');
                await Directory(
                  '${directory.path}/copy/payload',
                ).rename(restored);
              case 'forged commit':
                final file = File('$path/prepared/record.json');
                final record =
                    jsonDecode(await file.readAsString())
                        as Map<String, Object?>;
                record['committed'] = true;
                imageFileMode(file.path, 0x180);
                await file.writeAsString(
                  '${jsonEncode(record)}\n',
                  flush: true,
                );
                imageFileMode(file.path, 0x100);
            }
            final directory = await Directory(
              '${temporary.path}/refused-recovery-inspection',
            ).create();
            imageFileMode(directory.path, 0x1c0);
            scratch = await OwnedImageDirectory.open(directory);
            retained = await MaintenanceTree.open(temporary);
            final before = await retained.capture(nativeMetadata: true);
            final executed = host.executedRoles.length;
            await expectLater(
              () async {
                rollback = await reopenRollback(fence, scratch!);
              }(),
              throwsA(
                anyOf(isA<FormatException>(), isA<FileSystemException>()),
              ),
            );
            expect(host.executedRoles.length, executed);
            await retained.verify(before, nativeMetadata: true);
            await lease.verify();
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            rollback?.close();
            retained?.close();
            scratch?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    for (final change in [
      'current state',
      'restoration bytes',
      'restoration metadata',
      'completion flags',
    ]) {
      test(
        'rollback preparation refuses a post-checkpoint change to $change',
        () async {
          activeRetirementChecks++;
          ColdRollbackPreparation? rollback;
          try {
            final (snapshot, fence, upgrade) = await fencedPreparation();
            upgrade.close();
            snapshot.close();
            var changed = false;
            coldHost.onStatus = () async {
              final record = File(
                '${backups.path}/rollback/prepared/record.json',
              );
              if (changed || !record.existsSync()) return;
              changed = true;
              switch (change) {
                case 'current state':
                  await File(
                    '${state.path}/unknown-data',
                  ).writeAsString('retain newer state', flush: true);
                case 'restoration bytes':
                  await File(
                    '${backups.path}/rollback/state/payload/unknown-data',
                  ).writeAsString('retain altered copy', flush: true);
                case 'restoration metadata':
                  imageFileMode(
                    '${backups.path}/rollback/app/payload.app/Contents/Resources/pair-only',
                    0x1a0,
                  );
                case 'completion flags':
                  final value =
                      jsonDecode(await record.readAsString())
                          as Map<String, Object?>;
                  value['committed'] = true;
                  imageFileMode(record.path, 0x180);
                  await record.writeAsString(
                    '${jsonEncode(value)}\n',
                    flush: true,
                  );
                  imageFileMode(record.path, 0x100);
              }
            };
            await expectLater(() async {
              rollback = await prepareRollback(fence);
            }(), throwsFormatException);
            expect(changed, true);
            expect(await Directory('${backups.path}/rollback').exists(), true);
            await lease.verify();
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } catch (_) {
            retainInputs = true;
            rethrow;
          } finally {
            coldHost.onStatus = null;
            rollback?.close();
            activeRetirementChecks--;
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }

    test(
      'prepared upgrade publishes a candidate without releasing original state ownership',
      () async {
        activeRetirementChecks++;
        try {
          lease.close();
          var finalAppObservation = false;
          host.onStatus = () async {
            if (finalAppObservation && maintenancePathEntryExists(app.path)) {
              throw StateError(
                'native callback after final filesystem boundary',
              );
            }
          };
          final nativeHost = await MacOsColdStateHost.open(
            app,
            bundleIdentifier: 'org.gaovm.tests.Release',
            version: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            catalogSchema: 21,
            host: host,
            observer: MacOsOpenReferences(
              command: (_, arguments) async {
                if (arguments.last == app.path &&
                    maintenancePathEntryExists(
                      '${temporary.path}/retirements/old/intent.json',
                    )) {
                  finalAppObservation = true;
                }
                return ProcessResult(pid, 1, '', '');
              },
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          addTearDown(() {
            if (activeRetirementChecks == 0) nativeHost.close();
          });
          lease = await ColdStateLease.acquire(
            state,
            bundleIdentifier: 'org.gaovm.tests.Release',
            host: nativeHost,
          );
          final (prepared, fence, transaction) = await fencedPreparation();
          final retirementDirectory = await Directory(
            '${temporary.path}/retirements',
          ).create();
          imageFileMode(retirementDirectory.path, 0x1c0);
          final retirement = await OwnedImageDirectory.open(
            retirementDirectory,
          );
          final source = await OwnedImageDirectory.open(app);
          final stateRoot = await OwnedImageDirectory.open(state);
          try {
            final oldIdentity = await source.maintenanceIdentity();
            final result = await transaction.retireOriginalApp(
              retirement,
              'old',
            );
            expect(result['phase'], 'old_app_retired');
            expect(finalAppObservation, true);
            expect(result['installed_candidate_published'], false);
            expect(lease.installationPath, app.path);
            expect(lease.appPath, '${retirement.path}/old/GaoVM.app');
            expect(maintenancePathEntryExists(app.path), false);
            final moved = await OwnedImageDirectory.open(
              Directory(lease.appPath),
            );
            try {
              expect(await moved.maintenanceIdentity(), oldIdentity);
            } finally {
              moved.close();
            }
            expect(
              await DaemonOwnership.tryAcquireForMaintenance(stateRoot, fence),
              isNull,
            );
            await lease.verify();
            await transaction.verify();
            expect(
              await File('${state.path}/unknown-data').readAsString(),
              'preserve state',
            );
            expect(
              await File(
                '${transaction.path}/original-app/payload.app/Contents/Resources/pair-only',
              ).readAsString(),
              'preserve unknown app resource',
            );
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            transaction.close();
            final reopened = await ColdUpgradePreparation.open(
              prepared,
              fence,
              backups,
              'upgrade',
              oldVersion: '0.1.0',
              newVersion: '0.1.0',
              teamIdentifier: 'ABCDEFGHIJ',
              host: host,
              observer: MacOsOpenReferences(
                command: (_, _) async => ProcessResult(pid, 1, '', ''),
              ),
            );
            try {
              // The original checkpoint stays immutable, not a commit record.
              expect(reopened.toJson()['phase'], 'candidate_prepared');
              expect(reopened.toJson()['installed_candidate_published'], false);
              host.onStatus =
                  null; // The pre-retirement callback boundary passed.
              final published = await reopened.publishCandidate(
                retirement,
                'candidate',
              );
              expect(published['phase'], 'candidate_published');
              expect(published['activation_authorized'], false);
              expect(published['committed'], false);
              expect(lease.appPath, '${retirement.path}/old/GaoVM.app');
              expect(
                await DaemonOwnership.tryAcquireForMaintenance(
                  stateRoot,
                  fence,
                ),
                isNull,
              );
              expect(
                await Directory(
                  '${reopened.path}/candidate-app/payload.app',
                ).exists(),
                true,
              );
              expect(reopened.toJson()['installed_candidate_published'], false);
              expect(
                await File('${state.path}/unknown-data').readAsString(),
                'preserve state',
              );
              await expectLater(
                MaintenanceStateFence.requireUnfenced(state),
                throwsA(isA<MaintenanceFenceActive>()),
              );
            } finally {
              reopened.close();
            }
          } finally {
            source.close();
            stateRoot.close();
            retirement.close();
          }
        } finally {
          activeRetirementChecks--;
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'fenced candidate preparation journals matching old state without installing it',
      () async {
        final candidate = Directory('${temporary.path}/Candidate.app');
        await _fixture(candidate);
        await File(
          '${candidate.path}/Contents/Resources/candidate-only',
        ).writeAsString('new candidate resource');
        final fence = await MaintenanceStateFence.begin(lease);
        ColdStateSnapshot? prepared;
        ColdUpgradePreparation? transaction;
        final appTree = await MaintenanceTree.open(app);
        final stateTree = await MaintenanceTree.open(state);
        try {
          final oldApp = await appTree.capture(nativeMetadata: true);
          final oldState = await stateTree.capture(nativeMetadata: true);
          prepared = await ColdStateSnapshot.prepare(
            lease,
            inspection,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
            inventory: (_) async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [],
            ),
          );
          transaction = await ColdUpgradePreparation.create(
            prepared,
            fence,
            backups,
            'upgrade',
            candidateApp: candidate,
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
          );
          expect(transaction.toJson()['phase'], 'candidate_prepared');
          expect(transaction.toJson()['catalog_schema'], 21);
          expect(transaction.toJson()['installed_candidate_published'], false);
          expect(
            await File(
              '${transaction.path}/candidate-app/payload.app/Contents/Resources/candidate-only',
            ).readAsString(),
            'new candidate resource',
          );
          expect(
            await File(
              '${transaction.path}/original-state/payload/unknown-data',
            ).readAsString(),
            'preserve state',
          );
          expect(
            await File('${transaction.path}/prepared/record.json').exists(),
            true,
          );
          expect(
            await Directory('${backups.path}/.upgrade.partial').exists(),
            false,
          );
          await transaction.verify();
          await appTree.verify(oldApp, nativeMetadata: true);
          await stateTree.verify(oldState, nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          transaction?.close();
          prepared?.close();
          fence.close();
          appTree.close();
          stateTree.close();
        }
        await lease.verify();
      },
    );

    test(
      'prepared candidate reopens without the original candidate source',
      () async {
        final (prepared, fence, transaction) = await fencedPreparation();
        transaction.close();
        await Directory(
          '${temporary.path}/Candidate.app',
        ).rename('${temporary.path}/retained-candidate.app');
        final reopened = await ColdUpgradePreparation.open(
          prepared,
          fence,
          backups,
          'upgrade',
          oldVersion: '0.1.0',
          newVersion: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
        );
        try {
          expect(reopened.toJson()['phase'], 'candidate_prepared');
          expect(reopened.path, '${backups.path}/upgrade');
          reopened.toJson()['phase'] = 'committed';
          expect(reopened.toJson()['phase'], 'candidate_prepared');
          await reopened.verify();
        } finally {
          reopened.close();
        }
        await fence.verify();
        await lease.verify();
      },
    );

    test(
      'active preparation rejects namespace lock tampering without repairing it',
      () async {
        final (_, _, transaction) = await fencedPreparation();
        final lockFile = File('${backups.path}/.gaovm-upgrade.lock');
        await lockFile.writeAsString('unknown namespace owner');
        await expectLater(
          transaction.verify(),
          throwsA(isA<FormatException>()),
        );
        expect(await lockFile.readAsString(), 'unknown namespace owner');
        await lease.verify();
      },
    );

    test(
      'interrupted candidate preparation retains intent and refuses completed-phase recovery',
      () async {
        final candidate = Directory('${temporary.path}/Candidate.app');
        await _fixture(candidate);
        final (prepared, fence) = await guardedState();
        host.onProbe = () async {
          if (await Directory(
            '${backups.path}/.upgrade.partial/candidate-app',
          ).exists()) {
            throw StateError(
              'injected interruption after all copies, before checkpoint',
            );
          }
        };
        await expectLater(
          ColdUpgradePreparation.create(
            prepared,
            fence,
            backups,
            'upgrade',
            candidateApp: candidate,
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
          ),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        host.onProbe = null;
        final partial = '${backups.path}/.upgrade.partial';
        expect(await File('$partial/intent.json').exists(), true);
        expect(
          await File(
            '$partial/original-state/payload/unknown-data',
          ).readAsString(),
          'preserve state',
        );
        expect(await Directory('$partial/prepared').exists(), false);
        expect(await Directory('${backups.path}/upgrade').exists(), false);
        await expectLater(
          ColdUpgradePreparation.open(
            prepared,
            fence,
            backups,
            'upgrade',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await File('$partial/intent.json').exists(), true);
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'preserve state',
        );
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
        await lease.verify();
      },
    );

    test(
      'preparation catches unknown source writes in the last native checkpoint pass',
      () async {
        var changed = false;
        host.onProbe = () async {
          if (!changed &&
              await File(
                '${backups.path}/.upgrade.partial/prepared/record.json',
              ).exists()) {
            changed = true;
            await File(
              '${state.path}/unknown-data',
            ).writeAsString('late native callback changed unknown state');
          }
        };
        await expectLater(
          fencedPreparation(),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        host.onProbe = null;
        expect(changed, true);
        expect(await Directory('${backups.path}/upgrade').exists(), false);
        expect(
          await File(
            '${backups.path}/.upgrade.partial/prepared/record.json',
          ).exists(),
          true,
        );
        expect(
          await File(
            '${backups.path}/.upgrade.partial/original-state/payload/unknown-data',
          ).readAsString(),
          'preserve state',
        );
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'late native callback changed unknown state',
        );
        await lease.verify();
      },
    );

    test(
      'prepared candidate recovery requires newly acquired cold ownership and fence',
      () async {
        final (prepared, fence, transaction) = await fencedPreparation();
        transaction.close();
        prepared.close();
        lease.close();
        fence.close();
        final recoveredFence = await MaintenanceStateFence.open(state);
        addTearDown(recoveredFence.close);
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Release',
          host: coldHost,
          maintenanceFence: recoveredFence,
        );
        final scratch = await Directory(
          '${temporary.path}/recovery-inspection',
        ).create();
        imageFileMode(scratch.path, 0x1c0);
        final ownedScratch = await OwnedImageDirectory.open(scratch);
        addTearDown(ownedScratch.close);
        final recoveredState = await ColdStateSnapshot.prepare(
          lease,
          ownedScratch,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
          inventory: (_) async =>
              DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
        );
        addTearDown(recoveredState.close);
        final recovered = await ColdUpgradePreparation.open(
          recoveredState,
          recoveredFence,
          backups,
          'upgrade',
          oldVersion: '0.1.0',
          newVersion: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
        );
        try {
          expect(recovered.toJson()['phase'], 'candidate_prepared');
          await recovered.verify();
        } finally {
          recovered.close();
        }
        await recoveredFence.verify();
        await lease.verify();
      },
    );

    test(
      'prepared candidate refuses concurrent recovery and explicit identity disagreement',
      () async {
        final (prepared, fence, transaction) = await fencedPreparation();
        Future<ColdUpgradePreparation> reopen({
          String oldVersion = '0.1.0',
          String newVersion = '0.1.0',
          String team = 'ABCDEFGHIJ',
          String name = 'upgrade',
        }) => ColdUpgradePreparation.open(
          prepared,
          fence,
          backups,
          name,
          oldVersion: oldVersion,
          newVersion: newVersion,
          teamIdentifier: team,
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
        );
        await expectLater(reopen(), throwsA(isA<StateError>()));
        transaction.close();
        final probes = host.executedRoles.length;
        for (final future in [
          () => reopen(oldVersion: '0.2.0'),
          () => reopen(newVersion: '0.2.0'),
          () => reopen(team: 'KLMNOPQRST'),
        ]) {
          await expectLater(future(), throwsA(isA<FormatException>()));
        }
        expect(host.executedRoles.length, probes);
        expect(
          (await command('/bin/cp', [
            '-pR',
            '${backups.path}/upgrade',
            '${backups.path}/copied',
          ])).exitCode,
          0,
        );
        await expectLater(
          reopen(name: 'copied'),
          throwsA(isA<FormatException>()),
        );
        expect(host.executedRoles.length, probes);
        expect(
          await File('${backups.path}/copied/prepared/record.json').exists(),
          true,
        );
        final valid = await reopen();
        valid.close();
        await lease.verify();
      },
    );

    for (final failure in [
      'candidate bytes',
      'old state bytes',
      'wrapper privacy',
      'unknown entry',
      'phase',
      'intent path',
      'signature',
    ]) {
      test(
        'prepared candidate recovery refuses $failure without cleanup',
        () async {
          final (prepared, fence, transaction) = await fencedPreparation();
          transaction.close();
          final root = '${backups.path}/upgrade';
          if (failure == 'candidate bytes') {
            await File(
              '$root/candidate-app/payload.app/Contents/Resources/unknown',
            ).writeAsString('preserve changed candidate');
          } else if (failure == 'old state bytes') {
            final file = File('$root/original-state/payload/unknown-data');
            await file.writeAsString('preserve changed backup');
          } else if (failure == 'wrapper privacy') {
            imageFileMode('$root/original-state', 0x1ed);
          } else if (failure == 'unknown entry') {
            await File(
              '$root/unknown',
            ).writeAsString('preserve unknown checkpoint entry');
          } else if (failure == 'signature') {
            host.rejectSignature = true;
          } else {
            final file = File(
              failure == 'phase'
                  ? '$root/prepared/record.json'
                  : '$root/intent.json',
            );
            final value =
                jsonDecode(await file.readAsString()) as Map<String, Object?>;
            value[failure == 'phase'
                ? 'phase'
                : 'source_state'] = failure == 'phase'
                ? 'committed'
                : '${temporary.path}/foreign-state';
            imageFileMode(file.path, 0x180);
            await file.writeAsString('${jsonEncode(value)}\n');
            imageFileMode(file.path, 0x100);
          }
          final before = await MaintenanceTree.open(Directory(root));
          try {
            final manifest = await before.capture(nativeMetadata: true);
            await expectLater(
              ColdUpgradePreparation.open(
                prepared,
                fence,
                backups,
                'upgrade',
                oldVersion: '0.1.0',
                newVersion: '0.1.0',
                teamIdentifier: 'ABCDEFGHIJ',
                host: host,
                observer: MacOsOpenReferences(
                  command: (_, _) async => ProcessResult(pid, 1, '', ''),
                ),
              ).then((unexpected) {
                unexpected.close();
                return true;
              }),
              throwsA(
                anyOf(isA<FormatException>(), isA<ReleaseInspectionFailure>()),
              ),
            );
            await before.verify(manifest, nativeMetadata: true);
          } finally {
            before.close();
          }
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'preserve state',
          );
          await fence.verify();
          await lease.verify();
        },
      );
    }

    test(
      'prepared checkpoint in retained staging is not recoverable as a published name',
      () async {
        final candidate = Directory('${temporary.path}/Candidate.app');
        await _fixture(candidate);
        final (prepared, fence) = await guardedState();
        host.onProbe = () async {
          if (await File(
            '${backups.path}/.upgrade.partial/prepared/record.json',
          ).exists()) {
            throw StateError('interrupted before outer publication');
          }
        };
        await expectLater(
          ColdUpgradePreparation.create(
            prepared,
            fence,
            backups,
            'upgrade',
            candidateApp: candidate,
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
          ),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        host.onProbe = null;
        expect(
          await File(
            '${backups.path}/.upgrade.partial/prepared/record.json',
          ).exists(),
          true,
        );
        await expectLater(
          ColdUpgradePreparation.open(
            prepared,
            fence,
            backups,
            '.upgrade.partial',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
          ).then((opened) {
            opened.close();
            return true;
          }),
          throwsArgumentError,
        );
        expect(await Directory('${backups.path}/upgrade').exists(), false);
        await lease.verify();
      },
    );

    test(
      'prepared candidate after a final cold failure remains uncommitted and requires revalidation',
      () async {
        final candidate = Directory('${temporary.path}/Candidate.app');
        await _fixture(candidate);
        final (prepared, fence) = await guardedState();
        coldHost.onStatus = () async {
          if (await File(
            '${backups.path}/upgrade/prepared/record.json',
          ).exists())
            coldHost.registered = true;
        };
        await expectLater(
          ColdUpgradePreparation.create(
            prepared,
            fence,
            backups,
            'upgrade',
            candidateApp: candidate,
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
            observer: MacOsOpenReferences(
              command: (_, _) async => ProcessResult(pid, 1, '', ''),
            ),
          ),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(coldHost.registered, true);
        expect(
          await Directory('${backups.path}/.upgrade.partial').exists(),
          false,
        );
        expect(
          await File('${backups.path}/upgrade/prepared/record.json').exists(),
          true,
        );
        coldHost.onStatus = null;
        await expectLater(
          ColdUpgradePreparation.open(
            prepared,
            fence,
            backups,
            'upgrade',
            oldVersion: '0.1.0',
            newVersion: '0.1.0',
            teamIdentifier: 'ABCDEFGHIJ',
            host: host,
          ),
          throwsA(isA<ColdStateFailure>()),
        );
        coldHost.registered = false;
        final recovered = await ColdUpgradePreparation.open(
          prepared,
          fence,
          backups,
          'upgrade',
          oldVersion: '0.1.0',
          newVersion: '0.1.0',
          teamIdentifier: 'ABCDEFGHIJ',
          host: host,
          observer: MacOsOpenReferences(
            command: (_, _) async => ProcessResult(pid, 1, '', ''),
          ),
        );
        try {
          expect(recovered.toJson()['phase'], 'candidate_prepared');
          expect(recovered.toJson()['installed_candidate_published'], false);
          expect(recovered.toJson()['rollback_authorized'], false);
        } finally {
          recovered.close();
        }
        await fence.verify();
        await lease.verify();
      },
    );

    test('another app reference refuses before paired staging', () async {
      final observer = MacOsOpenReferences(
        command: (_, arguments) async => ProcessResult(
          pid,
          1,
          arguments.last == app.path ? 'p123\x00\nf8\x00\n' : '',
          '',
        ),
      );
      await expectLater(
        snapshot(observer: observer).then((_) => true),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      expect(await Directory('${backups.path}/before').exists(), false);
      await lease.verify();
    });

    test(
      'matching app and complete state publish as one durable pair',
      () async {
        final sourceApp = await MaintenanceTree.open(app);
        final sourceState = await MaintenanceTree.open(state);
        try {
          final appBefore = await sourceApp.capture(nativeMetadata: true);
          final stateBefore = await sourceState.capture(nativeMetadata: true);
          final result = await snapshot();
          expect(result['format'], 'gaovm.cold-upgrade-snapshot.v1');
          expect(result['paired_app_snapshot'], true);
          expect(result['external_files_backed_up'], false);
          expect(result['candidate_publication_authorized'], false);
          expect(result['replacement_startup_fenced'], false);
          expect(result['rollback_authorized'], false);
          expect(result['source_app'], app.path);
          expect(result['source_state'], state.path);
          expect(result['catalog_schema'], 21);
          expect(
            await File(
              '${backups.path}/before/state/payload/unknown-data',
            ).readAsString(),
            'preserve state',
          );
          expect(
            await File(
              '${backups.path}/before/app/payload.app/Contents/MacOS/gaovmd',
            ).readAsBytes(),
            await File('${app.path}/Contents/MacOS/gaovmd').readAsBytes(),
          );
          expect(
            jsonDecode(
              await File('${backups.path}/before/receipt.json').readAsString(),
            ),
            result,
          );
          expect(
            await Directory('${backups.path}/.before.partial').exists(),
            false,
          );
          await sourceApp.verify(appBefore, nativeMetadata: true);
          await sourceState.verify(stateBefore, nativeMetadata: true);
          await lease.verify();
        } finally {
          sourceApp.close();
          sourceState.close();
        }
      },
    );
    test('unexpected pair wrapper entries refuse without cleanup', () async {
      var changed = false;
      final target = '${backups.path}/.before.partial/unknown-after-check';
      coldHost.onStatus = () async {
        if (!changed &&
            await File(
              '${backups.path}/.before.partial/receipt.json',
            ).exists()) {
          changed = true;
          await File(target).writeAsString('retain unexpected pair evidence');
        }
      };
      await expectLater(
        snapshot().then((_) => true),
        throwsA(isA<MaintenanceSnapshotFailure>()),
      );
      expect(changed, true);
      expect(
        await File(target).readAsString(),
        'retain unexpected pair evidence',
      );
      expect(await Directory('${backups.path}/before').exists(), false);
      await lease.verify();
    });
    test(
      'app ACL grants refuse rather than weakening source metadata',
      () async {
        final user = (await command('/usr/bin/id', [
          '-un',
        ])).stdout.toString().trim();
        final file = File('${app.path}/Contents/Resources/pair-only');
        expect(
          (await command('/bin/chmod', [
            '+a',
            'user:$user allow read',
            file.path,
          ])).exitCode,
          0,
        );
        await expectLater(
          snapshot().then((_) => true),
          throwsA(isA<ColdStateFailure>()),
        );
        final held = await OwnedImageFile.open(file);
        try {
          expect((await held.maintenanceMetadata())['has_acl'], true);
        } finally {
          held.close();
        }
        expect(
          await Directory('${backups.path}/.before.partial').exists(),
          false,
        );
        await lease.verify();
      },
    );
    for (final failure in [
      'signature',
      'role',
      'public API',
      'catalog range',
      'native evidence',
    ]) {
      test('$failure refusal retains original inputs and ownership', () async {
        if (failure == 'signature') host.rejectSignature = true;
        if (failure == 'role')
          host.componentChanges['cli'] = {'role': 'daemon'};
        if (failure == 'public API')
          host.componentChanges['cli'] = {'public_api': 'v2'};
        if (failure == 'catalog range')
          host.componentChanges['daemon'] = {
            'catalog_schema': {'minimum': 22, 'maximum': 22},
          };
        if (failure == 'native evidence') host.nativeArm64 = false;
        final tree = await MaintenanceTree.open(state);
        try {
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(
            snapshot().then((_) => true),
            throwsA(
              isA<ReleaseInspectionFailure>().having(
                (e) => e.status,
                'status',
                failure == 'native evidence' ? 'unverified' : 'incompatible',
              ),
            ),
          );
          expect(
            await Directory('${backups.path}/.before.partial').exists(),
            false,
          );
          expect(await Directory('${backups.path}/before').exists(), false);
          await tree.verify(before, nativeMetadata: true);
          await assertOwnership();
        } finally {
          tree.close();
        }
      });
    }
    for (final phase in ['partial', 'final']) {
      for (final target in [
        'app/payload.app/Contents/Resources/pair-only',
        'state/payload/unknown-data',
        'app/receipt.json',
        'state/receipt.json',
        'receipt.json',
      ]) {
        test('$phase $target tampering never returns a valid pair', () async {
          var changed = false;
          final root =
              '${backups.path}/${phase == 'partial' ? '.before.partial' : 'before'}';
          final file = File('$root/$target');
          coldHost.onStatus = () async {
            if (!changed && await File('$root/receipt.json').exists()) {
              changed = true;
              imageFileMode(file.path, 0x180);
              await file.writeAsString('retain tampered pair evidence');
            }
          };
          await expectLater(
            snapshot().then((_) => true),
            throwsA(isA<MaintenanceSnapshotFailure>()),
          );
          expect(changed, true);
          expect(await file.readAsString(), 'retain tampered pair evidence');
          expect(
            await Directory('${backups.path}/before').exists(),
            phase == 'final',
          );
          expect(
            await File('${state.path}/unknown-data').readAsString(),
            'preserve state',
          );
          expect(
            await File(
              '${app.path}/Contents/Resources/pair-only',
            ).readAsString(),
            'preserve unknown app resource',
          );
          await assertOwnership();
        });
      }
    }
    for (final target in ['before', '.before.partial']) {
      test(
        'existing $target is retained without inspection or overwrite',
        () async {
          final directory = await Directory('${backups.path}/$target').create();
          imageFileMode(directory.path, 0x1c0);
          await File(
            '${directory.path}/keep',
          ).writeAsString('previous snapshot');
          await expectLater(
            snapshot().then((_) => true),
            throwsFormatException,
          );
          expect(
            await File('${directory.path}/keep').readAsString(),
            'previous snapshot',
          );
          expect(await Directory(inspection.path).list().isEmpty, true);
          expect(host.executedRoles, isEmpty);
          await assertOwnership();
        },
      );
    }
    for (final input in ['app', 'inspection', 'state']) {
      test('storage inside $input refuses without source mutation', () async {
        final storage = input == 'inspection'
            ? inspection
            : await OwnedImageDirectory.open(input == 'app' ? app : state);
        try {
          await expectLater(
            snapshot(storage: storage).then((_) => true),
            throwsFormatException,
          );
          expect(await Directory('${storage.path}/before').exists(), false);
          expect(host.executedRoles, isEmpty);
          await assertOwnership();
        } finally {
          if (input != 'inspection') storage.close();
        }
      });
    }
    test(
      'pre-catalog legacy pair does not initialize or migrate original data',
      () async {
        lease.close();
        final retained = await state.rename(
          '${temporary.path}/retained-modern-state',
        );
        state = await Directory('${temporary.path}/state').create();
        imageFileMode(state.path, 0x1c0);
        final kernel = await File(
          '${temporary.path}/legacy-kernel',
        ).writeAsString('legacy kernel');
        final disk = await File(
          '${temporary.path}/legacy-disk',
        ).writeAsString('guest-mutated legacy disk');
        for (final file in [kernel, disk]) imageFileMode(file.path, 0x180);
        final config = jsonEncode({
          'boot': {'loader': 'linux', 'kernelPath': kernel.path},
          'disk': {'path': disk.path},
        });
        await File('${state.path}/config.json').writeAsString(config);
        imageFileMode('${state.path}/config.json', 0x180);
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Release',
          host: coldHost,
        );
        final result = await snapshot();
        expect(result['catalog_schema'], isNull);
        expect((result['app_release'] as Map)['required_catalog_schema'], 0);
        expect(
          await File(
            '${backups.path}/before/state/payload/config.json',
          ).readAsString(),
          config,
        );
        for (final name in [
          'gaovm.db',
          'gaovm.db-wal',
          'gaovm.db-shm',
          'run',
        ]) {
          expect(
            await FileSystemEntity.type(
              '${state.path}/$name',
              followLinks: false,
            ),
            FileSystemEntityType.notFound,
          );
          expect(
            await FileSystemEntity.type(
              '${backups.path}/before/state/payload/$name',
              followLinks: false,
            ),
            FileSystemEntityType.notFound,
          );
        }
        expect(await File('${retained.path}/gaovm.db').exists(), true);
        expect(await disk.readAsString(), 'guest-mutated legacy disk');
        expect(result['external_files_backed_up'], false);
        await assertOwnership();
      },
    );
    test(
      'closed caller lease refuses before output or inspection I/O',
      () async {
        lease.close();
        await expectLater(snapshot().then((_) => true), throwsStateError);
        expect(await Directory(backups.path).list().isEmpty, true);
        expect(await Directory(inspection.path).list().isEmpty, true);
        expect(host.executedRoles, isEmpty);
      },
    );
    test(
      'unrecognized namespace lock is not normalized or overwritten',
      () async {
        final file = await File(
          '${backups.path}/.gaovm-maintenance.lock',
        ).writeAsString('operator evidence');
        imageFileMode(file.path, 0x1c0);
        await expectLater(snapshot().then((_) => true), throwsFormatException);
        expect(await file.readAsString(), 'operator evidence');
        expect((await file.stat()).mode & 0xfff, 0x1c0);
        expect(await Directory(inspection.path).list().isEmpty, true);
        await assertOwnership();
      },
    );
    test(
      'source app change after its copy retains partial and refuses pairing',
      () async {
        var changed = false;
        final file = File('${app.path}/Contents/Resources/pair-only');
        coldHost.onStatus = () async {
          if (!changed &&
              await File(
                '${backups.path}/.before.partial/app/receipt.json',
              ).exists()) {
            changed = true;
            await file.writeAsString('source changed after app copy');
          }
        };
        await expectLater(
          snapshot().then((_) => true),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(changed, true);
        expect(await file.readAsString(), 'source changed after app copy');
        expect(
          await File(
            '${backups.path}/.before.partial/app/payload.app/Contents/Resources/pair-only',
          ).readAsString(),
          'preserve unknown app resource',
        );
        expect(await Directory('${backups.path}/before').exists(), false);
        await assertOwnership();
      },
    );
    for (final phase in ['partial', 'final']) {
      test('$phase late unknown source-state changes refuse pairing', () async {
        var changed = false;
        final root =
            '${backups.path}/${phase == 'partial' ? '.before.partial' : 'before'}';
        coldHost.onStatus = () async {
          if (!changed && await File('$root/receipt.json').exists()) {
            changed = true;
            await File(
              '${state.path}/unknown-data',
            ).writeAsString('source changed after state copy');
          }
        };
        await expectLater(
          snapshot().then((_) => true),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(changed, true);
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'source changed after state copy',
        );
        expect(
          await File('$root/state/payload/unknown-data').readAsString(),
          'preserve state',
        );
        expect(
          await Directory('${backups.path}/before').exists(),
          phase == 'final',
        );
        await assertOwnership();
      });
    }
    test(
      'a post-publication cold failure retains final but is not success',
      () async {
        coldHost.onStatus = () async {
          if (await File('${backups.path}/before/receipt.json').exists())
            coldHost.registered = true;
        };
        await expectLater(
          snapshot().then((_) => true),
          throwsA(
            isA<MaintenanceSnapshotFailure>().having(
              (e) => e.cause,
              'cause',
              isA<ColdStateFailure>(),
            ),
          ),
        );
        expect(await Directory('${backups.path}/before').exists(), true);
        expect(
          await File(
            '${backups.path}/before/state/payload/unknown-data',
          ).readAsString(),
          'preserve state',
        );
        coldHost.onStatus = null;
        coldHost.registered = false;
        await assertOwnership();
      },
    );
    test(
      'last native callback cannot hide an unknown source-state change',
      () async {
        var observations = 0;
        final observer = MacOsOpenReferences(
          command: (_, arguments) async {
            if (arguments.last == app.path &&
                await File('${backups.path}/before/receipt.json').exists()) {
              observations++;
              if (observations == 2) {
                await File(
                  '${state.path}/unknown-data',
                ).writeAsString('changed in final native callback');
              }
            }
            return ProcessResult(pid, 1, '', '');
          },
        );
        await expectLater(
          snapshot(observer: observer).then((_) => true),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(observations, 2);
        expect(
          await File('${state.path}/unknown-data').readAsString(),
          'changed in final native callback',
        );
        expect(
          await File(
            '${backups.path}/before/state/payload/unknown-data',
          ).readAsString(),
          'preserve state',
        );
        await assertOwnership();
      },
    );
    test(
      'a real native app holder blocks pairing until its owned exit',
      () async {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '${Directory.current.path}/test/fixtures/hold_maintenance_file.dart',
          '${app.path}/Contents/Resources/pair-only',
        ]);
        final ready = Completer<void>();
        final output = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) {
              if (line == 'held' && !ready.isCompleted) ready.complete();
              return line;
            })
            .join('\n');
        final child = OwnedTestProcess(process, stdoutCapture: output);
        children.add(child);
        await ready.future.timeout(const Duration(seconds: 10));
        final observer = MacOsOpenReferences(command: command);
        await expectLater(
          snapshot(observer: observer).then((_) => true),
          throwsA(
            isA<ColdStateFailure>().having(
              (e) => e.stage,
              'stage',
              'app_references',
            ),
          ),
        );
        expect(
          await Directory('${backups.path}/.before.partial').exists(),
          false,
        );
        await process.stdin.close();
        expect((await child.result()).exitCode, 0);
        expect(child.exitConfirmed, true);
        expect(await observer.directory(app), isNot(contains(child.pid)));
        await assertOwnership();
      },
    );
  }, skip: !Platform.isMacOS);
}

final class _ValidationDoctorHost implements DoctorHost {
  _ValidationDoctorHost(this.onPlatform);
  final Future<void> Function() onPlatform;
  @override
  Future<DoctorPlatformObservation> inspectPlatform() async {
    await onPlatform();
    return (macOS: true, appleSilicon: true, majorVersion: 14);
  }

  @override
  Future<DoctorDriverObservation> inspectDriver() async => (
    executable: true,
    arm64: true,
    validSignature: true,
    virtualizationEntitlement: true,
    signatureMessage: 'fixture native boundary',
  );
  @override
  Future<HostMetrics> sampleResources() async => const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 16 * 1024 * 1024 * 1024,
    availableMemoryBytes: 10 * 1024 * 1024 * 1024,
    freeDiskBytes: 100 * 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
  @override
  Future<DriverInventorySnapshot> inventory() async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
}

final class _SnapshotHost implements ColdStateHost {
  _SnapshotHost(this.appPath);
  @override
  final String appPath;
  bool registered = false;
  Future<void> Function()? onStatus;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async {
    await onStatus?.call();
    return ProcessResult(
      pid,
      0,
      jsonEncode({
        'action': 'status',
        'bundle_identifier': 'org.gaovm.tests.Release',
        'plist_name': 'gaovmd.plist',
        'authorization_state': registered ? 'enabled' : 'notRegistered',
        'native_status': 0,
        'outcome': 'observed',
        'error_code': null,
      }),
      '',
    );
  }
}

final class _RealNativeBoundary implements ReleaseInspectionHost {
  bool retainInputs = false, executedCandidate = false;
  String? rejectedSignature;
  final _native = const MacOsReleaseInspectionHost();
  @override
  bool get canExecuteArm64 => _native.canExecuteArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) async {
    if (arguments.contains('--component-info')) executedCandidate = true;
    try {
      final result = await _native.run(executable, arguments, input: input);
      if (executable == '/usr/bin/codesign' && result.exitCode != 0)
        rejectedSignature = result.stderr as String;
      return result;
    } on MaintenanceCommandFailure catch (error) {
      if (!error.exitConfirmed) retainInputs = true;
      rethrow;
    }
  }
}

// Only the native Security/plutil/execution boundary is replaced. These header
// fixtures are never executed or presented as signed GaoVM product binaries.
final class _NativeBoundary implements ReleaseInspectionHost {
  int statusCalls = 0;
  int admissions = 0;
  bool realAdmission = false, retainInputs = false;
  final executedRoles = <String>[];
  final _verified = <String>{};
  final componentChanges = <String, Map<String, Object?>>{};
  final extraEntitlements = <String, Object?>{};
  bool rejectSignature = false, nativeArm64 = true, runtimeFlag = true;
  String metadataTeam = 'ABCDEFGHIJ';
  Future<void> Function()? onProbe, onStatus;
  Future<ProcessResult?> Function(String, List<String>)? onAdmission;
  @override
  bool get canExecuteArm64 => nativeArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) async {
    String output = '', error = '';
    int verifiedFor(String executable) {
      final root = executable.split('/Contents/').first;
      return _verified
          .where((path) => path == root || path.startsWith('$root/Contents/'))
          .length;
    }

    if (executable == '/usr/bin/plutil') {
      output = input == null
          ? await File(arguments.last).readAsString()
          : utf8.decode(input);
    } else if (executable == '/usr/bin/lipo') {
      output = 'arm64\n';
    } else if (executable == '/usr/bin/codesign') {
      final path = arguments.last;
      final suffix = path.endsWith('.app') || path.endsWith('/gaovmd')
          ? ''
          : path.endsWith('/gaovm')
          ? '.cli'
          : path.endsWith('/gaovm-service')
          ? '.service'
          : '.driver';
      final identifier = 'org.gaovm.tests.Release$suffix';
      if (arguments.contains('--verify')) {
        expect(arguments, contains('--strict'));
        final requirement =
            arguments[arguments.indexOf('--test-requirement') + 1];
        expect(requirement, contains('identifier "$identifier"'));
        expect(requirement, contains('anchor apple generic'));
        expect(
          requirement,
          contains('certificate leaf[subject.OU] = "ABCDEFGHIJ"'),
        );
        expect(
          requirement,
          contains('certificate 1[field.1.2.840.113635.100.6.2.6] exists'),
        );
        expect(
          requirement,
          contains('certificate leaf[field.1.2.840.113635.100.6.1.13] exists'),
        );
        if (rejectSignature)
          return ProcessResult(
            1,
            3,
            '',
            'code failed to satisfy specified code requirement(s)',
          );
        _verified.add(path);
      } else if (arguments.contains('--entitlements')) {
        output = jsonEncode({
          ...(suffix == '.service'
              ? <String, Object?>{}
              : suffix == '.driver'
              ? {'com.apple.security.virtualization': true}
              : {
                  'com.apple.security.cs.allow-unsigned-executable-memory':
                      true,
                }),
          ...extraEntitlements,
        });
      } else {
        error =
            'Identifier=$identifier\nTeamIdentifier=$metadataTeam\nCodeDirectory v=20500 flags=${runtimeFlag ? '0x10000(runtime)' : '0x0(none)'}\n';
      }
    } else if (arguments.length == 1 && arguments.single == 'status') {
      expect(executable, endsWith('/Contents/MacOS/gaovm-service'));
      expect(verifiedFor(executable), 5);
      statusCalls++;
      await onStatus?.call();
      output = jsonEncode({
        'action': 'status',
        'bundle_identifier': 'org.gaovm.tests.Release',
        'plist_name': 'gaovmd.plist',
        'authorization_state': 'notRegistered',
        'native_status': 0,
        'outcome': 'observed',
        'error_code': null,
      });
    } else if (arguments.contains('--state-dir')) {
      expect(executable, endsWith('/Contents/MacOS/gaovmd'));
      expect(verifiedFor(executable), 5);
      admissions++;
      final overridden = await onAdmission?.call(executable, arguments);
      if (overridden != null) return overridden;
      if (realAdmission) {
        try {
          return await runMaintenanceCommand(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovmd.dart',
            ...arguments,
          ], timeout: const Duration(seconds: 30));
        } on MaintenanceCommandFailure catch (failure) {
          if (!failure.exitConfirmed) retainInputs = true;
          rethrow;
        }
      }
      final state = arguments[arguments.indexOf('--state-dir') + 1];
      final parent = Directory(state).parent.path;
      final marker =
          '$parent/.gaovmd-maintenance-${sha256.convert(utf8.encode(state))}';
      return ProcessResult(
        pid,
        1,
        '',
        'gaovmd startup failed: maintenance recovery required for $state; retained fence: $marker\n',
      );
    } else {
      expect(arguments, ['--component-info']);
      expect(
        verifiedFor(executable),
        5,
        reason: 'all code is verified before any candidate code executes',
      );
      final name = File(executable).uri.pathSegments.last;
      final role = switch (name) {
        'gaovmd' => ComponentRole.daemon,
        'gaovm' => ComponentRole.cli,
        'gaovm-driver-vz' => ComponentRole.driver,
        'gaovm-service' => ComponentRole.service,
        _ => throw StateError('unexpected native execution'),
      };
      executedRoles.add(role == ComponentRole.driver ? 'driver-vz' : role.name);
      await onProbe?.call();
      final daemon = daemonComponentInfo();
      output = jsonEncode(switch (role) {
        ComponentRole.daemon => daemon.toJson(),
        ComponentRole.cli => ComponentInfo(
          role: role,
          version: '0.1.0',
          publicApi: 'v1',
          vmSpec: vmApiVersion,
        ).toJson(),
        ComponentRole.driver => ComponentInfo(
          role: role,
          version: '0.1.0',
          driverProtocol: daemon.driverProtocol,
          offered: daemon.offered.where((cap) => cap != 'guest.status'),
          requiredCapabilities: daemon.requiredCapabilities,
          developmentOnly: ['guest.status'],
        ).toJson(),
        ComponentRole.service => ComponentInfo(
          role: role,
          version: '0.1.0',
          serviceActions: ['register', 'status', 'unregister'],
        ).toJson(),
      });
      final change = componentChanges[role.name];
      if (change != null)
        output = jsonEncode({
          ...jsonDecode(output) as Map<String, Object?>,
          ...change,
        });
    }
    return ProcessResult(1, 0, output, error);
  }
}

Future<void> _fixture(Directory app) async {
  Future<void> write(
    String relative,
    List<int> bytes, {
    bool executable = false,
  }) async {
    final file = File('${app.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    imageFileMode(file.path, executable ? 0x1ed : 0x1a4);
  }

  final header = ByteData(64)
    ..setUint32(0, 0xfeedfacf, Endian.little)
    ..setUint32(4, 0x0100000c, Endian.little)
    ..setUint32(12, 2, Endian.little);
  for (final path in [
    'MacOS/gaovmd',
    'MacOS/gaovm',
    'Helpers/gaovm-driver-vz',
    'MacOS/gaovm-service',
  ]) {
    await write(
      'Contents/$path',
      header.buffer.asUint8List(),
      executable: true,
    );
  }
  await write(
    'Contents/Info.plist',
    utf8.encode(
      jsonEncode({
        'CFBundleIdentifier': 'org.gaovm.tests.Release',
        'CFBundleName': 'GaoVM',
        'CFBundleDisplayName': 'GaoVM',
        'CFBundleExecutable': 'gaovmd',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.1.0',
        'CFBundleVersion': '0.1.0',
        'LSMinimumSystemVersion': '14.0',
        'LSBackgroundOnly': true,
      }),
    ),
  );
  await write(
    'Contents/Library/LaunchAgents/gaovmd.plist',
    utf8.encode(
      jsonEncode({
        'Label': 'org.gaovm.tests.Release.gaovmd',
        'BundleProgram': 'Contents/MacOS/gaovmd',
        'ProgramArguments': ['gaovmd'],
        'KeepAlive': true,
        'Umask': 63,
        'AbandonProcessGroup': true,
      }),
    ),
  );
  for (final path in [
    'openapi/gaovm-v1.yaml',
    'vm-spec/v1alpha1.schema.json',
    'driver-protocol/v2.schema.json',
  ]) {
    await write(
      'Contents/Resources/schemas/$path',
      await File('../../schemas/$path').readAsBytes(),
    );
  }
  await write(
    'Contents/Resources/dart-runtime-entitlements.plist',
    utf8.encode(
      jsonEncode({
        'com.apple.security.cs.allow-unsigned-executable-memory': true,
      }),
    ),
  );
  await write(
    'Contents/Resources/driver-entitlements.plist',
    utf8.encode(jsonEncode({'com.apple.security.virtualization': true})),
  );
}
