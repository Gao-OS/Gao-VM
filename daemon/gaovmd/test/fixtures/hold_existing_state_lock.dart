import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';

// Test-only kernel-lock contender, not ordinary daemon admission. Never creates
// a state or ownership file, changes a marker, or executes a runtime/service.
Future<void> main(List<String> arguments) async {
  final root = await OwnedImageDirectory.open(Directory(arguments.single));
  OwnedImageLock? owner;
  try {
    owner = await root.tryAcquireMaintenanceLock('.gaovmd.lock', create: false);
    if (owner == null) {
      stdout.writeln('busy');
      exitCode = 3;
      return;
    }
    stdout.writeln('owned');
    await stdin.drain<void>();
  } finally {
    owner?.close();
    root.close();
  }
}
