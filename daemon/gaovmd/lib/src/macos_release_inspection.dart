import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'component_executable_probe.dart';
import 'driver_protocol_v2.dart';
import 'image_filesystem.dart';
import 'maintenance_command.dart';
import 'maintenance_tree.dart';
import 'public_openapi_document.dart';
import 'release_compatibility.dart';

abstract interface class ReleaseInspectionHost {
  bool get canExecuteArm64;

  /// Return only after the owned child exits. An unconfirmed native failure
  /// carries MaintenanceCommandFailure.ownedExit for callers retaining inputs.
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  });
}

final class MacOsReleaseInspectionHost implements ReleaseInspectionHost {
  const MacOsReleaseInspectionHost();
  @override
  bool get canExecuteArm64 =>
      Platform.isMacOS && Abi.current() == Abi.macosArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) {
    if (!Platform.isMacOS)
      throw UnsupportedError('macOS release inspection required');
    return runMaintenanceCommand(executable, arguments, input: input);
  }
}

final class ReleaseInspectionFailure implements Exception {
  const ReleaseInspectionFailure(this.stage, this.status, this.reason);
  final String stage;
  final String status;
  final String reason;
  @override
  String toString() => '$status release ($stage): $reason';
}

const _paths = {
  ComponentRole.daemon: 'Contents/MacOS/gaovmd',
  ComponentRole.cli: 'Contents/MacOS/gaovm',
  ComponentRole.driver: 'Contents/Helpers/gaovm-driver-vz',
  ComponentRole.service: 'Contents/MacOS/gaovm-service',
};
const _dartEntitlements = {
  'com.apple.security.cs.allow-unsigned-executable-memory': true,
};
const _driverEntitlements = {'com.apple.security.virtualization': true};

Future<Map<String, Object?>> inspectMacOsRelease(
  Directory app, {
  required String bundleIdentifier,
  required String version,
  required String teamIdentifier,
  required int catalogSchema,
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
}) async {
  var stage = 'inputs';
  MaintenanceTree? tree;
  try {
    if (!app.path.endsWith('.app') ||
        bundleIdentifier.length > 255 ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$',
        ).hasMatch(bundleIdentifier) ||
        !RegExp(r'^[A-Z0-9]{10}$').hasMatch(teamIdentifier) ||
        version.length > 32 ||
        !RegExp(
          r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
        ).hasMatch(version) ||
        catalogSchema < 0 ||
        catalogSchema > 2147483647) {
      throw const FormatException(
        'explicit app, bundle ID, X.Y.Z version, Team ID and catalog schema are required',
      );
    }
    tree = await MaintenanceTree.open(app);
    final root = tree.path;
    final manifest = await tree.capture();
    for (final path in [
      ..._paths.values,
      'Contents/Info.plist',
      'Contents/Library/LaunchAgents/gaovmd.plist',
      'Contents/Resources/dart-runtime-entitlements.plist',
      'Contents/Resources/driver-entitlements.plist',
      'Contents/Resources/schemas/openapi/gaovm-v1.yaml',
      'Contents/Resources/schemas/vm-spec/v1alpha1.schema.json',
      'Contents/Resources/schemas/driver-protocol/v2.schema.json',
    ]) {
      if ((manifest[path] as Map?)?['kind'] != 'file') {
        throw FormatException(
          'required regular release file is missing: $path',
        );
      }
      final size = (manifest[path] as Map)['size'] as int;
      if (path.endsWith('.plist') && size > 65536 ||
          path.contains('/schemas/') && size > 1024 * 1024) {
        throw const FormatException(
          'release plist/schema evidence exceeds its byte bound',
        );
      }
    }
    Future<ProcessResult> run(
      String executable,
      List<String> args, {
      List<int>? input,
    }) async {
      final result = await host.run(executable, args, input: input);
      if (result.exitCode != 0) {
        throw FormatException(
          'native ${File(executable).uri.pathSegments.last} check failed',
        );
      }
      return result;
    }

    Future<Map<String, Object?>> plist(String path, {List<int>? input}) async {
      final result = await run('/usr/bin/plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        input == null ? path : '-',
      ], input: input);
      final value = jsonDecode(result.stdout as String);
      if (value is! Map<String, Object?>)
        throw const FormatException('release plist must be a dictionary');
      return value;
    }

    Future<void> signature(
      String path,
      String identifier, {
      bool nested = false,
    }) async {
      // Apple-issued Developer ID Application, not a self-signed/ad-hoc identity.
      final requirement =
          '=anchor apple generic and identifier "$identifier" '
          'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
          'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
          'and certificate leaf[subject.OU] = "$teamIdentifier"';
      await run('/usr/bin/codesign', [
        '--verify',
        if (nested) '--deep',
        '--strict',
        '--test-requirement',
        requirement,
        path,
      ]);
    }

    stage = 'signature';
    await signature(root, bundleIdentifier, nested: true);
    for (final entry in _paths.entries) {
      final role = entry.key, relative = entry.value;
      final path = '$root/$relative';
      final suffix = role == ComponentRole.daemon
          ? ''
          : role == ComponentRole.driver
          ? '.driver'
          : '.${role.name}';
      final identifier = '$bundleIdentifier$suffix';
      await signature(path, identifier);
      final file = await OwnedImageFile.open(File(path));
      try {
        if (file.size < 32) {
          throw const FormatException(
            'release component must be a thin executable ARM64 Mach-O',
          );
        }
        final first = await file.openRead().first;
        final header = ByteData.sublistView(Uint8List.fromList(first));
        if (file.mode & 0x40 == 0 ||
            header.lengthInBytes < 32 ||
            header.getUint32(0, Endian.little) != 0xfeedfacf ||
            header.getUint32(4, Endian.little) != 0x0100000c ||
            header.getUint32(12, Endian.little) != 2) {
          throw const FormatException(
            'release component must be a thin executable ARM64 Mach-O',
          );
        }
        await file.verifyPathBinding();
      } finally {
        file.close();
      }
      final architectures = await run('/usr/bin/lipo', ['-archs', path]);
      if ((architectures.stdout as String).trim() != 'arm64') {
        throw const FormatException(
          'release component must contain only ARM64',
        );
      }
      final signing = await run('/usr/bin/codesign', [
        '--display',
        '--verbose=4',
        path,
      ]);
      final metadata = signing.stderr as String;
      String field(String key) {
        final matches = RegExp(
          '^$key=(.*)\$',
          multiLine: true,
        ).allMatches(metadata).toList();
        if (matches.length != 1)
          throw const FormatException('missing or ambiguous signing metadata');
        return matches.single.group(1)!;
      }

      final flags = RegExp(
        r'\bflags=0x([0-9a-fA-F]+)\(',
      ).allMatches(metadata).toList();
      if (field('Identifier') != identifier ||
          field('TeamIdentifier') != teamIdentifier ||
          flags.length != 1 ||
          int.parse(flags.single.group(1)!, radix: 16) & 0x10000 == 0) {
        throw const FormatException(
          'release signature identity or hardened runtime does not match',
        );
      }
      final entitlements = await run('/usr/bin/codesign', [
        '--display',
        '--entitlements',
        ':-',
        path,
      ]);
      final bytes = utf8.encode(entitlements.stdout as String);
      final actual = bytes.isEmpty
          ? <String, Object?>{}
          : await plist('-', input: bytes);
      _same(
        actual,
        role == ComponentRole.driver
            ? _driverEntitlements
            : role == ComponentRole.service
            ? const {}
            : _dartEntitlements,
        'signed entitlements',
      );
    }
    stage = 'bundle';
    _same(await plist('$root/Contents/Info.plist'), {
      'CFBundleIdentifier': bundleIdentifier,
      'CFBundleName': 'GaoVM',
      'CFBundleDisplayName': 'GaoVM',
      'CFBundleExecutable': 'gaovmd',
      'CFBundlePackageType': 'APPL',
      'CFBundleShortVersionString': version,
      'CFBundleVersion': version,
      'LSMinimumSystemVersion': '14.0',
      'LSBackgroundOnly': true,
    }, 'bundle metadata');
    _same(
      await plist('$root/Contents/Library/LaunchAgents/gaovmd.plist'),
      {
        'Label': '$bundleIdentifier.gaovmd',
        'BundleProgram': 'Contents/MacOS/gaovmd',
        'ProgramArguments': ['gaovmd'],
        'KeepAlive': true,
        'Umask': 63,
        'AbandonProcessGroup': true,
      },
      'owning service configuration',
    );
    _same(
      await plist('$root/Contents/Resources/dart-runtime-entitlements.plist'),
      _dartEntitlements,
      'Dart entitlement resource',
    );
    _same(
      await plist('$root/Contents/Resources/driver-entitlements.plist'),
      _driverEntitlements,
      'driver entitlement resource',
    );
    stage = 'schemas';
    final schemas = '$root/Contents/Resources/schemas';
    final public = await loadPublicOpenApiDocument(
      File('$schemas/openapi/gaovm-v1.yaml'),
    );
    Future<Object?> readSchema(String path) async {
      final file = await OwnedImageFile.open(File(path));
      try {
        final value = jsonDecode(
          utf8.decode(await file.readBounded(1024 * 1024)),
        );
        await file.verifyPathBinding();
        return value;
      } finally {
        file.close();
      }
    }

    final spec = await readSchema('$schemas/vm-spec/v1alpha1.schema.json');
    final driverSchema = await readSchema(
      '$schemas/driver-protocol/v2.schema.json',
    );
    if (!RegExp(
          r'^1\.[0-9]+\.[0-9]+$',
        ).hasMatch('${_at(public, ['info', 'version'])}') ||
        _at(spec, ['properties', 'api_version', 'const']) != vmApiVersion ||
        _at(driverSchema, [
              r'$defs',
              'helloRequest',
              'properties',
              'params',
              'properties',
              'protocol_version',
              'const',
            ]) !=
            DriverProtocolV2.version ||
        _at(driverSchema, [
              r'$defs',
              'helloSuccessResponse',
              'properties',
              'result',
              'properties',
              'protocol_version',
              'const',
            ]) !=
            DriverProtocolV2.version) {
      throw const FormatException(
        'shipped public, VmSpec or driver schema version does not match',
      );
    }
    await tree.verify(manifest);
    stage = 'components';
    if (!host.canExecuteArm64) {
      throw const ReleaseInspectionFailure(
        'components',
        'unverified',
        'actual ARM64 probes require a native ARM64 macOS maintenance process',
      );
    }
    final components = <ComponentRole, ComponentInfo>{};
    final evidence = <String, Object?>{};
    for (final entry in _paths.entries) {
      final probe = await probeComponentExecutable(
        File('$root/${entry.value}'),
        expectedRole: entry.key,
        command: (path, arguments) => host.run(path, arguments),
      );
      if (probe.digest != (manifest[entry.value] as Map)['digest']) {
        throw const FormatException(
          'component bytes changed after signature inspection',
        );
      }
      components[entry.key] = probe.info;
      evidence[entry.key == ComponentRole.driver
          ? 'driver-vz'
          : entry.key.name] = {
        'relative_path': entry.value,
        'digest': probe.digest,
        'info': probe.info.toJson(),
      };
    }
    verifyReleaseCompatibility(
      components,
      version: version,
      catalogSchema: catalogSchema,
    );
    await tree.verify(manifest);
    return {
      'format': 'gaovm.release-inspection.v1',
      'app_path': root,
      'bundle_identifier': bundleIdentifier,
      'team_identifier': teamIdentifier,
      'version': version,
      'compatibility': 'compatible',
      'required_catalog_schema': catalogSchema,
      'applied_catalog_schema': null,
      'negotiated_runtime': 'unobserved',
      'components': evidence,
      'tree_digest':
          'sha256:${sha256.convert(utf8.encode(jsonEncode(manifest)))}',
      'tree': manifest,
    };
  } on FormatException catch (error) {
    throw ReleaseInspectionFailure(stage, 'incompatible', error.message);
  } on FileSystemException catch (error) {
    throw ReleaseInspectionFailure(stage, 'unverified', error.message);
  } on UnsupportedError catch (error) {
    throw ReleaseInspectionFailure(
      stage,
      'unverified',
      error.message.toString(),
    );
  } finally {
    tree?.close();
  }
}

void _same(
  Map<String, Object?> actual,
  Map<String, Object?> expected,
  String name,
) {
  if (actual.length != expected.length ||
      expected.entries.any(
        (entry) =>
            !actual.containsKey(entry.key) ||
            jsonEncode(actual[entry.key]) != jsonEncode(entry.value),
      )) {
    throw FormatException('$name does not match the release contract');
  }
}

Object? _at(Object? value, List<String> path) {
  for (final key in path) {
    if (value is! Map<String, Object?>) return null;
    value = value[key];
  }
  return value;
}
