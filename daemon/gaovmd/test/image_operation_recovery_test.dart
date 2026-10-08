import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/image_application_service.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  for (final checkpoint in ImageImportCheckpoint.values) {
    test(
      'recovers the durable operation after process exit at ${checkpoint.name}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'gvm-image-recover-',
        );
        final databasePath = '${directory.path}/catalog.db';
        final database = await GaoVmDatabase.open(databasePath);
        Process? child;
        Future<int>? exited;
        Future<String>? errors;
        Future<String>? output;
        var exitConfirmed = false;
        try {
          final store = ImageStore(
            database,
            Directory('${directory.path}/images'),
          );
          final images = ImageApplicationService(
            database: database,
            store: store,
          );
          final source = await File(
            '${directory.path}/disk',
          ).writeAsString('disk');
          final body = {
            'source_path': source.path,
            'type': 'raw-disk',
            'architecture': 'arm64',
          };
          final accepted = await images.importImage(
            ImageImportCommand.fromJson(
              body,
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: utf8.encode(jsonEncode(body)),
            ),
          );
          child = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/crash_image_operation.dart',
            databasePath,
            store.directory.path,
            checkpoint.name,
          ]);
          exited = child.exitCode.then((code) {
            exitConfirmed = true;
            return code;
          });
          errors = utf8.decoder.bind(child.stderr).join();
          output = utf8.decoder.bind(child.stdout).join();
          await child.stdin.close();
          expect(
            await exited.timeout(const Duration(seconds: 30)),
            74,
            reason: await errors,
          );
          final operations = SqliteOperationRepository(database);
          final committed = checkpoint == ImageImportCheckpoint.committed;
          expect(
            (await operations.get(accepted.operationId))!.state,
            committed ? OperationState.succeeded : OperationState.running,
          );
          expect(await store.list(), hasLength(committed ? 1 : 0));
          await store.reconcile();
          final recovered = ImageApplicationService(
            database: database,
            store: store,
            now: () => DateTime.now().add(const Duration(minutes: 1)),
          );
          await recovered.dispatchOnce();
          final image = (await store.list()).single;
          final operation = (await operations.get(accepted.operationId))!;
          expect(operation.state, OperationState.succeeded);
          expect(operation.result!.toJson()['image_id'], image.id.value);
          expect(
            await (await store.objectFile(image.id, 'payload')).readAsString(),
            'disk',
          );
          final events = await SqliteEventRepository(
            database,
          ).list(operationId: accepted.operationId);
          expect(
            events.where((event) => event.type == 'image.imported'),
            hasLength(1),
          );
          expect(
            events.where((event) => event.type == 'operation.completed'),
            hasLength(1),
          );
        } finally {
          if (child != null && !exitConfirmed) {
            child.kill(ProcessSignal.sigkill);
            await exited!.timeout(const Duration(seconds: 5));
          }
          await errors;
          await output;
          database.close();
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }
}
