import 'dart:io';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';

Future<void> main(List<String> args) async {
  final root = await OwnedImageDirectory.open(Directory(args.single));
  final owner = await DaemonOwnership.tryAcquire(root);
  if (owner == null) {
    stdout.writeln('busy');
    root.close();
    exitCode = 3;
    return;
  }
  stdout.writeln('owned');
  await stdin.drain<void>();
  owner.close();
  root.close();
}
