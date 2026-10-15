import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_component_info.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_release_inspection.dart';
import 'package:gaovmd/src/macos_cold_state_host.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/macos_cold_publication.dart';
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
