import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/sqlite_database.dart';

Future<void> main(List<String> args) async {
  final database = await GaoVmDatabase.open(args[0]);
  final target = ImageImportCheckpoint.values.byName(args[3]);
  final store = ImageStore(
    database,
    Directory(args[1]),
    onCheckpoint: (point) {
      if (point == target) exit(91);
    },
  );
  await store.importFile(File(args[2]), type: ImageType.rawDisk);
  database.close();
}
