import 'dart:io';

import 'package:gaovmd/src/image_application_service.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/sqlite_database.dart';

Future<void> main(List<String> args) async {
  final database = await GaoVmDatabase.open(args[0]);
  try {
    final store = ImageStore(
      database,
      Directory(args[1]),
      onCheckpoint: (point) {
        if (point.name == args[2]) exit(74);
      },
    );
    await ImageApplicationService(
      database: database,
      store: store,
    ).dispatchOnce();
    throw StateError('requested crash checkpoint was not reached');
  } finally {
    database.close();
  }
}
