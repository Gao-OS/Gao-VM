import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/sqlite_database.dart';

Future<void> main(List<String> args) async {
  final database = await GaoVmDatabase.open(args[0]);
  try {
    stdout.writeln('ready');
    await stdout.flush();
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    final image = await ImageStore(
      database,
      Directory(args[1]),
    ).importFile(File(args[2]), type: ImageType.rawDisk);
    stdout.writeln(image.id.value);
  } finally {
    database.close();
  }
}
