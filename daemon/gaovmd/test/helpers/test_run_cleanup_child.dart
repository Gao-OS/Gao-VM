import 'dart:async';
import 'dart:io';

import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/test_run_cleanup_dispatch_loop.dart';
import 'package:gaovmd/src/test_run_cleanup_worker.dart';

Future<void> main(List<String> arguments) async {
  final database = await GaoVmDatabase.open('${arguments.single}/catalog.db');
  final completed = Completer<void>();
  final loop = TestRunCleanupDispatchLoop(
    worker: TestRunCleanupWorker(database: database),
    onDispatch: (pass) {
      if (pass.any((item) => item.completed) && !completed.isCompleted)
        completed.complete();
      for (final item in pass) {
        if (item.error != null && !completed.isCompleted)
          completed.completeError(item.error!);
      }
    },
    onError: completed.completeError,
  );
  try {
    loop.start();
    await completed.future.timeout(const Duration(seconds: 5));
    await loop.close();
    stdout.writeln('cleanup drained');
  } finally {
    await loop.close();
    database.close();
  }
}
