import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  final directory = await OwnedImageDirectory.open(Directory(args[0]));
  final database = await GaoVmDatabase.open(args[1]);
  try {
    await ArtifactApplicationService(
      database: database,
      directory: directory,
      onCheckpoint: (checkpoint, id) {
        if (checkpoint.name != args[4]) return;
        File(
          '${Directory(args[0]).parent.path}/crash-${checkpoint.name}.json',
        ).writeAsStringSync(jsonEncode({'artifact_id': id.value}), flush: true);
        exit(73);
      },
    ).publish(
      bytes: Stream.fromIterable([
        [1, 2],
        [3],
      ]),
      kind: ArtifactKind.stdout,
      contentType: 'application/octet-stream',
      maxBytes: 16,
      testRunId: TestRunId(args[2]),
      operationId: OperationId(args[3]),
    );
    exitCode = 74;
  } finally {
    directory.close();
    database.close();
  }
}
