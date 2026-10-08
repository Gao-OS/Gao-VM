import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_application_service.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/image_work_dispatch_loop.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:test/test.dart';

void main() {
  test('close drains image publication and leaves no scheduled work', () async {
    final directory = await Directory.systemTemp.createTemp('gvm-image-loop-');
    final database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    final entered = Completer<void>();
    final release = Completer<void>();
    final service = ImageApplicationService(
      database: database,
      store: ImageStore(
        database,
        Directory('${directory.path}/images'),
        availableBytes: (_) async {
          entered.complete();
          await release.future;
          return 100 * 1024 * 1024;
        },
      ),
    );
    final source = await File('${directory.path}/disk').writeAsString('disk');
    final body = {
      'source_path': source.path,
      'type': 'raw-disk',
      'architecture': 'arm64',
    };
    final accepted = await service.importImage(
      ImageImportCommand.fromJson(
        body,
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: utf8.encode(jsonEncode(body)),
      ),
    );
    final scheduler = _Scheduler();
    final loop = ImageWorkDispatchLoop(
      images: service,
      scheduler: scheduler,
      onError: (error, _) => fail('$error'),
    );
    try {
      loop.start();
      await entered.future;
      loop.start();
      var closed = false;
      final closing = loop.close().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      release.complete();
      await closing;
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(scheduler.handles.where((handle) => !handle.cancelled), isEmpty);
      expect(loop.start, throwsStateError);
    } finally {
      if (!release.isCompleted) release.complete();
      await loop.close();
      database.close();
      await directory.delete(recursive: true);
    }
  });
}

final class _Scheduler implements VmTimerScheduler {
  final handles = <_Handle>[];
  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _Handle();
    handles.add(handle);
    return handle;
  }
}

final class _Handle implements VmTimerHandle {
  bool cancelled = false;
  @override
  bool get isActive => !cancelled;
  @override
  void cancel() => cancelled = true;
}
