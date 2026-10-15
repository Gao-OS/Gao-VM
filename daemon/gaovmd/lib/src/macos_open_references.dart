import 'dart:ffi';
import 'dart:io';

import 'image_filesystem.dart';
import 'maintenance_command.dart';

/// Same-user open references, not permission to signal any observed process.
/// Missing/partial native evidence is an error, never an empty observation.
final class MacOsOpenReferences {
  MacOsOpenReferences({
    Future<ProcessResult> Function(String, List<String>) command =
        runMaintenanceCommand,
  }) : _command = command;
  final Future<ProcessResult> Function(String, List<String>) _command;

  Future<Set<int>> directory(Directory directory) async {
    await _canonical(directory.path, FileSystemEntityType.directory);
    final root = await OwnedImageDirectory.open(directory);
    try {
      if (root.path != directory.path) {
        throw const FormatException('open-reference directory path changed');
      }
      await root.verifyPathBinding();
      final result = await _observe(['+D', root.path]);
      await root.verifyPathBinding();
      return result;
    } finally {
      root.close();
    }
  }

  Future<Set<int>> file(File file) async {
    await _canonical(file.path, FileSystemEntityType.file);
    final parent = await OwnedImageDirectory.open(file.parent);
    OwnedImageFile? held;
    try {
      if (parent.path != file.parent.path) {
        throw const FormatException('open-reference parent path changed');
      }
      held = parent.file(file.uri.pathSegments.last);
      final before = held.stat();
      final result = await _observe(['--', file.path]);
      await parent.verifyPathBinding();
      await held.verifyPathBinding();
      if (held.stat() != before) {
        throw const FormatException(
          'referenced file changed during inspection',
        );
      }
      return result;
    } finally {
      held?.close();
      parent.close();
    }
  }

  Future<Set<int>> _observe(List<String> selection) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('macOS open-reference inspection required');
    }
    final libc = DynamicLibrary.process();
    final uid = libc.lookupFunction<Uint32 Function(), int Function()>(
      'getuid',
    )();
    final effective = libc.lookupFunction<Uint32 Function(), int Function()>(
      'geteuid',
    )();
    if (uid != effective) {
      throw const FormatException('maintenance requires matching user IDs');
    }
    final result = await _command('/usr/sbin/lsof', [
      '-nP',
      '-a',
      '-u',
      '$uid',
      '-F0p',
      ...selection,
    ]);
    final output = result.stdout as String;
    if ((result.stderr as String).isNotEmpty || result.pid <= 0) {
      throw const FormatException('open-reference evidence is incomplete');
    }
    if (result.exitCode == 1 && output.isEmpty) return const <int>{};
    // With +D, unopened entries also yield 1 even when other entries match.
    // Native errors/warnings must still have empty stderr, and any returned
    // references remain occupied; a nonzero status never erases those PIDs.
    if ((result.exitCode != 0 && result.exitCode != 1) ||
        !output.endsWith('\x00\n')) {
      throw const FormatException('open-reference evidence is malformed');
    }
    final processes = <int>{};
    var hasFile = false;
    final fields = output.split('\x00');
    for (final field in fields.take(fields.length - 1)) {
      final value = field.startsWith('\n') ? field.substring(1) : field;
      if (RegExp(r'^p[1-9][0-9]{0,9}$').hasMatch(value)) {
        if (processes.isNotEmpty && !hasFile) {
          throw const FormatException('open-reference process is incomplete');
        }
        final observed = int.parse(value.substring(1));
        if (observed > 0x7fffffff) {
          throw const FormatException('open-reference PID is out of range');
        }
        processes.add(observed);
        hasFile = false;
      } else if (processes.isEmpty ||
          !RegExp(r'^f(?:[0-9]+|cwd|rtd|txt|mem)$').hasMatch(value)) {
        throw const FormatException('open-reference evidence is malformed');
      } else {
        hasFile = true;
      }
    }
    if (processes.isEmpty || !hasFile || fields.last != '\n') {
      throw const FormatException('open-reference evidence is malformed');
    }
    // The bounded runner confirms its own observer child exited before return.
    processes.remove(result.pid);
    return Set.unmodifiable(processes);
  }

  static Future<void> _canonical(String path, FileSystemEntityType type) async {
    if (!path.startsWith('/') ||
        await File(path).resolveSymbolicLinks() != path ||
        await FileSystemEntity.type(path, followLinks: false) != type) {
      throw const FormatException('open-reference target must be canonical');
    }
  }
}
