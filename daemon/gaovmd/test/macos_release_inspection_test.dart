import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/daemon_component_info.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/macos_release_inspection.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory app;
  late _NativeBoundary host;
  _RealNativeBoundary? realHost;
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
  });
  tearDown(() async {
    if (realHost?.retainInputs == true) {
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
  final executedRoles = <String>[];
  final _verified = <String>{};
  final componentChanges = <String, Map<String, Object?>>{};
  final extraEntitlements = <String, Object?>{};
  bool rejectSignature = false, nativeArm64 = true, runtimeFlag = true;
  String metadataTeam = 'ABCDEFGHIJ';
  Future<void> Function()? onProbe;
  @override
  bool get canExecuteArm64 => nativeArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) async {
    String output = '', error = '';
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
    } else {
      expect(arguments, ['--component-info']);
      expect(
        _verified.length,
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
