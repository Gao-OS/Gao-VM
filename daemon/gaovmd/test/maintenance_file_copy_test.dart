import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File source;
  late OwnedImageDirectory destination;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp('gvm-metadata-copy-');
    temporary = Directory(await created.resolveSymbolicLinks());
    imageFileMode(temporary.path, 0x1c0);
    source = await File('${temporary.path}/source').writeAsBytes([0, 1, 255]);
    imageFileMode(source.path, 0x1c0);
    final folder = await Directory('${temporary.path}/backup').create();
    imageFileMode(folder.path, 0x1c0);
    destination = await OwnedImageDirectory.open(folder);
  });
  tearDown(() async {
    destination.close();
    await temporary.delete(recursive: true);
  });

  test(
    'native maintenance copy preserves complete bytes, mode, xattrs and ACL',
    () async {
      Future<ProcessResult> command(
        String executable,
        List<String> args,
      ) async {
        final result = await runMaintenanceCommand(executable, args);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result;
      }

      final uid = (await command('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      await command('/usr/bin/xattr', [
        '-wx',
        'org.gaovm.fixture',
        '0001ff',
        source.path,
      ]);
      await command('/bin/chmod', ['+a', 'user:$uid allow read', source.path]);
      final acl = (await command('/bin/ls', [
        '-lde',
        source.path,
      ])).stdout.toString().split('\n').skip(1).toList();
      final held = await OwnedImageFile.open(source);
      try {
        await held.openRead().drain<void>();
        await held.copyForMaintenance(destination, 'saved');
      } finally {
        held.close();
      }
      final saved = File('${destination.path}/saved');
      expect(await saved.readAsBytes(), [0, 1, 255]);
      expect((await saved.stat()).mode & 0xfff, 0x1c0);
      expect(
        (await command('/usr/bin/xattr', [
          '-px',
          'org.gaovm.fixture',
          saved.path,
        ])).stdout.toString().replaceAll(RegExp(r'\s'), '').toLowerCase(),
        '0001ff',
      );
      expect(
        (await command('/bin/ls', [
          '-lde',
          saved.path,
        ])).stdout.toString().split('\n').skip(1).toList(),
        acl,
      );
      expect(await source.readAsBytes(), [0, 1, 255]);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'metadata evidence binds xattrs and distinguishes an otherwise identical copy',
    () async {
      final held = await OwnedImageFile.open(source);
      try {
        final before = await held.maintenanceMetadata();
        await held.copyForMaintenance(destination, 'saved');
        final copied = destination.file('saved');
        try {
          expect(await copied.maintenanceMetadata(), before);
          final result = await runMaintenanceCommand('/usr/bin/xattr', [
            '-wx',
            'org.gaovm.late',
            '00ff',
            copied.path,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          expect(await copied.maintenanceMetadata(), isNot(before));
          expect(await held.maintenanceMetadata(), before);
        } finally {
          copied.close();
        }
      } finally {
        held.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'native copies retain resource forks larger than one metadata chunk',
    () async {
      final bytes = List<int>.generate(160 * 1024, (index) => index % 251);
      await File('${source.path}/..namedfork/rsrc').writeAsBytes(bytes);
      final held = await OwnedImageFile.open(source);
      try {
        final before = await held.maintenanceMetadata();
        final attributes = before['xattrs'] as Map;
        expect(attributes['com.apple.ResourceFork'], {
          'size': bytes.length,
          'digest': 'sha256:${sha256.convert(bytes)}',
        });
        await held.copyForMaintenance(destination, 'with-fork');
        final saved = destination.file('with-fork');
        try {
          expect(await saved.maintenanceMetadata(), before);
          expect(
            await File('${saved.path}/..namedfork/rsrc').readAsBytes(),
            bytes,
          );
        } finally {
          saved.close();
        }
        expect(
          await File('${source.path}/..namedfork/rsrc').readAsBytes(),
          bytes,
        );
      } finally {
        held.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'an in-flight native copy owns its descriptors until completion',
    () async {
      final held = await OwnedImageFile.open(source);
      final copying = held.copyForMaintenance(destination, 'owned');
      held.close();
      destination.close();
      await copying;
      expect(await File('${destination.path}/owned').readAsBytes(), [
        0,
        1,
        255,
      ]);
      expect(await source.readAsBytes(), [0, 1, 255]);
    },
    skip: !Platform.isMacOS,
  );
}
