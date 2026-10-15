import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'maintenance_command.dart';

final class ComponentExecutableEvidence {
  const ComponentExecutableEvidence({
    required this.path,
    required this.digest,
    required this.info,
  });
  final String path;
  final String digest;
  final ComponentInfo info;
}

Future<ComponentExecutableEvidence> probeComponentExecutable(
  File executable, {
  required ComponentRole expectedRole,
  Future<ProcessResult> Function(String, List<String>) command =
      runMaintenanceCommand,
}) async {
  final path = executable.absolute.path;
  if (await executable.resolveSymbolicLinks() != path ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException(
      'component executable must be a canonical regular file',
    );
  }
  final parent = await OwnedImageDirectory.open(executable.parent);
  OwnedImageFile? binary;
  try {
    binary = parent.file(executable.uri.pathSegments.last);
    final before = binary.stat();
    if (parent.mode & 0x12 != 0 ||
        before.mode & 0x12 != 0 ||
        before.mode & 0x40 == 0 ||
        before.linkCount != 1 ||
        before.size == 0) {
      throw const FormatException(
        'component executable must be owned, executable and not writable by other users',
      );
    }
    final digest = 'sha256:${await sha256.bind(binary.openRead()).first}';
    await parent.verifyPathBinding();
    await binary.verifyPathBinding();
    final result = await command(path, ['--component-info']);
    await parent.verifyPathBinding();
    await binary.verifyPathBinding();
    if (binary.stat() != before ||
        'sha256:${await sha256.bind(binary.openRead()).first}' != digest) {
      throw const FormatException(
        'component executable changed during its probe',
      );
    }
    if (result.exitCode != 0 || (result.stderr as String).isNotEmpty) {
      throw const FormatException(
        'component executable probe failed or emitted diagnostics',
      );
    }
    final info = ComponentInfo.fromJson(jsonDecode(result.stdout as String));
    if (info.role != expectedRole) {
      throw const FormatException(
        'component executable returned the wrong role',
      );
    }
    return ComponentExecutableEvidence(path: path, digest: digest, info: info);
  } finally {
    binary?.close();
    parent.close();
  }
}
