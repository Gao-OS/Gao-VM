import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'image_filesystem.dart';
import 'public_openapi_document.dart';

/// Build-time packaging only; not imported by the installed daemon.
final class MacOsAppPackageBuilder {
  const MacOsAppPackageBuilder({
    required this.daemon,
    required this.cli,
    required this.driver,
    required this.schemas,
    required this.driverEntitlements,
    required this.outputDirectory,
    required this.bundleIdentifier,
    required this.version,
    required this.signingIdentity,
  });

  final File daemon;
  final File cli;
  final File driver;
  final Directory schemas;
  final File driverEntitlements;
  final Directory outputDirectory;
  final String bundleIdentifier;
  final String version;
  final String signingIdentity;

  Future<Directory> build() async {
    if (bundleIdentifier.length > 255 ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$',
        ).hasMatch(bundleIdentifier)) {
      throw const FormatException(
        'bundle identifier must use reverse-DNS labels',
      );
    }
    if (version.length > 32 ||
        !RegExp(
          r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
        ).hasMatch(version)) {
      throw const FormatException(
        'app version must be a numeric X.Y.Z version',
      );
    }
    if (signingIdentity.isEmpty ||
        signingIdentity.length > 256 ||
        RegExp(r'[\x00\r\n]').hasMatch(signingIdentity)) {
      throw const FormatException('an explicit signing identity is required');
    }
    if (!Platform.isMacOS) throw UnsupportedError('macOS packaging required');
    if (await FileSystemEntity.type(outputDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('package output must be a regular directory');
    }
    await _checkExecutable(daemon, 'daemon');
    await _checkExecutable(cli, 'CLI');
    await _checkExecutable(driver, 'driver');
    final root = await OwnedImageDirectory.open(outputDirectory);
    OwnedImageLock? lock;
    OwnedImageDirectory? staging;
    try {
      if (root.mode & 0x3f != 0) {
        throw const FormatException('package output directory must be private');
      }
      lock = await root.acquireLock('.gaovm-package.lock');
      await root.verifyPathBinding();
      if (await FileSystemEntity.type(
            '${root.path}/GaoVM.app',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('output app already exists', root.path);
      }
      final random = Random.secure();
      final token = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final stagingName = '.gaovm-package-$token.app';
      staging = root.createDirectory(stagingName);
      final contents = staging.createDirectory('Contents');
      try {
        final executables = contents.createDirectory('MacOS');
        final helpers = contents.createDirectory('Helpers');
        final resources = contents.createDirectory('Resources');
        try {
          await _copyFile(daemon, executables, 'gaovmd', executable: true);
          await _copyFile(cli, executables, 'gaovm', executable: true);
          await _copyFile(driver, helpers, 'gaovm-driver-vz', executable: true);
          final schemaTarget = resources.createDirectory('schemas');
          try {
            await _copySchemas(schemas, schemaTarget);
          } finally {
            schemaTarget.close();
          }
          await loadPublicOpenApiDocument(
            File('${resources.path}/schemas/openapi/gaovm-v1.yaml'),
          );
          await _copyFile(
            driverEntitlements,
            resources,
            'driver-entitlements.plist',
          );
          final entitlementPath = '${resources.path}/driver-entitlements.plist';
          final entitlements = jsonDecode(
            await _command('/usr/bin/plutil', [
              '-convert',
              'json',
              '-o',
              '-',
              entitlementPath,
            ]),
          );
          if (entitlements is! Map<String, dynamic> ||
              entitlements['com.apple.security.virtualization'] != true) {
            throw const FormatException(
              'driver entitlement must enable com.apple.security.virtualization',
            );
          }
          await _writeFile(
            contents,
            'Info.plist',
            utf8.encode(
              jsonEncode({
                'CFBundleIdentifier': bundleIdentifier,
                'CFBundleName': 'GaoVM',
                'CFBundleDisplayName': 'GaoVM',
                'CFBundleExecutable': 'gaovmd',
                'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': version,
                'CFBundleVersion': version,
                'LSMinimumSystemVersion': '14.0',
                'LSBackgroundOnly': true,
              }),
            ),
          );
          await _command('/usr/bin/plutil', [
            '-convert',
            'xml1',
            '${contents.path}/Info.plist',
          ]);
          // Sign code inside out. --deep is verification only, never signing.
          final signing = [
            '--force',
            '--sign',
            signingIdentity,
            '--options',
            'runtime',
            signingIdentity == '-' ? '--timestamp=none' : '--timestamp',
          ];
          final packagedDriver = '${helpers.path}/gaovm-driver-vz';
          await _command('/usr/bin/codesign', [
            ...signing,
            '--identifier',
            '$bundleIdentifier.driver',
            '--entitlements',
            entitlementPath,
            packagedDriver,
          ]);
          final embedded = await _command('/usr/bin/codesign', [
            '--display',
            '--entitlements',
            ':-',
            packagedDriver,
          ]);
          if (!RegExp(
            r'<key>com\.apple\.security\.virtualization</key>\s*<true\s*/>',
          ).hasMatch(embedded)) {
            throw const FormatException(
              'signed driver lacks virtualization entitlement',
            );
          }
          await _command('/usr/bin/codesign', [
            ...signing,
            '--identifier',
            '$bundleIdentifier.cli',
            '${executables.path}/gaovm',
          ]);
          await _command('/usr/bin/codesign', [...signing, staging.path]);
          for (final path in [
            '${executables.path}/gaovmd',
            '${executables.path}/gaovm',
            packagedDriver,
          ]) {
            await _checkExecutable(File(path), 'packaged binary');
            await _command('/usr/bin/codesign', ['--verify', '--strict', path]);
          }
          await _command('/usr/bin/codesign', [
            '--verify',
            '--deep',
            '--strict',
            staging.path,
          ]);
        } finally {
          executables.close();
          helpers.close();
          resources.close();
        }
      } finally {
        contents.close();
      }
      await _syncTree(staging);
      await staging.verifyPathBinding();
      await root.verifyPathBinding();
      await root.renameDirectoryNoReplace(stagingName, 'GaoVM.app');
      return Directory('${root.path}/GaoVM.app');
    } finally {
      // Failed private staging is deliberately retained, never recursively
      // removed through a possibly replaced path. Existing apps are untouched.
      staging?.close();
      lock?.close();
      root.close();
    }
  }
}

Future<void> _copyFile(
  File input,
  OwnedImageDirectory destination,
  String name, {
  bool executable = false,
}) async {
  if (await FileSystemEntity.type(input.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FormatException(
      'package input must be a regular file: ${input.path}',
    );
  }
  final source = await OwnedImageFile.open(input);
  try {
    final before = source.stat();
    final output = destination.createFile(name);
    RandomAccessFile? writer;
    try {
      writer = await output.openWrite();
      var copied = 0;
      await for (final chunk in source.openRead()) {
        copied += chunk.length;
        if (copied > before.size) {
          throw FileSystemException(
            'package input changed while copying',
            source.path,
          );
        }
        await writer.writeFrom(chunk);
      }
      final after = source.stat();
      if (copied != before.size ||
          after.size != before.size ||
          after.modifiedAt != before.modifiedAt) {
        throw FileSystemException(
          'package input changed while copying',
          source.path,
        );
      }
      await source.verifyPathBinding();
      await writer.flush();
    } finally {
      await writer?.close();
      output.close();
    }
    imageFileMode('${destination.path}/$name', executable ? 0x1ed : 0x1a4);
  } finally {
    source.close();
  }
}

Future<void> _writeFile(
  OwnedImageDirectory directory,
  String name,
  List<int> bytes,
) async {
  final output = directory.createFile(name);
  RandomAccessFile? writer;
  try {
    writer = await output.openWrite();
    await writer.writeFrom(bytes);
    await writer.flush();
  } finally {
    await writer?.close();
    output.close();
  }
}

Future<void> _copySchemas(
  Directory sourceDirectory,
  OwnedImageDirectory destination,
) async {
  var entries = 0;
  Future<void> copy(
    OwnedImageDirectory source,
    OwnedImageDirectory target,
    int depth,
  ) async {
    if (depth > 16) throw const FormatException('schema directory is too deep');
    await source.verifyPathBinding();
    await for (final entry in Directory(source.path).list(followLinks: false)) {
      if (++entries > 512)
        throw const FormatException('too many schema entries');
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final child = source.directory(name);
        final output = target.createDirectory(name);
        try {
          await copy(child, output, depth + 1);
        } finally {
          child.close();
          output.close();
        }
      } else if (type == FileSystemEntityType.file) {
        final file = source.file(name);
        try {
          if (file.size > 1024 * 1024) {
            throw const FormatException('schema file exceeds 1 MiB');
          }
          await _copyFile(File(file.path), target, name);
        } finally {
          file.close();
        }
      } else {
        throw const FormatException(
          'schema tree contains a link or special file',
        );
      }
    }
    await source.verifyPathBinding();
  }

  if (await FileSystemEntity.type(sourceDirectory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('schemas must be a regular directory');
  }
  final source = await OwnedImageDirectory.open(sourceDirectory);
  try {
    await copy(source, destination, 0);
  } finally {
    source.close();
  }
}

Future<void> _syncTree(OwnedImageDirectory directory) async {
  await directory.verifyPathBinding();
  await for (final entry in Directory(
    directory.path,
  ).list(followLinks: false)) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final child = directory.directory(name);
      try {
        await _syncTree(child);
      } finally {
        child.close();
      }
    } else if (type == FileSystemEntityType.file) {
      final file = directory.file(name);
      try {
        await file.sync();
      } finally {
        file.close();
      }
    } else {
      throw const FormatException(
        'generated app contains a link or special file',
      );
    }
  }
  await directory.sync();
}

Future<String> _command(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}

Future<void> _checkExecutable(File file, String role) async {
  const requirement = 'must be an arm64 Mach-O executable';
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FormatException('$role $requirement');
  }
  final source = await OwnedImageFile.open(file);
  try {
    if (source.size < 32 || source.mode & 0x40 == 0) {
      throw FormatException('$role $requirement');
    }
    final header = ByteData.sublistView(
      Uint8List.fromList(await source.openRead().first),
    );
    if (header.lengthInBytes < 32 ||
        header.getUint32(0, Endian.little) != 0xfeedfacf ||
        header.getUint32(4, Endian.little) != 0x0100000c ||
        header.getUint32(12, Endian.little) != 2) {
      throw FormatException('$role $requirement');
    }
    final architectures = await Process.run('/usr/bin/lipo', [
      '-archs',
      source.path,
    ]);
    if (architectures.exitCode != 0 ||
        (architectures.stdout as String).trim() != 'arm64') {
      throw FormatException('$role $requirement');
    }
    await source.verifyPathBinding();
  } finally {
    source.close();
  }
}
