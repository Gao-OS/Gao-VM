import 'dart:io';

import 'package:gaovmd/src/artifact_application_service.dart'
    show ArtifactApplicationService;
import 'package:gaovmd/src/image_filesystem.dart' show OwnedImageDirectory;
import 'package:gaovmd/src/sqlite_database.dart' show GaoVmDatabase;
import 'package:gaovmd/src/test_run_collection_worker.dart';

Future<void> main(List<String> args) async {
  final database = await GaoVmDatabase.open('${args[0]}/catalog.db');
  final bundles = await OwnedImageDirectory.open(Directory('${args[0]}/vms'));
  final artifacts = await OwnedImageDirectory.open(
    Directory('${args[0]}/artifacts'),
  );
  try {
    await TestRunCollectionWorker(
      database: database,
      bundles: bundles,
      artifacts: ArtifactApplicationService(
        database: database,
        directory: artifacts,
        onCheckpoint: (checkpoint, _) {
          if (checkpoint.name == args[1]) exit(73);
        },
      ),
    ).dispatchOnce();
    exitCode = 74;
  } finally {
    artifacts.close();
    bundles.close();
    database.close();
  }
}
