import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'image_filesystem.dart';

/// Read-only content binding for maintenance; never creates a lock or output.
final class MaintenanceTree {
  MaintenanceTree._(this._root);
  final OwnedImageDirectory _root;
  String get path => _root.path;

  static Future<MaintenanceTree> open(Directory directory) async {
    if (directory.path != directory.absolute.path ||
        directory.absolute.path != await directory.resolveSymbolicLinks() ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException(
        'maintenance tree must be a canonical directory',
      );
    }
    final root = await OwnedImageDirectory.open(directory);
    if (root.path != directory.path) {
      root.close();
      throw const FormatException('maintenance canonical path changed');
    }
    return MaintenanceTree._(root);
  }

  Future<Map<String, Object?>> capture() async {
    final result = <String, Object?>{};
    var count = 0;
    Future<void> visit(
      OwnedImageDirectory directory,
      String prefix,
      int depth,
    ) async {
      if (depth > 32 || ++count > 16384) {
        throw const FormatException(
          'maintenance tree exceeds traversal bounds',
        );
      }
      await directory.verifyPathBinding();
      if (directory.mode & 0xc12 != 0) {
        throw const FormatException(
          'maintenance directory is writable by other users',
        );
      }
      result[prefix] = Map<String, Object?>.unmodifiable({
        'kind': 'directory',
        'mode': directory.mode & 0xfff,
      });
      final entries = <FileSystemEntity>[];
      await for (final entry in Directory(
        directory.path,
      ).list(followLinks: false)) {
        if (entries.length + count >= 16384) {
          throw const FormatException(
            'maintenance tree exceeds traversal bounds',
          );
        }
        entries.add(entry);
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final name = entry.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          final child = directory.directory(name);
          try {
            await visit(child, relative, depth + 1);
          } finally {
            child.close();
          }
        } else if (type == FileSystemEntityType.file) {
          if (++count > 16384) {
            throw const FormatException(
              'maintenance tree exceeds traversal bounds',
            );
          }
          final source = directory.file(name);
          try {
            final before = source.stat();
            if (before.linkCount != 1 || before.mode & 0xc12 != 0) {
              throw const FormatException(
                'maintenance file has unsafe permissions or links',
              );
            }
            final digest =
                'sha256:${await sha256.bind(source.openRead()).first}';
            await source.verifyPathBinding();
            if (source.stat() != before) {
              throw const FormatException(
                'maintenance file changed during capture',
              );
            }
            result[relative] = Map<String, Object?>.unmodifiable({
              'kind': 'file',
              'mode': before.mode & 0xfff,
              'size': before.size,
              'digest': digest,
            });
          } finally {
            source.close();
          }
        } else {
          throw const FormatException(
            'maintenance tree contains a link or special file',
          );
        }
      }
      await directory.verifyPathBinding();
    }

    await visit(_root, '', 0);
    return Map.unmodifiable(result);
  }

  Future<void> verify(Map<String, Object?> expected) async {
    if (jsonEncode(await capture()) != jsonEncode(expected)) {
      throw const FormatException('maintenance tree changed after inspection');
    }
  }

  void close() => _root.close();
}
