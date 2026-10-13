import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/guest_bridge_client.dart';
import 'package:gaovmd/src/guest_exec_request.dart';
import 'package:gaovmd/src/guest_exec_application_service.dart';
import 'package:gaovmd/src/guest_exec_worker.dart';
import 'package:gaovmd/src/test_run_step_worker.dart';
import 'package:gaovmd/src/test_run_collection_worker.dart';
import 'package:gaovmd/src/test_run_step_dispatch_loop.dart';
import 'package:gaovmd/src/guest_exec_dispatch_loop.dart';
import 'package:gaovmd/src/guest_exec_repository.dart';
import 'package:gaovmd/src/host_guest_artifacts.dart';
import 'package:gaovmd/src/host_guest_session.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final rustFixture = Platform.environment['GAOVM_GUEST_FIXTURE'];
  test(
    'real Rust guest spills both outputs through durable Dart publication and public download',
    () async {
      final fixture = await _Fixture.create(
        rustFixture: rustFixture!,
        requestForRoot: (root) => GuestExecRequest.fromJson({
          'argv': [
            '/bin/sh',
            '-c',
            r'''printf executed >> "$MARKER"; printf '\000\377\200\012'; printf err >&2''',
          ],
          'cwd': root,
          'env': {'MARKER': '$root/executed'},
          'timeout_seconds': 10,
          'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 0},
        }),
      );
      addTearDown(fixture.close);
      final connection = await _connectRustGuest(fixture);
      final jobs = SqliteGuestExecRepository(fixture.database);
      final request = GuestExecRequest.fromJson(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!.request.toJson(),
      );
      await connection.execStart(
        operationId: fixture.operationId,
        request: request,
        deadline: _deadline(),
      );
      final committed = <ArtifactId>[];
      final service = fixture.service(
        onCheckpoint: (checkpoint, id) {
          if (checkpoint != ArtifactPublicationCheckpoint.committed) return;
          final observer = sqlite3.open(fixture.databasePath);
          try {
            expect(
              observer.select(
                'SELECT 1 FROM guest_artifact_mappings WHERE host_artifact_id = ?',
                [id.value],
              ),
              hasLength(1),
            );
            expect(
              observer.select(
                '''
                SELECT 1 FROM events e JOIN outbox o ON o.key = e.id
                WHERE e.type = 'artifact.created' AND e.resource_id = ?
                  AND e.operation_id = ? AND e.vm_id = ? AND o.topic = 'events'
              ''',
                [id.value, fixture.operationId.value, fixture.vmId.value],
              ),
              hasLength(1),
            );
            committed.add(id);
          } finally {
            observer.dispose();
          }
        },
      );
      late GuestExecArtifactReceipt receipt;
      final deadline = _deadline(const Duration(seconds: 15));
      while (true) {
        deadline.requireLive();
        try {
          receipt = await service.captureExecStatus(
            connection: connection,
            operationId: fixture.operationId,
            attemptId: fixture.attemptId,
            request: request,
            deadline: deadline,
          );
          break;
        } on GuestArtifactException catch (error) {
          if (error.code != GuestArtifactFailure.notTerminal) rethrow;
        }
      }
      final result = receipt.result.toJson();
      final stdout = await service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 64,
      );
      expect(stdout.acknowledged, isTrue);
      expect(committed, [stdout.artifact.id]);
      await _expectRustGrantRetired(
        fixture,
        connection,
        ArtifactId((result['stdout'] as Map)['artifact_id'] as String),
        'stdout',
      );
      expect(
        await service.readExecResult(fixture.operationId, fixture.attemptId),
        isNull,
      );
      final stderr = await service.receiveOutput(
        receipt,
        output: 'stderr',
        maxBytes: 64,
      );
      expect(stderr.acknowledged, isTrue);
      expect(committed, [stdout.artifact.id, stderr.artifact.id]);
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
      final publicResult = (await service.readExecResult(
        fixture.operationId,
        fixture.attemptId,
      ))!.toJson();
      expect(
        (publicResult['stdout'] as Map)['artifact_id'],
        stdout.artifact.id.value,
      );
      expect(
        (publicResult['stderr'] as Map)['artifact_id'],
        stderr.artifact.id.value,
      );
      await connection.close();
      await _httpDownload(
        fixture,
        service.artifacts,
        stdout.artifact,
        ArtifactId((result['stdout'] as Map)['artifact_id'] as String),
        [0, 255, 128, 10],
      );
      await _httpDownload(
        fixture,
        service.artifacts,
        stderr.artifact,
        ArtifactId((result['stderr'] as Map)['artifact_id'] as String),
        ascii.encode('err'),
      );
      expect(
        await File('${fixture.root.path}/executed').readAsString(),
        'executed',
      );
    },
    skip: rustFixture == null
        ? 'build the real Rust host-publication fixture and set GAOVM_GUEST_FIXTURE'
        : false,
  );
  test(
    'real Rust guest collection preserves full descriptors, raw chunks and an empty sibling',
    () async {
      final fixture = await _Fixture.create(rustFixture: rustFixture!);
      addTearDown(fixture.close);
      final body = List<int>.generate(20000, (index) => index % 256);
      await File('${fixture.root.path}/guest-source/data').writeAsBytes(body);
      await File('${fixture.root.path}/guest-source/empty').writeAsBytes([]);
      final connection = await _connectRustGuest(fixture);
      final service = fixture.service();
      final receipt = await service.captureCollection(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: JsonObjectValue.fromJson({
          'paths': [
            {'path': 'data', 'kind': 'vendor-data'},
            {'path': 'empty', 'kind': 'result'},
          ],
          'max_total_bytes': body.length,
          'follow_symlinks': false,
        }),
        deadline: _deadline(const Duration(seconds: 15)),
      );
      final descriptors = receipt.result.toJson()['artifacts'] as List;
      expect(descriptors, hasLength(2));
      final first = await service.receiveCollectionArtifact(
        receipt,
        index: 0,
        maxBytes: body.length,
      );
      expect(first.acknowledged, isTrue);
      expect(first.artifact.kind, ArtifactKind.file);
      expect(await service.readCollectionResult(fixture.operationId), isNull);
      final second = await service.receiveCollectionArtifact(
        receipt,
        index: 1,
        maxBytes: 0,
      );
      expect(second.acknowledged, isTrue);
      expect(second.artifact.sizeBytes, 0);
      final publicResult = (await service.readCollectionResult(
        fixture.operationId,
      ))!.toJson();
      expect((publicResult['artifacts'] as List).map((a) => (a as Map)['id']), [
        first.artifact.id.value,
        second.artifact.id.value,
      ]);
      await connection.close();
      await _httpDownload(
        fixture,
        service.artifacts,
        first.artifact,
        ArtifactId((descriptors[0] as Map)['artifact_id'] as String),
        body,
      );
      await _httpDownload(
        fixture,
        service.artifacts,
        second.artifact,
        ArtifactId((descriptors[1] as Map)['artifact_id'] as String),
        [],
      );
      final serialized = jsonEncode(publicResult);
      for (final descriptor in descriptors.cast<Map>()) {
        expect(serialized, isNot(contains(descriptor['artifact_id'])));
        expect(serialized, isNot(contains(descriptor['stream_id'])));
      }
    },
    skip: rustFixture == null
        ? 'build the real Rust host-publication fixture and set GAOVM_GUEST_FIXTURE'
        : false,
  );
  test(
    'real Rust guest disconnect joins the execution before host recovery settles unknown without replay',
    () async {
      final fixture = await _Fixture.create(
        rustFixture: rustFixture!,
        requestForRoot: (root) => GuestExecRequest.fromJson({
          'argv': [
            '/bin/sh',
            '-c',
            r'''printf begun >> "$GUEST_FIXTURE_EXECUTIONS"; printf '%s' "$$" > "$GUEST_FIXTURE_PID_FILE"; exec sleep 30''',
          ],
          'cwd': root,
          'env': {
            'GUEST_FIXTURE_EXECUTIONS': '$root/executions',
            'GUEST_FIXTURE_PID_FILE': '$root/exec.pid',
          },
          'timeout_seconds': 30,
          'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 64},
        }),
      );
      addTearDown(fixture.close);
      final connection = await _connectRustGuest(fixture);
      final pidWritten = _watchGuestPid(fixture.root);
      final request = GuestExecRequest.fromJson(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!.request.toJson(),
      );
      await connection.execStart(
        operationId: fixture.operationId,
        request: request,
        deadline: _deadline(),
      );
      final pid = await pidWritten;
      expect((await Process.run('/bin/kill', ['-0', '$pid'])).exitCode, 0);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) =>
            throw StateError('recovery must not reconnect or replay'),
        maxInFlight: 1,
      );
      addTearDown(worker.close);
      await worker.recoverInterrupted(
        retireOriginalOwners: () async {
          await connection.close();
          // Actual process exit joins the real guest coordinator/exec cleanup,
          // not just caller EOF or a fake retirement callback.
          await fixture.rustGuest!.close();
        },
      );
      expect(
        (await Process.run('/bin/kill', ['-0', '$pid'])).exitCode,
        isNot(0),
      );
      final operation = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(operation.state, OperationState.failed);
      expect(operation.error!.details.toJson()['outcome'], 'unknown');
      expect(
        await File('${fixture.root.path}/executions').readAsString(),
        'begun',
      );
      expect(
        await worker.dispatchOnce(
          onComplete: (_, __, ___) =>
              fail('retired work cannot complete again'),
          onError: (_, __, ___) => fail('retired work cannot be dispatched'),
        ),
        0,
      );
    },
    skip: rustFixture == null
        ? 'build the real Rust host-publication fixture and set GAOVM_GUEST_FIXTURE'
        : false,
  );
  test(
    'invalid collection input cannot consume a durable attempt or send guest IO',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      await expectLater(
        service.captureCollection(
          connection: connection,
          operationId: fixture.operationId,
          attemptId: fixture.attemptId,
          request: JsonObjectValue.fromJson({
            'paths': [],
            'max_total_bytes': 8,
          }),
          deadline: _deadline(),
        ),
        throwsA(isA<GuestSessionException>()),
      );
      expect(
        await fixture.database.read(
          (db) => db.select('SELECT * FROM guest_diagnostic_attempts'),
        ),
        isEmpty,
      );
      final receipt = await _captureCollection(
        fixture,
        service,
        connection,
        control,
        [_collectionDescriptor(ArtifactId.generate(), [])],
      );
      expect(receipt.vmId, fixture.vmId);
      expect(connection.isActive, isTrue);
    },
  );
  test(
    'known original system info survives retirement without a guest resolver or another RPC',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await SqliteTestRunRepository(fixture.database).transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Fixture step failed.',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final service = fixture.service();
      final capture = service.captureSystemInfo(
        connection: connection,
        operationId: run.operationId,
        deadline: _deadline(),
      );
      final info = {
        'os': {'name': 'GaoOS', 'version': 'original'},
        'kernel': 'fixture',
        'architecture': 'aarch64',
        'hostname': 'original-vm',
      };
      await control.reply(await control.read(), info);
      await capture;
      await fixture.database.transaction(
        (db) => db.execute(
          'UPDATE vm_runtime SET driver_generation = 9 WHERE vm_id = ?',
          [fixture.vmId.value],
        ),
      );
      final worker = await _collector(fixture, service);
      await worker.recoverInterrupted(retireOriginalOwners: connection.close);
      final stored = await fixture.database.read(
        (db) =>
            jsonDecode(
                  db.select(
                        'SELECT system_info_json FROM test_run_collection WHERE test_run_id = ?',
                        [run.id.value],
                      ).single['system_info_json']
                      as String,
                )
                as Map,
      );
      expect(stored['state'], 'collected');
      expect(stored['result'], info);
      await expectLater(
        fixture.database.transaction(
          (db) => db.execute(
            "UPDATE test_run_collection SET system_info_json = '{}' WHERE test_run_id = ?",
            [run.id.value],
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
      expect((await worker.dispatchOnce()).single.collected, isTrue);
      expect(
        await fixture.database.read(
          (db) => db.select('SELECT * FROM guest_diagnostic_attempts').length,
        ),
        1,
      );
      final artifact = (await service.artifacts.listForTestRun(
        run.id,
      )).items.singleWhere((a) => a.kind == ArtifactKind.result);
      final report =
          jsonDecode(
                utf8.decode(
                  await (await service.artifacts.download(
                    artifact.id,
                  )).bytes.expand((c) => c).toList(),
                ),
              )
              as Map;
      expect(report['driver_generation'], 8);
    },
  );
  for (final checkpoint in ['published', 'committed']) {
    test(
      'a real collection exit at $checkpoint preserves per-step reservation and recovery identity',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final run = await _oneInlineRun(fixture, {
          'mode': 'inline',
          'text': 'out',
          'size_bytes': 3,
          'truncated': false,
        });
        final vms = await Directory('${fixture.root.path}/vms').create();
        imageFileMode(vms.path, 0x1c0);
        final child = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          'test/helpers/test_run_collection_crash_child.dart',
          fixture.root.path,
          checkpoint,
        ]);
        final stdout = child.stdout.transform(utf8.decoder).join();
        final stderr = child.stderr.transform(utf8.decoder).join();
        var exited = false;
        try {
          final code = await child.exitCode.timeout(
            const Duration(seconds: 15),
          );
          exited = true;
          expect(code, 73, reason: await stderr);
          await stdout;
        } finally {
          if (!exited) child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        }
        fixture.database.close();
        fixture.database = await GaoVmDatabase.open(fixture.databasePath);
        final before = await fixture.database.read(
          (db) => db.select(
            'SELECT artifact_id, state FROM test_run_step_artifacts WHERE test_run_id = ? ORDER BY kind DESC',
            [run.id.value],
          ),
        );
        final reserved = before.first['artifact_id'] as String;
        expect(
          before.first['state'],
          checkpoint == 'committed' ? 'published' : 'pending',
        );
        final service = fixture.service();
        expect(
          (await service.artifacts.reconcile()).damagedArtifactIds,
          isEmpty,
        );
        final worker = await _collector(fixture, service);
        await worker.recoverInterrupted(
          retireOriginalOwners: fixture.session.close,
        );
        expect((await worker.dispatchOnce()).single.collected, isTrue);
        final artifact = (await service.artifacts.repository.get(
          ArtifactId(reserved),
        ))!;
        expect(artifact.kind, ArtifactKind.stdout);
        expect(artifact.testRunId, run.id);
        expect(
          utf8.decode(
            await (await service.artifacts.download(
              artifact.id,
            )).bytes.expand((c) => c).toList(),
          ),
          'out',
        );
        expect(
          (await SqliteEventRepository(fixture.database).list()).where(
            (e) => e.type == 'artifact.created' && e.resourceId == artifact.id,
          ),
          hasLength(1),
        );
      },
    );
  }
  test(
    'collection completion rechecks step payloads after publishing the final report',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await _oneInlineRun(fixture, {
        'mode': 'inline',
        'text': 'out',
        'size_bytes': 3,
        'truncated': false,
      });
      ArtifactId? stdoutId;
      var commits = 0;
      final service = fixture.service(
        onCheckpoint: (checkpoint, id) {
          if (checkpoint != ArtifactPublicationCheckpoint.committed) return;
          commits++;
          stdoutId ??= id;
          if (commits == 3) {
            final file = File(
              '${fixture.artifactRoot.path}/${stdoutId!.value}/payload',
            );
            imageFileMode(file.path, 0x180);
            file.writeAsBytesSync([1, 2, 3]);
            imageFileMode(file.path, 0x100);
          }
        },
      );
      final worker = await _collector(fixture, service);
      final outcome = (await worker.dispatchOnce()).single;
      expect(outcome.collected, isFalse);
      expect(outcome.error, isA<ArtifactContentUnavailable>());
      expect(
        await fixture.database.read(
          (db) => db.select(
            'SELECT completed_at FROM test_run_collection WHERE test_run_id = ?',
            [run.id.value],
          ).single['completed_at'],
        ),
        isNull,
      );
    },
  );
  test(
    'closing publication joins an admitted status capture rather than only binary transfers',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      var settled = false;
      final captured = service
          .captureExecStatus(
            connection: connection,
            operationId: fixture.operationId,
            attemptId: fixture.attemptId,
            request: _request,
            deadline: _deadline(),
          )
          .then<void>(
            (_) {
              fail('closed capture must not create a receipt');
            },
            onError: (Object _, StackTrace __) {
              settled = true;
            },
          );
      await control.read();
      await service.close();
      expect(connection.isActive, isFalse);
      expect(
        await fixture.database.read(
          (db) => db.select('SELECT * FROM guest_artifact_receipts'),
        ),
        isEmpty,
      );
      await captured;
      expect(settled, isTrue);
    },
  );
  test(
    'invalid inline size cannot become a published step artifact or leak into its report',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await _oneInlineRun(fixture, {
        'mode': 'inline',
        'text': 'invalid-inline-payload',
        'size_bytes': 0,
        'truncated': false,
      });
      final service = fixture.service();
      final worker = await _collector(fixture, service);
      expect((await worker.dispatchOnce()).single.collected, isTrue);
      final artifacts = (await service.artifacts.listForTestRun(run.id)).items;
      expect(artifacts.where((a) => a.kind == ArtifactKind.stdout), isEmpty);
      final reportArtifact = artifacts.singleWhere(
        (a) => a.kind == ArtifactKind.result,
      );
      final body = utf8.decode(
        await (await service.artifacts.download(
          reportArtifact.id,
        )).bytes.expand((c) => c).toList(),
      );
      expect(body, isNot(contains('invalid-inline-payload')));
      final report = jsonDecode(body) as Map;
      final output = (report['step_artifacts'] as List).cast<Map>().singleWhere(
        (e) => e['kind'] == 'stdout',
      );
      expect(output['state'], 'failed');
      expect(
        ((output['error'] as Map)['details'] as Map)['reason'],
        'invalid_source',
      );
    },
  );
  for (final (member, changed) in [
    (
      'stream_id',
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
    ),
    (
      'digest',
      'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
    ),
    ('content_type', 'text/plain'),
  ]) {
    test(
      'collection binary metadata cannot change the committed $member',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final (connection, control) = await fixture.ready();
        final service = fixture.service();
        final descriptor = _collectionDescriptor(ArtifactId.generate(), [1]);
        final receipt = await _captureCollection(
          fixture,
          service,
          connection,
          control,
          [descriptor],
        );
        final rejected = expectLater(
          service.receiveCollectionArtifact(receipt, index: 0, maxBytes: 8),
          throwsA(_failure(GuestArtifactFailure.invalidMessage)),
        );
        final binary = await _binary(fixture);
        await binary.send({
          ...fixture.binding,
          'protocol_version': 'gaovm.binary.v1',
          'kind': 'ready',
          'artifact': {...descriptor, member: changed},
        });
        await rejected;
        expect(await service.readCollectionResult(fixture.operationId), isNull);
        expect(
          await service.artifacts.repository.get(
            ArtifactId(descriptor['artifact_id'] as String),
          ),
          isNull,
        );
        expect(connection.isActive, isTrue);
      },
    );
  }
  test(
    'collection siblings remain private until both publish and byte-zero retry reuses the host identity',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final descriptors = [
        for (var i = 0; i < 2; i++)
          _collectionDescriptor(
            ArtifactId.generate(),
            [i],
            streamId: i == 0
                ? _streamId
                : 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          ),
      ];
      final receipt = await _captureCollection(
        fixture,
        service,
        connection,
        control,
        descriptors,
      );
      final ids = <ArtifactId>[];
      for (final index in [0, 0, 1]) {
        final publishing = service.receiveCollectionArtifact(
          receipt,
          index: index,
          maxBytes: 8,
        );
        final binary = await _binary(fixture);
        await binary.send({
          ...fixture.binding,
          'protocol_version': 'gaovm.binary.v1',
          'kind': 'ready',
          'artifact': descriptors[index],
        });
        binary.socket.add(_length(1));
        binary.socket.add([index]);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        final ack = await binary.read();
        expect(ack['stream_id'], descriptors[index]['stream_id']);
        ids.add((await publishing).artifact.id);
        if (index == 0)
          expect(
            await service.readCollectionResult(fixture.operationId),
            isNull,
          );
      }
      expect(ids[0], ids[1]);
      final result = (await service.readCollectionResult(
        fixture.operationId,
      ))!.toJson();
      expect((result['artifacts'] as List).map((a) => (a as Map)['id']), [
        ids[0].value,
        ids[2].value,
      ]);
      expect(
        (await SqliteEventRepository(
          fixture.database,
        ).list()).where((e) => e.type == 'artifact.created'),
        hasLength(2),
      );
      await service.close();
      await connection.close();
      expect(
        (await service.readCollectionResult(fixture.operationId))!.toJson(),
        result,
      );
    },
  );
  test(
    'TestRun collection publishes each inline step output once without guest IO',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final runs = SqliteTestRunRepository(fixture.database);
      for (var index = 0; index < 2; index++) {
        await runs.startStep(run.id, index: index);
        await runs.finishStep(
          run.id,
          index: index,
          state: TestStepState.succeeded,
          result: JsonObjectValue.fromJson({
            'state': 'succeeded',
            'exit_code': 0,
            'stdout': {
              'mode': 'inline',
              'text': 'step-$index\n',
              'size_bytes': 7,
              'truncated': false,
            },
            'stderr': {
              'mode': 'inline',
              'text': '',
              'size_bytes': 0,
              'truncated': false,
            },
            'duration_ms': 1,
            'timed_out': false,
            'signal': null,
          }),
        );
      }
      await runs.transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.succeeded,
      );
      final bundlesPath = await Directory(
        '${fixture.root.path}/bundles',
      ).create();
      imageFileMode(bundlesPath.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(bundlesPath);
      addTearDown(bundles.close);
      final service = fixture.service();
      final worker = TestRunCollectionWorker(
        database: fixture.database,
        bundles: bundles,
        artifacts: service.artifacts,
        guestBudget: fixture.transferBudget,
        resolveGuestConnection: (_, __) => throw StateError(
          'these fixture steps never acquired a guest connection',
        ),
      );
      addTearDown(worker.close);
      expect((await worker.dispatchOnce()).single.collected, isTrue);
      final artifacts = (await service.artifacts.listForTestRun(run.id)).items;
      expect(
        artifacts.where((a) => a.kind == ArtifactKind.stdout),
        hasLength(2),
      );
      expect(
        artifacts.where((a) => a.kind == ArtifactKind.stderr),
        hasLength(2),
      );
      final reportArtifact = artifacts.singleWhere(
        (a) => a.kind == ArtifactKind.result,
      );
      final report =
          jsonDecode(
                utf8.decode(
                  await (await service.artifacts.download(
                    reportArtifact.id,
                  )).bytes.expand((c) => c).toList(),
                ),
              )
              as Map;
      final entries = report['step_artifacts'] as List;
      expect(entries, hasLength(4));
      for (final entry in entries.cast<Map>()) {
        expect(entry['state'], 'published');
        final id = ArtifactId(entry['artifact_id'] as String);
        final artifact = (await service.artifacts.repository.get(id))!;
        expect(artifact.testRunId, run.id);
        expect(artifact.vmId, fixture.vmId);
        final bytes = await (await service.artifacts.download(
          id,
        )).bytes.expand((c) => c).toList();
        expect(
          utf8.decode(bytes),
          entry['kind'] == 'stdout' ? 'step-${entry['step_index']}\n' : '',
        );
        final step =
            ((report['execution'] as Map)['steps'] as List)[entry['step_index']
                    as int]
                as Map;
        expect(
          ((step['result'] as Map)[entry['kind']] as Map)['artifact_id'],
          id.value,
        );
      }
      expect(await worker.dispatchOnce(), isEmpty);
    },
  );
  test(
    'TestRun diagnostic recovery waits for actual retirement and never resolves guest IO',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await SqliteTestRunRepository(fixture.database).transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Fixture step failed.',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final original = fixture.service();
      final captured = expectLater(
        original.captureSystemInfo(
          connection: connection,
          operationId: run.operationId,
          deadline: _deadline(),
        ),
        throwsA(anything),
      );
      await control.read();
      final bundlesPath = await Directory(
        '${fixture.root.path}/bundles',
      ).create();
      imageFileMode(bundlesPath.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(bundlesPath);
      addTearDown(bundles.close);
      final worker = TestRunCollectionWorker(
        database: fixture.database,
        bundles: bundles,
        artifacts: original.artifacts,
        guestBudget: fixture.transferBudget,
        resolveGuestConnection: (_, __) =>
            throw StateError('recovery must not resolve guest IO'),
      );
      addTearDown(worker.close);
      final entered = Completer<void>();
      final retire = Completer<void>();
      final recovering = worker.recoverInterrupted(
        retireOriginalOwners: () async {
          entered.complete();
          await retire.future;
          await original.close();
          await captured;
        },
      );
      await entered.future;
      expect(
        await fixture.database.read(
          (db) => db
              .select('SELECT completed_at FROM guest_diagnostic_attempts')
              .single['completed_at'],
        ),
        isNull,
      );
      await expectLater(worker.dispatchOnce(), throwsStateError);
      retire.complete();
      await recovering;
      final outcome = await fixture.database.read(
        (db) =>
            jsonDecode(
                  db.select(
                        'SELECT system_info_json FROM test_run_collection WHERE test_run_id = ?',
                        [run.id.value],
                      ).single['system_info_json']
                      as String,
                )
                as Map,
      );
      expect(outcome['state'], 'unavailable');
      expect((await worker.dispatchOnce()).single.collected, isTrue);
      expect(connection.isActive, isFalse);
    },
  );
  test(
    'a diagnostic claimed after the initial lookup cannot let collection pass its live owner',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await SqliteTestRunRepository(fixture.database).transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Fixture step failed.',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final original = fixture.service();
      final bundlesPath = await Directory(
        '${fixture.root.path}/bundles',
      ).create();
      imageFileMode(bundlesPath.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(bundlesPath);
      addTearDown(bundles.close);
      late Future<JsonObjectValue> originalCapture;
      var resolutions = 0;
      final worker = TestRunCollectionWorker(
        database: fixture.database,
        bundles: bundles,
        artifacts: original.artifacts,
        guestBudget: fixture.transferBudget,
        resolveGuestConnection: (_, __) {
          resolutions++;
          // This runs after the worker's initial attempt lookup. The foreign
          // claim is queued before its own claim, with real RPC still pending.
          originalCapture = original.captureSystemInfo(
            connection: connection,
            operationId: run.operationId,
            deadline: _deadline(),
          );
          return connection;
        },
      );
      addTearDown(worker.close);
      final collecting = worker.dispatchOnce();
      final call = await control.read();
      final first = (await collecting).single;
      expect(first.collected, isFalse);
      expect(first.error, isA<StateError>());
      expect(connection.isActive, isTrue);
      final checkpoint = await fixture.database.read(
        (db) => db.select(
          'SELECT system_info_json, completed_at FROM test_run_collection WHERE test_run_id = ?',
          [run.id.value],
        ).single,
      );
      expect(checkpoint['system_info_json'], isNull);
      expect(checkpoint['completed_at'], isNull);
      await control.reply(call, {
        'os': {'name': 'GaoOS', 'version': 'original'},
        'kernel': 'fixture',
        'architecture': 'aarch64',
        'hostname': 'test-vm',
      });
      final info = await originalCapture;
      expect((await worker.dispatchOnce()).single.collected, isTrue);
      final stored = await fixture.database.read(
        (db) =>
            jsonDecode(
                  db.select(
                        'SELECT system_info_json FROM test_run_collection WHERE test_run_id = ?',
                        [run.id.value],
                      ).single['system_info_json']
                      as String,
                )
                as Map,
      );
      expect(stored['result'], info.toJson());
      expect(resolutions, 1);
    },
  );
  test(
    'TestRun collection publishes its original system-info snapshot inside the result artifact',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final runs = SqliteTestRunRepository(fixture.database);
      await runs.transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Fixture step failed.',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final bundlesPath = await Directory(
        '${fixture.root.path}/bundles',
      ).create();
      imageFileMode(bundlesPath.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(bundlesPath);
      addTearDown(bundles.close);
      final service = fixture.service();
      var resolutions = 0;
      final worker = TestRunCollectionWorker(
        database: fixture.database,
        bundles: bundles,
        artifacts: service.artifacts,
        guestBudget: fixture.transferBudget,
        resolveGuestConnection: (vm, generation) {
          expect(vm, fixture.vmId);
          expect(generation, 8);
          resolutions++;
          return connection;
        },
      );
      addTearDown(worker.close);
      final collecting = worker.dispatchOnce();
      final call = await control.read();
      expect(call['method'], 'system.info');
      expect(call['operation_id'], run.operationId.value);
      final info = {
        'os': {'name': 'GaoOS', 'version': 'test'},
        'kernel': 'fixture',
        'architecture': 'aarch64',
        'hostname': 'test-vm',
      };
      await control.reply(call, info);
      expect((await collecting).single.collected, isTrue);
      final stored = (await runs.get(run.id))!;
      final resultArtifact = (await service.artifacts.repository.list(
        ArtifactListQuery(owner: run.id),
      )).items.singleWhere((a) => a.kind == ArtifactKind.result);
      final download = await service.artifacts.download(resultArtifact.id);
      final report =
          jsonDecode(
                utf8.decode(await download.bytes.expand((c) => c).toList()),
              )
              as Map;
      expect((report['system_info'] as Map)['state'], 'collected');
      expect((report['system_info'] as Map)['result'], info);
      expect(stored.artifactIds, contains(resultArtifact.id));
      expect(await worker.dispatchOnce(), isEmpty);
      expect(resolutions, 1);
    },
  );
  test(
    'collecting TestRun captures system info on its original VM start checkpoint',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await SqliteTestRunRepository(fixture.database).transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Fixture step failed.',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final service = fixture.service();
      final capturing = service.captureSystemInfo(
        connection: connection,
        operationId: run.operationId,
        deadline: _deadline(),
      );
      final call = await control.read();
      expect(call['operation_id'], run.operationId.value);
      await control.reply(call, {
        'os': {'name': 'GaoOS', 'version': 'test'},
        'kernel': 'fixture',
        'architecture': 'aarch64',
        'hostname': 'test-vm',
      });
      final snapshot = await capturing;
      expect(await service.readSystemInfoResult(run.operationId), snapshot);
      expect(
        await fixture.database.read(
          (db) => db
              .select('SELECT source_attempt_id FROM guest_diagnostic_attempts')
              .single['source_attempt_id'],
        ),
        isNull,
      );
    },
  );
  test(
    'system info is an original-operation durable snapshot rather than a replayable query',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final capturing = service.captureSystemInfo(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        deadline: _deadline(),
      );
      final call = await control.read();
      expect(call['method'], 'system.info');
      expect(call['operation_id'], fixture.operationId.value);
      await control.reply(call, {
        'os': {'name': 'GaoOS', 'version': 'test'},
        'kernel': 'fixture',
        'architecture': 'aarch64',
        'hostname': 'test-vm',
      });
      final snapshot = await capturing;
      expect(await service.readSystemInfoResult(fixture.operationId), snapshot);
      expect(
        await service.captureSystemInfo(
          connection: connection,
          operationId: fixture.operationId,
          attemptId: fixture.attemptId,
          deadline: _deadline(),
        ),
        snapshot,
      );
      await expectLater(
        fixture.service().captureSystemInfo(
          connection: connection,
          operationId: fixture.operationId,
          attemptId: fixture.attemptId,
          deadline: _deadline(),
        ),
        throwsA(isA<GuestArtifactException>()),
      );
      final observer = await GaoVmDatabase.open(fixture.databasePath);
      addTearDown(observer.close);
      expect(
        await observer.read(
          (db) => jsonDecode(
            db
                    .select('SELECT result_json FROM guest_diagnostic_attempts')
                    .single['result_json']
                as String,
          ),
        ),
        snapshot.toJson(),
      );
      expect(connection.isActive, isTrue);
    },
  );
  test(
    'collection start marker commits before IO and duplicate owners cannot replay it',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final request = JsonObjectValue.fromJson({
        'paths': [
          {'path': 'diagnostic.bin', 'kind': 'file'},
        ],
        'max_total_bytes': 8,
      });
      final first = service.captureCollection(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: request,
        deadline: _deadline(),
      );
      final call = await control.read();
      final observer = await GaoVmDatabase.open(fixture.databasePath);
      addTearDown(observer.close);
      final marker = await observer.read(
        (db) => db.select('SELECT * FROM guest_diagnostic_attempts').single,
      );
      expect(marker['method'], 'artifact.collect');
      expect(marker['source_attempt_id'], fixture.attemptId.value);
      expect(marker['control_epoch_id'], connection.epochId.value);
      expect(marker['result_json'], isNull);
      final duplicate = service.captureCollection(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: request,
        deadline: _deadline(),
      );
      await expectLater(
        fixture.service().captureCollection(
          connection: connection,
          operationId: fixture.operationId,
          attemptId: fixture.attemptId,
          request: request,
          deadline: _deadline(),
        ),
        throwsA(
          isA<GuestArtifactException>().having(
            (e) => e.code,
            'code',
            GuestArtifactFailure.superseded,
          ),
        ),
      );
      await control.reply(call, {'artifacts': []});
      final receipt = await first;
      expect(await duplicate, same(receipt));
      expect(
        await service.readCollectionResult(fixture.operationId),
        JsonObjectValue.fromJson({'artifacts': []}),
      );
      expect(
        await observer.read(
          (db) => db.select('SELECT * FROM guest_artifact_receipts').length,
        ),
        1,
      );
      expect(connection.isActive, isTrue);
    },
  );
  test(
    'collected bytes are durably published before ACK without exposing guest identifiers',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final body = [0, 255, 9];
      final guestId = ArtifactId.generate();
      final descriptor = {
        'artifact_id': guestId.value,
        'kind': 'file',
        'content_type': 'application/octet-stream',
        'size_bytes': body.length,
        'digest': 'sha256:${sha256.convert(body)}',
        'stream_id': _streamId,
      };
      final capturing = service.captureCollection(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: JsonObjectValue.fromJson({
          'paths': [
            {'path': 'diagnostic.bin', 'kind': 'file'},
          ],
          'max_total_bytes': 8,
        }),
        deadline: _deadline(),
      );
      final call = await control.read();
      expect(call['method'], 'artifact.collect');
      await control.reply(call, {
        'artifacts': [descriptor],
      });
      final receipt = await capturing;
      final publishing = service.receiveCollectionArtifact(
        receipt,
        index: 0,
        maxBytes: 8,
      );
      final binary = await fixture.accept('binary');
      expect(await binary.bytes(4), ascii.encode('GAB1'));
      final open = await binary.read();
      expect(open['source'], {'kind': 'collection', 'stream_id': _streamId});
      await binary.send({
        ...fixture.binding,
        'protocol_version': 'gaovm.binary.v1',
        'kind': 'ready',
        'artifact': descriptor,
      });
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      expect((await binary.read())['kind'], 'committed');
      final published = await publishing;
      expect(published.artifact.id, isNot(guestId));
      expect(published.artifact.kind, ArtifactKind.file);
      final publicResult = (await service.readCollectionResult(
        fixture.operationId,
      ))!.toJson();
      expect(
        (publicResult['artifacts'] as List).single,
        published.artifact.toJson(),
      );
      expect(jsonEncode(publicResult), isNot(contains(_streamId)));
      await _httpDownload(
        fixture,
        service.artifacts,
        published.artifact,
        guestId,
        body,
      );
    },
  );
  test(
    'TestRun recovery settles an uncertain original child before advancing its parent',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, _) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final child = await acceptance.executeStep(run.id, index: 0);
      final attempt = RequestId.generate();
      await acceptance.beginAttempt(
        child.operationId,
        attemptId: attempt,
        controlEpochId: connection.epochId,
        stillCurrent: () => connection.isReady,
      );
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) =>
            throw StateError('recovery cannot authorize guest IO'),
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      addTearDown(steps.close);
      await steps.recoverInterrupted(
        retireOriginalOwners: () =>
            guest.recoverInterrupted(retireOriginalOwners: connection.close),
      );
      final job = (await SqliteGuestExecRepository(
        fixture.database,
      ).get(child.operationId))!;
      expect(job.attemptId, attempt);
      expect(job.completedAt, isNotNull);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.steps[0].state, TestStepState.failed);
      expect(stored.steps[0].error!.details.toJson()['outcome'], 'unknown');
      expect(stored.steps[1].state, TestStepState.skipped);
      expect(await steps.dispatchOnce(), 0);
    },
  );
  test('TestRun step execution accepts an omitted overall timeout', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final run = await fixture.runningTestRun(timeoutSeconds: null);
    final steps = TestRunStepWorker(
      database: fixture.database,
      guestExec: fixture.acceptance,
    );
    addTearDown(steps.close);
    expect(await steps.dispatchOnce(), 1);
    final child = await fixture.acceptance.executeStep(run.id, index: 0);
    expect(
      (await SqliteOperationRepository(
        fixture.database,
      ).get(child.operationId))!.deadlineAt,
      isNull,
    );
  });
  test(
    'TestRun invalid guest request fails durably before child acceptance',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun(
        stepRequests: [
          TestStepRequest(argv: ['first'], cwd: '', timeoutSeconds: 30),
        ],
      );
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: fixture.acceptance,
      );
      expect(await steps.dispatchOnce(), 0);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.error!.code, ErrorCode.invalidRequest);
      expect(stored.error!.details.toJson()['outcome'], 'not_started');
      expect(stored.steps.single.state, TestStepState.skipped);
    },
  );
  test(
    'v19 preserves an interrupted v18 TestRun without manufacturing a step execution binding',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await SqliteTestRunRepository(
        fixture.database,
      ).startStep(run.id, index: 0);
      final before = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      final events = await SqliteEventRepository(fixture.database).list();
      final outbox = await SqliteEventRepository(
        fixture.database,
      ).readUnpublishedOutbox();
      fixture.database.close();
      final historical = sqlite3.open(fixture.databasePath);
      historical.execute('DROP TRIGGER test_run_system_info_immutable');
      historical.execute(
        'ALTER TABLE test_run_collection DROP COLUMN system_info_json',
      );
      historical.execute('DROP TABLE test_run_step_artifacts');
      historical.execute('DROP TABLE guest_diagnostic_attempts');
      historical.execute('DROP INDEX guest_collection_receipt_operation_idx');
      historical.execute(
        'ALTER TABLE vm_runtime DROP COLUMN display_observed_at',
      );
      historical.execute('ALTER TABLE vm_runtime DROP COLUMN display_state');
      historical.execute(
        'ALTER TABLE vm_runtime DROP COLUMN driver_operation_id',
      );
      historical.execute('DELETE FROM schema_migrations WHERE version = 21');
      historical.execute('DELETE FROM schema_migrations WHERE version = 20');
      historical.execute('DROP TABLE test_run_step_execs');
      historical.execute('DELETE FROM schema_migrations WHERE version = 19');
      historical.userVersion = 18;
      historical.dispose();
      fixture.database = await GaoVmDatabase.open(fixture.databasePath);
      expect(fixture.database.schemaVersion, 21);
      expect(
        await SqliteTestRunRepository(fixture.database).get(run.id),
        before,
      );
      expect(await SqliteEventRepository(fixture.database).list(), events);
      expect(
        (await SqliteEventRepository(
          fixture.database,
        ).readUnpublishedOutbox()).map((row) => row.id),
        outbox.map((row) => row.id),
      );
      expect(
        await fixture.database.read(
          (db) => db.select('SELECT * FROM test_run_step_execs'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'failed TestRun child binding rolls back the step, child operation, event and outbox together',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      Future<Map<String, int>> counts() => fixture.database.read(
        (db) => {
          for (final table in [
            'operations',
            'events',
            'outbox',
            'guest_exec_jobs',
            'test_run_step_execs',
          ])
            table:
                db
                        .select('SELECT COUNT(*) AS count FROM $table')
                        .single['count']
                    as int,
        },
      );
      final before = await counts();
      await fixture.database.transaction(
        (db) => db.execute(
          "CREATE TRIGGER reject_step_binding BEFORE INSERT ON test_run_step_execs BEGIN SELECT RAISE(ABORT, 'fixture step binding failure'); END",
        ),
      );
      await expectLater(
        fixture.acceptance.executeStep(run.id, index: 0),
        throwsA(isA<SqliteException>()),
      );
      expect(
        (await SqliteTestRunRepository(
          fixture.database,
        ).get(run.id))!.steps[0].state,
        TestStepState.pending,
      );
      expect(await counts(), before);
    },
  );
  test(
    'TestRun dispatch loop keeps VM-B progressing while VM-A guest polling stalls',
    () async {
      final first = await _Fixture.create();
      addTearDown(first.close);
      final second = await _Fixture.create(catalogOwner: first);
      addTearDown(second.close);
      final a = await first.runningTestRun();
      final b = await second.runningTestRun();
      final (ca, pa) = await first.ready(beginAttempt: false);
      final (cb, pb) = await second.ready(beginAttempt: false);
      final acceptance = GuestExecApplicationService(
        database: first.database,
        resolveController: (id) => id == first.vmId
            ? first.resolveController(id)
            : second.resolveController(id),
      );
      final steps = TestRunStepWorker(
        database: first.database,
        guestExec: acceptance,
      );
      final errors = <Object>[];
      final stepLoop = TestRunStepDispatchLoop(
        worker: steps,
        interval: const Duration(milliseconds: 10),
        onError: (error, _) => errors.add(error),
      );
      addTearDown(stepLoop.close);
      final guest = GuestExecWorker(
        database: first.database,
        acceptance: acceptance,
        artifacts: first.service().artifacts,
        budget: first.transferBudget,
        resolveConnection: (id, _) => id == first.vmId ? ca : cb,
        maxInFlight: 2,
      );
      final guestLoop = GuestExecDispatchLoop(
        worker: guest,
        interval: const Duration(milliseconds: 10),
        onComplete: (_, __, ___) {},
        onError: (_, error, __) => errors.add(error),
      );
      addTearDown(guestLoop.close);
      stepLoop.start();
      guestLoop.start();
      final startA = await pa.read().timeout(const Duration(seconds: 3));
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await pa.reply(startA, {
        ...result,
        'state': 'running',
        'exit_code': null,
      });
      final stalled = await pa.read();
      for (var index = 0; index < 2; index++) {
        final startB = await pb.read().timeout(const Duration(seconds: 3));
        expect((startB['params'] as Map)['argv'], [
          index == 0 ? 'first' : 'second',
        ]);
        await pb.reply(startB, result);
        await pb.reply(await pb.read(), result);
        await guest.run(OperationId(startB['operation_id'] as String));
      }
      await steps.dispatchOnce();
      final runs = SqliteTestRunRepository(first.database);
      expect((await runs.get(b.id))!.state, TestRunState.collecting);
      expect((await runs.get(a.id))!.steps[1].state, TestStepState.pending);
      await pa.reply(stalled, result);
      await guest.run(OperationId(startA['operation_id'] as String));
      final secondA = await pa.read().timeout(const Duration(seconds: 3));
      expect((secondA['params'] as Map)['argv'], ['second']);
      await pa.reply(secondA, result);
      await pa.reply(await pa.read(), result);
      await guest.run(OperationId(secondA['operation_id'] as String));
      await steps.dispatchOnce();
      expect((await runs.get(a.id))!.state, TestRunState.collecting);
      await Future.wait([stepLoop.close(), guestLoop.close()]);
      expect(await steps.dispatchOnce(), 0);
      expect(errors, isEmpty);
    },
  );
  for (final completeAll in [false, true]) {
    test(
      'TestRun recovery preserves known results without replay (all complete: $completeAll)',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final run = await fixture.runningTestRun();
        final (connection, control) = await fixture.ready(beginAttempt: false);
        final acceptance = fixture.acceptance;
        final steps = TestRunStepWorker(
          database: fixture.database,
          guestExec: acceptance,
        );
        addTearDown(steps.close);
        final guest = GuestExecWorker(
          database: fixture.database,
          acceptance: acceptance,
          artifacts: fixture.service().artifacts,
          budget: fixture.transferBudget,
          resolveConnection: (_, __) => connection,
          maxInFlight: 1,
        );
        addTearDown(guest.close);
        final result = {
          ..._result(ArtifactId.generate(), 0),
          'stdout': {
            'mode': 'inline',
            'text': 'ok',
            'truncated': false,
            'size_bytes': 2,
          },
        };
        for (var index = 0; index < (completeAll ? 2 : 1); index++) {
          await steps.dispatchOnce();
          final child = await acceptance.executeStep(run.id, index: index);
          final done = guest.run(child.operationId);
          await control.reply(await control.read(), result);
          await control.reply(await control.read(), result);
          await done;
        }
        final recovered = TestRunStepWorker(
          database: fixture.database,
          guestExec: GuestExecApplicationService(
            database: fixture.database,
            resolveController: (_) async =>
                throw StateError('must not activate a replacement controller'),
          ),
        );
        addTearDown(recovered.close);
        await recovered.recoverInterrupted(
          retireOriginalOwners: connection.close,
        );
        final stored = (await SqliteTestRunRepository(
          fixture.database,
        ).get(run.id))!;
        expect(stored.state, TestRunState.collecting);
        expect(stored.steps[0].state, TestStepState.succeeded);
        expect(stored.steps[0].result!.toJson(), result);
        expect(
          stored.steps[1].state,
          completeAll ? TestStepState.succeeded : TestStepState.skipped,
        );
        expect(
          stored.error?.details.toJson()['outcome'],
          completeAll ? isNull : 'not_started',
        );
        expect(await recovered.dispatchOnce(), 0);
      },
    );
  }
  test(
    'TestRun close fences new dispatch and joins original-owner retirement',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: fixture.acceptance,
      );
      final barrier = Completer<void>();
      final entered = Completer<void>();
      final recovering = steps.recoverInterrupted(
        retireOriginalOwners: () async {
          entered.complete();
          await barrier.future;
        },
      );
      await entered.future;
      var closed = false;
      final closing = steps.close().then((_) {
        closed = true;
      });
      expect(await steps.dispatchOnce(), 0);
      expect(closed, isFalse);
      barrier.complete();
      await Future.wait([recovering, closing]);
      expect(closed, isTrue);
    },
  );
  test(
    'TestRun recovery requires positive retirement before settling an unbound legacy running step',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final runs = SqliteTestRunRepository(fixture.database);
      await runs.startStep(run.id, index: 0);
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: GuestExecApplicationService(
          database: fixture.database,
          resolveController: (_) async =>
              throw StateError('recovery must not activate a controller'),
        ),
      );
      final barrier = Completer<void>();
      final entered = Completer<void>();
      final recovering = steps.recoverInterrupted(
        retireOriginalOwners: () async {
          entered.complete();
          await barrier.future;
        },
      );
      await entered.future;
      expect((await runs.get(run.id))!.steps[0].state, TestStepState.running);
      await expectLater(steps.dispatchOnce(), throwsStateError);
      barrier.complete();
      await recovering;
      final stored = (await runs.get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.steps[0].state, TestStepState.failed);
      expect(stored.steps[0].error!.details.toJson()['outcome'], 'unknown');
      expect(stored.steps[1].state, TestStepState.skipped);
      expect(
        await fixture.database.read(
          (db) => db.select(
            'SELECT 1 FROM test_run_step_execs WHERE test_run_id = ?',
            [run.id.value],
          ),
        ),
        isEmpty,
      );
    },
  );
  test(
    'TestRun dispatch records a changed original checkpoint as failure without starting a child',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await fixture.database.transaction(
        (db) => db.execute('UPDATE vms SET intent_revision = 2 WHERE id = ?', [
          fixture.vmId.value,
        ]),
      );
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: fixture.acceptance,
      );
      expect(await steps.dispatchOnce(), 0);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(
        stored.steps.map((step) => step.state),
        everyElement(TestStepState.skipped),
      );
      expect(stored.error!.code, ErrorCode.vmOperationConflict);
      expect(stored.error!.details.toJson()['outcome'], 'not_started');
      expect(
        await fixture.database.read(
          (db) => db.select(
            'SELECT 1 FROM test_run_step_execs WHERE test_run_id = ?',
            [run.id.value],
          ),
        ),
        isEmpty,
      );
    },
  );
  test(
    'TestRun child output is published under its parent and downloadable through the public API',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun(
        stepRequests: [
          TestStepRequest(argv: ['first'], timeoutSeconds: 30),
        ],
      );
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      await steps.dispatchOnce();
      final child = await acceptance.executeStep(run.id, index: 0);
      final artifacts = fixture.service().artifacts;
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final done = guest.run(child.operationId);
      final guestId = ArtifactId.generate();
      final body = [255, 0, 4];
      await control.reply(await control.read(), _result(guestId, body.length));
      await control.reply(await control.read(), _result(guestId, body.length));
      final binary = await _binary(fixture);
      await binary.send({
        ..._ready(fixture, guestId, body),
        'operation_id': child.operationId.value,
      });
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      expect((await binary.read())['kind'], 'committed');
      final operation = (await done)!;
      final hostId = ArtifactId(
        (operation.result!.toJson()['stdout'] as Map)['artifact_id'] as String,
      );
      expect(hostId, isNot(guestId));
      expect(
        (await ArtifactRepository(fixture.database).get(hostId))!.testRunId,
        run.id,
      );
      final api = await _ExecApi.open(fixture, acceptance, artifacts);
      addTearDown(api.close);
      final publicRun = await api.call('GET', '/v1/test-runs/${run.id.value}');
      expect(publicRun.status, 200);
      expect(publicRun.json['artifact_ids'], [hostId.value]);
      final downloaded = await (await api.client.getUrl(
        Uri.parse('http://localhost/v1/artifacts/${hostId.value}'),
      )).close();
      expect(downloaded.statusCode, 200);
      expect(await downloaded.expand((chunk) => chunk).toList(), body);
      expect(
        (await api.call('GET', '/v1/artifacts/${guestId.value}')).status,
        404,
      );
      await steps.dispatchOnce();
      expect(
        (await SqliteTestRunRepository(fixture.database).get(run.id))!.state,
        TestRunState.collecting,
      );
      final collector = await _collector(fixture, fixture.service());
      expect((await collector.dispatchOnce()).single.collected, isTrue);
      final collected = (await artifacts.listForTestRun(run.id)).items;
      expect(
        collected.where((a) => a.kind == ArtifactKind.stdout).single.id,
        hostId,
      );
      expect(
        (await SqliteEventRepository(fixture.database).list()).where(
          (e) => e.type == 'artifact.created' && e.resourceId == hostId,
        ),
        hasLength(1),
      );
      final reportId = collected
          .singleWhere((a) => a.kind == ArtifactKind.result)
          .id;
      final report =
          jsonDecode(
                utf8.decode(
                  await (await artifacts.download(
                    reportId,
                  )).bytes.expand((c) => c).toList(),
                ),
              )
              as Map;
      final stdout = (report['step_artifacts'] as List).cast<Map>().singleWhere(
        (entry) => entry['kind'] == 'stdout',
      );
      expect(stdout['artifact_id'], hostId.value);
      expect(stdout['state'], 'published');
    },
  );
  test(
    'a TestRun child cannot authorize guest IO after its accepted VM checkpoint changes',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, _) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final child = await acceptance.executeStep(run.id, index: 0);
      await fixture.database.transaction(
        (db) => db.execute('UPDATE vms SET intent_revision = 2 WHERE id = ?', [
          fixture.vmId.value,
        ]),
      );
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final failed = (await guest
          .run(child.operationId)
          .timeout(const Duration(seconds: 1)))!;
      expect(failed.state, OperationState.failed);
      expect(failed.error!.details.toJson()['outcome'], 'not_started');
      expect(
        (await SqliteGuestExecRepository(
          fixture.database,
        ).get(child.operationId))!.startedAt,
        isNull,
      );
      expect(connection.isReady, isTrue);
    },
  );
  test(
    'accepted VM intent changes fence a TestRun step before child acceptance',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await fixture.database.transaction(
        (db) => db.execute('UPDATE vms SET intent_revision = 2 WHERE id = ?', [
          fixture.vmId.value,
        ]),
      );
      await expectLater(
        fixture.acceptance.executeStep(run.id, index: 0),
        throwsA(isA<TestRunConflictException>()),
      );
      expect(
        (await SqliteTestRunRepository(
          fixture.database,
        ).get(run.id))!.steps[0].state,
        TestStepState.pending,
      );
    },
  );
  test(
    'a TestRun parent deadline caps the original child budget and stops future steps',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      await steps.dispatchOnce();
      final child = await acceptance.executeStep(run.id, index: 0);
      final cap = DateTime.now().toUtc().add(const Duration(seconds: 1));
      await fixture.database.transaction(
        (db) => db.execute(
          'UPDATE operations SET deadline_at = ? WHERE id IN (?, ?)',
          [
            cap.toIso8601String(),
            run.operationId.value,
            child.operationId.value,
          ],
        ),
      );
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final done = guest.run(child.operationId);
      final start = await control.read();
      expect(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(child.operationId))!.deadlineAt,
        cap,
      );
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(start, result);
      await done.timeout(const Duration(seconds: 3));
      await steps.dispatchOnce();
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.steps[0].state, TestStepState.failed);
      expect(stored.steps[0].error!.code, ErrorCode.waitTimeout);
      expect(stored.steps[1].state, TestStepState.skipped);
    },
  );
  test(
    'cancelling a TestRun before its first step never authorizes guest work',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      await TestRunApplicationService(database: fixture.database).cancel(
        OperationCancelCommand(
          operationId: run.operationId,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode('{}'),
        ),
      );
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: fixture.acceptance,
      );
      expect(await steps.dispatchOnce(), 0);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(
        stored.steps.map((step) => step.state),
        everyElement(TestStepState.skipped),
      );
    },
  );
  test(
    'TestRun cancellation reaches a stalled original child and prevents later steps',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final steps = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      await steps.dispatchOnce();
      final child = await acceptance.executeStep(run.id, index: 0);
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(guest.close);
      final finished = guest.run(child.operationId);
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(await control.read(), result);
      final stalled = await control.read();
      expect(stalled['method'], 'exec.status');
      await TestRunApplicationService(database: fixture.database).cancel(
        OperationCancelCommand(
          operationId: run.operationId,
          requestId: RequestId.generate(),
          idempotencyKey: 'parent-cancel',
          requestBody: utf8.encode('{}'),
        ),
      );
      final cancel = await control.read().timeout(const Duration(seconds: 1));
      expect(cancel['method'], 'exec.cancel');
      expect(cancel['operation_id'], child.operationId.value);
      expect(await steps.dispatchOnce(), 0);
      expect(
        (await SqliteTestRunRepository(fixture.database).get(run.id))!.state,
        TestRunState.runningSteps,
      );
      final terminal = {...result, 'state': 'cancelled', 'signal': 15};
      await control.reply(cancel, terminal);
      await control.reply(stalled, terminal);
      await finished;
      await steps.dispatchOnce();
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.steps[0].state, TestStepState.cancelled);
      expect(stored.steps[1].state, TestStepState.skipped);
    },
  );
  test(
    'a failed TestRun child preserves diagnostics and skips every later step',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final worker = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      await worker.dispatchOnce();
      final child = await acceptance.executeStep(run.id, index: 0);
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final running = guest.run(child.operationId);
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'failed',
        'exit_code': 7,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(await control.read(), result);
      await control.reply(await control.read(), result);
      await running;
      expect(await worker.dispatchOnce(), 0);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.state, TestRunState.collecting);
      expect(stored.steps[0].state, TestStepState.failed);
      expect(stored.steps[0].result!.toJson(), result);
      expect(stored.steps[0].error!.code, ErrorCode.guestExecFailed);
      expect(stored.steps[1].state, TestStepState.skipped);
    },
  );
  test(
    'TestRun worker executes ordered steps through original guest IO and enters collection only after completion',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final guest = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(guest.close);
      final worker = TestRunStepWorker(
        database: fixture.database,
        guestExec: acceptance,
      );
      expect(await worker.dispatchOnce(), 1);
      final first = await acceptance.executeStep(run.id, index: 0);
      final completed = guest.run(first.operationId);
      final start = await control.read();
      expect((start['params'] as Map)['argv'], ['first']);
      expect(await worker.dispatchOnce(), 0);
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(start, result);
      await control.reply(await control.read(), result);
      await completed;
      expect(await worker.dispatchOnce(), 1);
      final midway = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(midway.steps[0].state, TestStepState.succeeded);
      expect(midway.steps[1].state, TestStepState.running);
      final second = await acceptance.executeStep(run.id, index: 1);
      final completedSecond = guest.run(second.operationId);
      final secondStart = await control.read();
      expect((secondStart['params'] as Map)['argv'], ['second']);
      await control.reply(secondStart, result);
      await control.reply(await control.read(), result);
      await completedSecond;
      expect(await worker.dispatchOnce(), 0);
      final collected = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(collected.state, TestRunState.collecting);
      expect(
        collected.steps.map((step) => step.state),
        everyElement(TestStepState.succeeded),
      );
      expect(collected.steps.map((step) => step.result!.toJson()), [
        result,
        result,
      ]);
    },
  );
  test(
    'TestRun step acceptance atomically binds one child execution and rejects out-of-order steps',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final run = await fixture.runningTestRun();
      final acceptance = fixture.acceptance;
      final accepted = await Future.wait([
        acceptance.executeStep(run.id, index: 0),
        acceptance.executeStep(run.id, index: 0),
      ]);
      final first = accepted[0];
      final repeated = accepted[1];
      expect(repeated.operationId, first.operationId);
      final stored = (await SqliteTestRunRepository(
        fixture.database,
      ).get(run.id))!;
      expect(stored.steps[0].state, TestStepState.running);
      expect(stored.steps[1].state, TestStepState.pending);
      final operation = (await SqliteOperationRepository(
        fixture.database,
      ).get(first.operationId))!;
      expect(operation.state, OperationState.pending);
      expect(
        operation.deadlineAt,
        (await SqliteOperationRepository(
          fixture.database,
        ).get(run.operationId))!.deadlineAt,
      );
      expect(operation.request.toJson()['argv'], ['first']);
      await expectLater(
        fixture.database.transaction(
          (db) => db.execute(
            'UPDATE test_run_step_execs SET operation_id = operation_id WHERE test_run_id = ?',
            [run.id.value],
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
      await expectLater(
        acceptance.executeStep(run.id, index: 1),
        throwsA(isA<TestRunConflictException>()),
      );
      expect(
        (await SqliteTestRunRepository(
          fixture.database,
        ).get(run.id))!.steps[1].state,
        TestStepState.pending,
      );
    },
  );
  test(
    'worker close joins startup original-owner retirement before releasing its catalog',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, _) = await fixture.ready();
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 1,
      );
      addTearDown(worker.close);
      final started = Completer<void>();
      final release = Completer<void>();
      final recovery = worker.recoverInterrupted(
        retireOriginalOwners: () async {
          started.complete();
          await release.future;
          await connection.close();
        },
      );
      await started.future;
      var didClose = false;
      final closing = worker.close().then((_) {
        didClose = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(didClose, isFalse);
      expect(
        (await SqliteGuestExecRepository(
          fixture.database,
        ).get(fixture.operationId))!.completedAt,
        isNull,
      );
      release.complete();
      await recovery;
      await closing;
      expect(didClose, isTrue);
      expect(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!.state,
        OperationState.failed,
      );
    },
  );
  test(
    'public pre-start cancellation settles target and action without guest execution',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, _) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final artifacts = fixture.service().artifacts;
      final api = await _ExecApi.open(fixture, acceptance, artifacts);
      addTearDown(api.close);
      final action = await api.call(
        'POST',
        '/v1/operations/${fixture.operationId.value}/cancel',
        body: const {},
        key: 'public-cancel',
      );
      expect(action.status, 202);
      expect(action.json['state'], 'pending');
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) =>
            throw StateError('pre-cancel cannot resolve guest IO'),
        maxInFlight: 1,
      );
      addTearDown(worker.close);
      expect(
        (await worker.run(fixture.operationId))!.state,
        OperationState.cancelled,
      );
      expect(
        (await SqliteGuestExecRepository(
          fixture.database,
        ).get(fixture.operationId))!.startedAt,
        isNull,
      );
      expect(connection.isReady, isTrue);
      final settled = await api.call(
        'GET',
        '/v1/operations/${action.json['operation_id']}',
      );
      expect(settled.status, 200);
      expect(settled.json['state'], 'succeeded');
    },
  );
  for (final corrupt in [false, true]) {
    test(
      'startup verifies mapped output before known completion (corrupt=$corrupt)',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final (connection, control) = await fixture.ready();
        final service = fixture.service();
        final guestId = ArtifactId.generate();
        final receipt = await _capture(
          fixture,
          service,
          connection,
          control,
          _result(guestId, 3),
        );
        final receiving = service.receiveOutput(
          receipt,
          output: 'stdout',
          maxBytes: 3,
        );
        final binary = await _binary(fixture);
        final body = [1, 2, 3];
        await binary.send(_ready(fixture, guestId, body));
        binary.socket.add(_length(3));
        binary.socket.add(body);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        expect((await binary.read())['kind'], 'committed');
        final publication = await receiving;
        if (corrupt) {
          final payload = File(
            '${fixture.artifactRoot.path}/${publication.artifact.id.value}/payload',
          );
          imageFileMode(payload.path, 0x180);
          await payload.writeAsBytes([3, 2, 1]);
          imageFileMode(payload.path, 0x100);
        }
        final worker = GuestExecWorker(
          database: fixture.database,
          acceptance: fixture.acceptance,
          artifacts: service.artifacts,
          budget: fixture.transferBudget,
          resolveConnection: (_, __) =>
              throw StateError('recovery must not reconnect'),
          maxInFlight: 1,
        );
        addTearDown(worker.close);
        await worker.recoverInterrupted(
          retireOriginalOwners: () async {
            await connection.close();
            await service.close();
          },
        );
        final operation = (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!;
        expect(
          operation.state,
          corrupt ? OperationState.failed : OperationState.succeeded,
        );
        if (corrupt) {
          expect(
            operation.error!.details.toJson()['outcome'],
            'known_result_incomplete',
          );
          expect(operation.result, isNull);
        } else {
          expect(
            (operation.result!.toJson()['stdout'] as Map)['artifact_id'],
            publication.artifact.id.value,
          );
        }
      },
    );
  }
  test(
    'recovery retains known terminal evidence when output mappings are incomplete',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      await _capture(
        fixture,
        service,
        connection,
        control,
        _result(ArtifactId.generate(), 3),
      );
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: service.artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) =>
            throw StateError('no recovery replacement'),
        maxInFlight: 1,
      );
      addTearDown(worker.close);
      await worker.recoverInterrupted(retireOriginalOwners: connection.close);
      final operation = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(operation.state, OperationState.failed);
      expect(
        operation.error!.details.toJson()['outcome'],
        'known_result_incomplete',
      );
      expect(operation.result, isNull);
      expect(
        await service.readExecSnapshot(fixture.operationId, fixture.attemptId),
        isNotNull,
      );
    },
  );
  test(
    'one production loop progresses another VM while the original guest status is stalled',
    () async {
      final first = await _Fixture.create();
      addTearDown(first.close);
      final second = await _Fixture.create(catalogOwner: first);
      addTearDown(second.close);
      final (firstConnection, firstControl) = await first.ready(
        beginAttempt: false,
      );
      final (secondConnection, secondControl) = await second.ready(
        beginAttempt: false,
      );
      final acceptance = GuestExecApplicationService(
        database: first.database,
        resolveController: (id) => id == first.vmId
            ? first.resolveController(id)
            : second.resolveController(id),
      );
      final worker = GuestExecWorker(
        database: first.database,
        acceptance: acceptance,
        artifacts: first.service().artifacts,
        budget: first.transferBudget,
        resolveConnection: (vm, generation) => generation != 8
            ? null
            : vm == first.vmId
            ? firstConnection
            : vm == second.vmId
            ? secondConnection
            : null,
        maxInFlight: 2,
        pollInterval: const Duration(milliseconds: 10),
      );
      final firstDone = Completer<Operation>();
      final secondDone = Completer<Operation>();
      final errors = <Object>[];
      final loop = GuestExecDispatchLoop(
        worker: worker,
        interval: const Duration(milliseconds: 10),
        onComplete: (operation, vm, generation) {
          expect(generation, 8);
          (vm == first.vmId ? firstDone : secondDone).complete(operation);
        },
        onError: (_, error, __) => errors.add(error),
      );
      addTearDown(loop.close);
      loop.start();
      final firstStart = await firstControl.read();
      final secondStart = await secondControl.read().timeout(
        const Duration(seconds: 1),
      );
      expect(firstStart['operation_id'], first.operationId.value);
      expect(secondStart['operation_id'], second.operationId.value);
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await firstControl.reply(firstStart, {
        ...result,
        'state': 'running',
        'exit_code': null,
      });
      final stalledStatus = await firstControl.read();
      expect(stalledStatus['method'], 'exec.status');
      await secondControl.reply(secondStart, result);
      await secondControl.reply(await secondControl.read(), result);
      expect(
        (await secondDone.future.timeout(const Duration(seconds: 1))).state,
        OperationState.succeeded,
      );
      expect(
        (await SqliteOperationRepository(
          first.database,
        ).get(first.operationId))!.state,
        OperationState.running,
      );
      expect(firstDone.isCompleted, isFalse);
      await firstControl.reply(stalledStatus, result);
      expect((await firstDone.future).state, OperationState.succeeded);
      await loop.close();
      expect(errors, isEmpty);
      await expectLater(worker.run(second.operationId), throwsStateError);
    },
  );
  test(
    'public UDS guest exec returns durable acceptance and downloadable host output without replay',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      await acceptance.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode('{}'),
          operationId: fixture.operationId,
        ),
      );
      await SqliteGuestExecRepository(
        fixture.database,
      ).cancelBeforeStart(fixture.operationId);
      final artifacts = fixture.service().artifacts;
      final api = await _ExecApi.open(fixture, acceptance, artifacts);
      addTearDown(api.close);
      final path = '/v1/vms/${fixture.vmId.value}/guest/exec';
      final accepted = await api.call(
        'POST',
        path,
        body: _request.toJson(),
        key: 'public-exec',
      );
      expect(accepted.status, 202);
      final id = OperationId(accepted.json['operation_id'] as String);
      expect(accepted.location, '/v1/operations/${id.value}');
      expect(accepted.json['state'], 'pending');
      expect(
        (await SqliteGuestExecRepository(fixture.database).get(id))!.startedAt,
        isNull,
      );
      expect(
        (await api.call(
          'POST',
          path,
          body: {..._request.toJson(), 'timeout_seconds': 31},
          key: 'public-exec',
        )).status,
        409,
      );
      expect(
        (await api.call(
          'POST',
          path,
          body: _request.toJson(),
          key: 'another-exec',
        )).status,
        409,
      );
      expect((await api.call('POST', path, body: {'argv': []})).status, 400);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final completed = worker.run(id);
      final start = await control.read();
      expect(start['method'], 'exec.start');
      expect(start['operation_id'], id.value);
      expect(
        (await SqliteGuestExecRepository(fixture.database).get(id))!.startedAt,
        isNotNull,
      );
      final guestId = ArtifactId.generate();
      await control.reply(start, _result(guestId, 3));
      await control.reply(await control.read(), _result(guestId, 3));
      final binary = await _binary(fixture);
      final body = [255, 0, 4];
      await binary.send({
        ..._ready(fixture, guestId, body),
        'operation_id': id.value,
      });
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      expect((await binary.read())['kind'], 'committed');
      await completed;
      await connection.close();
      final operation = await api.call('GET', '/v1/operations/${id.value}');
      expect(operation.status, 200);
      expect(operation.json['state'], 'succeeded');
      final result = operation.json['result'] as Map;
      final hostId = ArtifactId(
        (result['stdout'] as Map)['artifact_id'] as String,
      );
      expect(hostId, isNot(guestId));
      final downloaded = await (await api.client.getUrl(
        Uri.parse('http://localhost/v1/artifacts/${hostId.value}'),
      )).close();
      expect(downloaded.statusCode, 200);
      expect(await downloaded.expand((chunk) => chunk).toList(), body);
      expect(
        (await api.call('GET', '/v1/artifacts/${guestId.value}')).status,
        404,
      );
      final replay = await api.call(
        'POST',
        path,
        body: _request.toJson(),
        key: 'public-exec',
      );
      expect(replay.status, 202);
      expect(replay.json, accepted.json);
      expect((await worker.run(id))!.state, OperationState.succeeded);
      await fixture.database.transaction(
        (db) => db.execute(
          "UPDATE vm_runtime SET guest_agent = 'unavailable' WHERE vm_id = ?",
          [fixture.vmId.value],
        ),
      );
      expect(
        (await api.call('POST', path, body: _request.toJson())).status,
        503,
      );
    },
  );
  test(
    'dispatch adopts committed jobs without waiting for guest IO and acknowledges terminal work',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      await acceptance.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode('{}'),
          operationId: fixture.operationId,
        ),
      );
      await SqliteGuestExecRepository(
        fixture.database,
      ).cancelBeforeStart(fixture.operationId);
      final accepted = await acceptance.execute(
        GuestExecCommand(
          vmId: fixture.vmId,
          requestId: RequestId.generate(),
          idempotencyKey: 'dispatch-once',
          requestBody: utf8.encode(jsonEncode(_request.toJson())),
          request: _request,
        ),
      );
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final results = <Operation>[];
      final errors = <Object>[];
      Future<int> dispatch() => worker.dispatchOnce(
        onComplete: (operation, _, __) => results.add(operation),
        onError: (_, error, __) => errors.add(error),
      );
      expect(await dispatch().timeout(const Duration(seconds: 1)), 1);
      expect(await dispatch(), 0);
      final start = await control.read();
      expect(start['method'], 'exec.start');
      expect(start['operation_id'], accepted.operationId.value);
      final result = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(start, result);
      await control.reply(await control.read(), result);
      await worker.run(accepted.operationId);
      await dispatch();
      expect(results.single.state, OperationState.succeeded);
      expect(errors, isEmpty);
      expect(
        await fixture.database.read(
          (db) => db.select(
            "SELECT 1 FROM outbox WHERE topic = 'guest.exec' AND published_at IS NULL",
          ),
        ),
        isEmpty,
      );
    },
  );
  test(
    'committed execution deadline retains one original budget through polling',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(worker.close);
      final completed = worker.run(fixture.operationId);
      final start = await control.read();
      final operations = SqliteOperationRepository(fixture.database);
      final running = (await operations.get(fixture.operationId))!;
      expect(running.deadlineAt, isNotNull);
      expect(
        running.deadlineAt!.difference(running.startedAt!),
        lessThanOrEqualTo(_request.timeout + const Duration(seconds: 65)),
      );
      final ongoing = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(start, ongoing);
      await control.reply(await control.read(), ongoing);
      final status = await control.read();
      expect(status['method'], 'exec.status');
      expect(
        (await operations.get(fixture.operationId))!.deadlineAt,
        running.deadlineAt,
      );
      await control.reply(status, {
        ...ongoing,
        'state': 'failed',
        'timed_out': true,
        'signal': 9,
      });
      await completed;
      final failed = (await operations.get(fixture.operationId))!;
      expect(failed.deadlineAt, running.deadlineAt);
      expect(failed.state, OperationState.failed);
      expect(failed.error!.details.toJson()['timed_out'], isTrue);
    },
  );
  test(
    'startup recovery waits for original owner retirement and never replays a started attempt',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, _) = await fixture.ready();
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) =>
            throw StateError('recovery must not open a replacement'),
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final retiring = Completer<void>();
      final release = Completer<void>();
      final recovery = worker.recoverInterrupted(
        retireOriginalOwners: () async {
          retiring.complete();
          await release.future;
          await connection.close();
        },
      );
      await retiring.future;
      expect(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!.state,
        OperationState.running,
      );
      expect(connection.isReady, isTrue);
      release.complete();
      await recovery;
      final failed = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(failed.state, OperationState.failed);
      expect(failed.error!.details.toJson()['outcome'], 'unknown');
      expect(
        (await SqliteGuestExecRepository(
          fixture.database,
        ).get(fixture.operationId))!.attemptId,
        fixture.attemptId,
      );
      expect(
        (await worker.run(fixture.operationId))!.toJson(),
        failed.toJson(),
      );
    },
  );
  test(
    'unavailable original guest fails an unstarted job without claiming or sending it',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => null,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final completed = (await worker.run(fixture.operationId))!;
      expect(completed.state, OperationState.failed);
      expect(completed.error!.code, ErrorCode.guestAgentUnavailable);
      expect(completed.error!.details.toJson()['outcome'], 'not_started');
      final job = (await SqliteGuestExecRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(job.startedAt, isNull);
      expect(job.attemptId, isNull);
      expect(job.controlEpochId, isNull);
      expect(job.completedAt, completed.completedAt);
    },
  );
  test(
    'durable cancellation reaches the original owner while exec status is stalled',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final acceptance = fixture.acceptance;
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(worker.close);
      final completed = worker.run(fixture.operationId);
      final running = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      };
      await control.reply(await control.read(), running);
      final status = await control.read();
      expect(status['method'], 'exec.status');
      final action = (await acceptance.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: 'stalled-cancel',
          requestBody: utf8.encode('{}'),
          operationId: fixture.operationId,
        ),
      )).operationId;
      expect(
        (await SqliteOperationRepository(fixture.database).get(action))!.state,
        OperationState.pending,
      );
      final cancel = await control.read().timeout(const Duration(seconds: 1));
      expect(cancel['method'], 'exec.cancel');
      expect(cancel['operation_id'], fixture.operationId.value);
      final terminal = {...running, 'state': 'cancelled', 'signal': 15};
      await control.reply(cancel, terminal);
      await control.reply(status, terminal);
      await completed;
      final operations = SqliteOperationRepository(fixture.database);
      expect(
        (await operations.get(fixture.operationId))!.state,
        OperationState.cancelled,
      );
      expect((await operations.get(action))!.state, OperationState.succeeded);
      expect(connection.isReady, isTrue);
    },
  );
  test(
    'lost original start reply becomes one unknown failure and is never replayed',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final completed = worker
          .run(fixture.operationId)
          .then<Object>(
            (value) => value ?? 'missing',
            onError: (Object error) => error,
          );
      expect((await control.read())['method'], 'exec.start');
      control.socket.destroy();
      await control.iterator.cancel();
      expect(await completed, isA<Operation>());
      final failed = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(failed.state, OperationState.failed);
      expect(failed.error!.code, ErrorCode.guestExecFailed);
      expect(failed.error!.details.toJson()['outcome'], 'unknown');
      expect(failed.error!.retryable, isFalse);
      expect(
        (await worker.run(fixture.operationId))!.toJson(),
        failed.toJson(),
      );
      expect(
        (await SqliteEventRepository(fixture.database).list(
          operationId: fixture.operationId,
        )).where((event) => event.type == 'operation.completed'),
        hasLength(1),
      );
      expect(
        (await SqliteVmRepository(
          fixture.database,
        ).get(fixture.vmId))!.status.phase,
        VmPhase.running,
      );
    },
  );
  test(
    'owned worker publishes spill bytes before completing its mapped public result',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (_, __) => connection,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final completed = worker.run(fixture.operationId);
      await control.reply(await control.read(), {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      });
      final guestId = ArtifactId.generate();
      await control.reply(await control.read(), _result(guestId, 3));
      // Completion without publication is observable even if no binary is opened.
      final opening = _binary(fixture);
      final first = await Future.any<Object>([
        opening,
        completed.then<Object>((value) => value ?? 'uncompleted'),
      ]);
      expect(first, isA<_Peer>());
      final binary = first as _Peer;
      final body = [255, 0, 4];
      await binary.send(_ready(fixture, guestId, body));
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      expect((await binary.read())['kind'], 'committed');
      await completed;
      final operation = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(operation.state, OperationState.succeeded);
      final hostId = ArtifactId(
        (operation.result!.toJson()['stdout'] as Map)['artifact_id'] as String,
      );
      expect(hostId, isNot(guestId));
      final artifact = fixture.service().artifacts;
      expect(
        await (await artifact.download(
          hostId,
        )).bytes.expand((chunk) => chunk).toList(),
        body,
      );
    },
  );
  test(
    'owned worker starts once and durably completes the original inline execution',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready(beginAttempt: false);
      final worker = GuestExecWorker(
        database: fixture.database,
        acceptance: fixture.acceptance,
        artifacts: fixture.service().artifacts,
        budget: fixture.transferBudget,
        resolveConnection: (vm, generation) =>
            vm == fixture.vmId && generation == 8 ? connection : null,
        maxInFlight: 2,
      );
      addTearDown(worker.close);
      final completed = worker.run(fixture.operationId);
      final duplicate = worker.run(fixture.operationId);
      final start = await control.read();
      expect(start['method'], 'exec.start');
      expect(start['params'], _request.toJson());
      final claimed = (await SqliteGuestExecRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(claimed.startedAt, isNotNull);
      expect(claimed.controlEpochId, connection.epochId);
      await control.reply(start, {
        ..._result(ArtifactId.generate(), 0),
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      });
      final status = await control.read();
      expect(status['method'], 'exec.status');
      final terminal = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': 'ok',
          'truncated': false,
          'size_bytes': 2,
        },
      };
      await control.reply(status, terminal);
      await Future.wait([completed, duplicate]);
      final operation = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(operation.state, OperationState.succeeded);
      expect(operation.result, JsonObjectValue.fromJson(terminal));
      expect(connection.isReady, isTrue);
      expect(
        (await fixture.database.read(
          (db) => db.select('SELECT * FROM guest_exec_jobs'),
        )),
        hasLength(1),
      );
    },
  );
  test(
    'cancellation completion publication failure rolls back the target and every action',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final action =
          (await GuestExecApplicationService(
                database: fixture.database,
                resolveController: (_) async => null,
              ).cancel(
                OperationCancelCommand(
                  requestId: RequestId.generate(),
                  idempotencyKey: 'rollback-cancel',
                  requestBody: utf8.encode('{}'),
                  operationId: fixture.operationId,
                ),
              ))
              .operationId;
      final service = fixture.service();
      await _capture(fixture, service, connection, control, {
        ..._result(ArtifactId.generate(), 0),
        'state': 'cancelled',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
      });
      final events = SqliteEventRepository(fixture.database);
      final before = (await events.readUnpublishedOutbox())
          .map((row) => row.id)
          .toList();
      await fixture.database.transaction(
        (db) => db.execute(
          "CREATE TRIGGER reject_guest_completion BEFORE INSERT ON events WHEN NEW.type = 'operation.completed' AND NEW.operation_id = '${action.value}' BEGIN SELECT RAISE(ABORT, 'fixture completion failure'); END",
        ),
      );
      final jobs = SqliteGuestExecRepository(fixture.database);
      await expectLater(
        jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        throwsA(isA<Exception>()),
      );
      final operations = SqliteOperationRepository(fixture.database);
      expect(
        (await operations.get(fixture.operationId))!.state,
        OperationState.running,
      );
      expect((await operations.get(fixture.operationId))!.result, isNull);
      expect((await operations.get(action))!.state, OperationState.pending);
      expect((await jobs.get(fixture.operationId))!.completedAt, isNull);
      expect(
        (await events.readUnpublishedOutbox()).map((row) => row.id).toList(),
        before,
      );
      await fixture.database.transaction(
        (db) => db.execute('DROP TRIGGER reject_guest_completion'),
      );
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
    },
  );
  test(
    'known cancellation commits captured diagnostics and all cancellation actions together',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final acceptance = GuestExecApplicationService(
        database: fixture.database,
        resolveController: (_) =>
            throw StateError('cancel must not resolve a controller'),
      );
      final actions = <OperationId>[];
      for (var i = 0; i < 2; i++) {
        actions.add(
          (await acceptance.cancel(
            OperationCancelCommand(
              requestId: RequestId.generate(),
              idempotencyKey: 'cancel-$i',
              requestBody: utf8.encode('{}'),
              operationId: fixture.operationId,
            ),
          )).operationId,
        );
      }
      final service = fixture.service();
      final terminal = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'cancelled',
        'exit_code': null,
        'signal': 15,
        'stdout': {
          'mode': 'inline',
          'text': 'bye',
          'truncated': false,
          'size_bytes': 3,
        },
      };
      await _capture(fixture, service, connection, control, terminal);
      final jobs = SqliteGuestExecRepository(fixture.database);
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
      final operations = SqliteOperationRepository(fixture.database);
      final completed = (await operations.get(fixture.operationId))!;
      expect(completed.state, OperationState.cancelled);
      expect(completed.result, JsonObjectValue.fromJson(terminal));
      for (final action in actions) {
        final settled = (await operations.get(action))!;
        expect(settled.state, OperationState.succeeded);
        expect(settled.completedAt, completed.completedAt);
      }
      expect(
        (await jobs.get(fixture.operationId))!.completedAt,
        completed.completedAt,
      );
    },
  );
  test(
    'known failed execution retains diagnostics in its durable public result',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final terminal = {
        ..._result(ArtifactId.generate(), 0),
        'state': 'failed',
        'exit_code': 3,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'stderr': {
          'mode': 'inline',
          'text': 'bad',
          'truncated': false,
          'size_bytes': 3,
        },
      };
      await _capture(fixture, service, connection, control, terminal);
      expect(
        await SqliteGuestExecRepository(fixture.database).completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
      final completed = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(completed.state, OperationState.failed);
      expect(completed.error!.code, ErrorCode.guestExecFailed);
      expect(completed.error!.retryable, isFalse);
      expect(completed.result, JsonObjectValue.fromJson(terminal));
    },
  );
  test(
    'durable inline result completes only the original attempt after control EOF',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final terminal = {
        ..._result(ArtifactId.generate(), 0),
        'stdout': {
          'mode': 'inline',
          'text': 'ok',
          'truncated': false,
          'size_bytes': 2,
        },
      };
      await _capture(fixture, service, connection, control, terminal);
      await connection.close();
      await service.close();
      final jobs = SqliteGuestExecRepository(fixture.database);
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
      final completed = (await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(completed.state, OperationState.succeeded);
      expect(completed.result, JsonObjectValue.fromJson(terminal));
      expect(
        (await jobs.get(fixture.operationId))!.completedAt,
        completed.completedAt,
      );
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isFalse,
      );
      expect(
        (await SqliteEventRepository(fixture.database).list(
          operationId: fixture.operationId,
        )).where((event) => event.type == 'operation.completed'),
        hasLength(1),
      );
      expect(
        (await SqliteVmRepository(
          fixture.database,
        ).get(fixture.vmId))!.status.phase,
        VmPhase.running,
      );
    },
  );
  test(
    'degraded original epoch can capture terminal status and open its output',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final health = connection.health(deadline: _deadline());
      await control.reply(await control.read(), {
        'status': 'degraded',
        'uptime_seconds': 1,
      });
      await health;
      expect(connection.isReady, isFalse);
      expect(connection.isActive, isTrue);
      final service = fixture.service();
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
      );
      final receiving = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 8,
      );
      final binary = await _binary(fixture);
      await binary.send(_ready(fixture, id, []));
      binary.socket.add(_length(0));
      await binary.socket.flush();
      expect((await receiving).acknowledged, isTrue);
      expect((await binary.read())['kind'], 'committed');
      expect(connection.isReady, isFalse);
      expect(
        await service.readExecResult(fixture.operationId, fixture.attemptId),
        isNotNull,
      );
    },
  );
  test(
    'degraded readiness does not revoke the original authenticated output owner',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final written = Completer<void>();
      final service = fixture.service(
        onCheckpoint: (checkpoint, _) {
          if (checkpoint == ArtifactPublicationCheckpoint.receiving &&
              !written.isCompleted)
            written.complete();
        },
      );
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 1),
      );
      final observed = service
          .receiveOutput(receipt, output: 'stdout', maxBytes: 8)
          .then<Object>((value) => value, onError: (Object error) => error);
      final binary = await _binary(fixture);
      await binary.send(_ready(fixture, id, [255]));
      binary.socket.add(_length(1));
      binary.socket.add([255]);
      await binary.socket.flush();
      await written.future;
      final health = connection.health(deadline: _deadline());
      final call = await control.read();
      await control.reply(call, {
        'status': 'degraded',
        'uptime_seconds': 1,
        'checks': {'optional': 'degraded'},
      });
      await health;
      expect(connection.isReady, isFalse);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      final publication = await observed;
      expect(publication, isA<GuestArtifactPublication>());
      expect((publication as GuestArtifactPublication).acknowledged, isTrue);
      expect((await binary.read())['kind'], 'committed');
      expect(
        await service.readExecResult(fixture.operationId, fixture.attemptId),
        isNotNull,
      );
    },
  );
  test(
    'fragmented metadata and full 8 KiB coalesced chunks end without EOF or trailer publication',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final body = List.generate(16387, (index) => index & 255);
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, body.length),
        deadline: _deadline(const Duration(seconds: 15)),
      );
      final publishing = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 32768,
      );
      final binary = await _binary(fixture);
      final json = utf8.encode(jsonEncode(_ready(fixture, id, body)));
      final header = [..._length(json.length), ...json];
      for (var offset = 0; offset < header.length; offset += 3) {
        binary.socket.add(
          header.sublist(
            offset,
            offset + 3 > header.length ? header.length : offset + 3,
          ),
        );
        await binary.socket.flush();
      }
      binary.socket.add([
        ..._length(8192),
        ...body.take(8192),
        ..._length(8192),
        ...body.skip(8192).take(8192),
        ..._length(3),
        ...body.skip(16384),
        ..._length(0),
        0,
        255,
        10,
        13,
      ]);
      await binary.socket.flush();
      final publication = await publishing;
      expect((await binary.read())['kind'], 'committed');
      final download = await service.artifacts.download(
        publication.artifact.id,
      );
      expect(await download.bytes.expand((chunk) => chunk).toList(), body);
    },
  );
  test(
    'private guest artifact IDs reused by VM-B are not global public identities',
    () async {
      final a = await _Fixture.create();
      final b = await _Fixture.create();
      addTearDown(a.close);
      addTearDown(b.close);
      final budget = GuestArtifactBudget(maxTransfers: 2, maxReservedBytes: 16);
      final privateId = ArtifactId.generate();
      final publicIds = <ArtifactId>[];
      for (final (fixture, body) in [
        (a, [1]),
        (b, [2]),
      ]) {
        final (connection, control) = await fixture.ready();
        final service = fixture.service(budget: budget);
        final receipt = await _capture(
          fixture,
          service,
          connection,
          control,
          _result(privateId, body.length),
        );
        final publishing = service.receiveOutput(
          receipt,
          output: 'stdout',
          maxBytes: 8,
        );
        final binary = await _binary(fixture);
        await binary.send(_ready(fixture, privateId, body));
        binary.socket.add(_length(1));
        binary.socket.add(body);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        final publication = await publishing;
        await binary.read();
        publicIds.add(publication.artifact.id);
        expect(publication.artifact.vmId, fixture.vmId);
        expect(publication.artifact.id, isNot(privateId));
        final download = await service.artifacts.download(
          publication.artifact.id,
        );
        expect(await download.bytes.expand((chunk) => chunk).toList(), body);
      }
      expect(publicIds[0], isNot(publicIds[1]));
    },
  );
  test(
    'public exec output references are available only after both sibling mappings commit',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final stdout = ArtifactId.generate();
      final stderr = ArtifactId.generate();
      final original = _result(stdout, 1);
      original['stderr'] = {
        'mode': 'artifact',
        'artifact_id': stderr.value,
        'size_bytes': 1,
      };
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        original,
      );
      final publishedIds = <String>[];
      final jobs = SqliteGuestExecRepository(fixture.database);
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isFalse,
      );
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: RequestId.generate(),
          controlEpochId: connection.epochId,
        ),
        isFalse,
      );
      for (final (output, id) in [('stdout', stdout), ('stderr', stderr)]) {
        final publishing = service.receiveOutput(
          receipt,
          output: output,
          maxBytes: 8,
        );
        final binary = await _binary(fixture);
        final ready = _ready(fixture, id, [255]);
        (ready['artifact'] as Map)['kind'] = output;
        await binary.send(ready);
        binary.socket.add(_length(1));
        binary.socket.add([255]);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        publishedIds.add((await publishing).artifact.id.value);
        expect((await binary.read())['artifact_id'], id.value);
        if (output == 'stdout') {
          expect(
            await jobs.completeAttempt(
              fixture.operationId,
              attemptId: fixture.attemptId,
              controlEpochId: connection.epochId,
            ),
            isFalse,
          );
          expect(
            await service.readExecResult(
              fixture.operationId,
              fixture.attemptId,
            ),
            isNull,
          );
        }
      }
      final result = (await service.readExecResult(
        fixture.operationId,
        fixture.attemptId,
      ))!.toJson();
      expect((result['stdout'] as Map)['artifact_id'], publishedIds[0]);
      expect((result['stderr'] as Map)['artifact_id'], publishedIds[1]);
      expect(
        await service.readExecSnapshot(fixture.operationId, fixture.attemptId),
        JsonObjectValue.fromJson(original),
      );
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: RequestId.generate(),
        ),
        isFalse,
      );
      await service.close();
      expect(
        await jobs.completeAttempt(
          fixture.operationId,
          attemptId: fixture.attemptId,
          controlEpochId: connection.epochId,
        ),
        isTrue,
      );
      expect(
        (await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId))!.result,
        JsonObjectValue.fromJson(result),
      );
    },
  );
  test(
    'a terminal snapshot cannot be replaced by changed status metadata',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final original = _result(id, 0);
      await _capture(fixture, service, connection, control, original);
      final capturing = service.captureExecStatus(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: _request,
        deadline: _deadline(),
      );
      final rejected = expectLater(
        capturing,
        throwsA(_failure(GuestArtifactFailure.publicationConflict)),
      );
      final status = await control.read();
      await control.reply(status, {...original, 'exit_code': 1});
      await rejected;
      expect(
        await service.readExecSnapshot(fixture.operationId, fixture.attemptId),
        JsonObjectValue.fromJson(original),
      );
      expect(connection.isReady, isTrue);
    },
  );
  test(
    'unconfirmed stage cleanup quarantines shared byte admission and is reported at the close barrier',
    () async {
      final a = await _Fixture.create();
      final b = await _Fixture.create();
      a.allowFailedPublicationCleanup = true;
      addTearDown(a.close);
      addTearDown(b.close);
      final (ca, pa) = await a.ready();
      final (cb, pb) = await b.ready();
      final budget = GuestArtifactBudget(maxTransfers: 1, maxReservedBytes: 8);
      final written = Completer<ArtifactId>();
      final sa = a.service(
        budget: budget,
        onCheckpoint: (checkpoint, id) {
          if (checkpoint == ArtifactPublicationCheckpoint.receiving &&
              !written.isCompleted)
            written.complete(id);
        },
      );
      final sb = b.service(budget: budget);
      final id = ArtifactId.generate();
      final ra = await _capture(a, sa, ca, pa, _result(id, 1));
      final rb = await _capture(
        b,
        sb,
        cb,
        pb,
        _result(ArtifactId.generate(), 1),
      );
      final failed = expectLater(
        sa.receiveOutput(ra, output: 'stdout', maxBytes: 8),
        throwsA(isA<ArtifactPublicationFailure>()),
      );
      final binary = await _binary(a);
      await binary.send(_ready(a, id, [1]));
      binary.socket.add(_length(1));
      binary.socket.add([1]);
      await binary.socket.flush();
      final stagedId = await written.future;
      // Only the fixture's own stage is damaged. Cleanup must preserve an object
      // whose durable ownership receipt no longer matches rather than guess.
      final owner = File(
        '${a.artifactRoot.path}/.stage-${stagedId.value}/owner.json',
      );
      imageFileMode(owner.path, 0x180);
      await owner.writeAsString('{}');
      await expectLater(sa.close(), throwsA(isA<ArtifactPublicationFailure>()));
      await failed;
      await expectLater(
        Future.sync(() => sb.receiveOutput(rb, output: 'stdout', maxBytes: 8)),
        throwsA(_failure(GuestArtifactFailure.limitExceeded)),
      );
      expect((await sa.artifacts.listForVm(a.vmId)).items, isEmpty);
      expect(
        await Directory(
          a.artifactRoot.path,
        ).list().where((entity) => entity is Directory).toList(),
        hasLength(1),
      );
      expect(cb.isReady, isTrue);
    },
  );
  test(
    'replacement control is rejected even before the first terminal snapshot was journaled',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (original, _) = await fixture.ready();
      await original.close();
      final (replacement, _) = await fixture.ready();
      final service = fixture.service();
      await expectLater(
        service
            .captureExecStatus(
              connection: replacement,
              operationId: fixture.operationId,
              attemptId: fixture.attemptId,
              request: _request,
              deadline: _deadline(),
            )
            .timeout(const Duration(milliseconds: 200)),
        throwsA(_failure(GuestArtifactFailure.superseded)),
      );
      expect(replacement.isReady, isTrue);
    },
  );
  test(
    'shared transfer admission is retained until actual stage cleanup joins and then VM-B can progress',
    () async {
      final a = await _Fixture.create();
      final b = await _Fixture.create();
      addTearDown(a.close);
      addTearDown(b.close);
      final (ca, pa) = await a.ready();
      final (cb, pb) = await b.ready();
      final budget = GuestArtifactBudget(maxTransfers: 1, maxReservedBytes: 8);
      final written = Completer<void>();
      final sa = a.service(
        budget: budget,
        onCheckpoint: (checkpoint, _) {
          if (checkpoint == ArtifactPublicationCheckpoint.receiving &&
              !written.isCompleted)
            written.complete();
        },
      );
      final sb = b.service(budget: budget);
      final ida = ArtifactId.generate();
      final idb = ArtifactId.generate();
      final body = [255];
      final ra = await _capture(a, sa, ca, pa, _result(ida, 1));
      final rb = await _capture(b, sb, cb, pb, _result(idb, 1));
      final failed = expectLater(
        sa.receiveOutput(ra, output: 'stdout', maxBytes: 8),
        throwsA(
          anyOf(
            isA<GuestBridgeException>(),
            _failure(GuestArtifactFailure.superseded),
          ),
        ),
      );
      final binary = await _binary(a);
      await binary.send(_ready(a, ida, body));
      binary.socket.add(_length(1));
      binary.socket.add(body);
      await binary.socket.flush();
      await written.future;
      final entered = Completer<void>();
      final release = Completer<void>();
      final holding = a.database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final closing = sa.close();
      try {
        await expectLater(
          Future.sync(
            () => sb.receiveOutput(rb, output: 'stdout', maxBytes: 8),
          ),
          throwsA(_failure(GuestArtifactFailure.limitExceeded)),
        );
      } finally {
        release.complete();
      }
      await holding;
      await closing;
      await failed;
      final publishing = sb.receiveOutput(rb, output: 'stdout', maxBytes: 8);
      final other = await _binary(b);
      await other.send(_ready(b, idb, body));
      other.socket.add(_length(1));
      other.socket.add(body);
      other.socket.add(_length(0));
      await other.socket.flush();
      expect((await publishing).acknowledged, isTrue);
      expect((await other.read())['kind'], 'committed');
      expect(cb.isReady, isTrue);
      expect((await sa.artifacts.listForVm(a.vmId)).items, isEmpty);
      expect(
        await Directory(
          a.artifactRoot.path,
        ).list().where((entity) => entity is Directory).toList(),
        isEmpty,
      );
    },
  );
  test(
    'v18 preserves active v17 guest jobs, operations, events and pending work',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await fixture.ready();
      final jobs = SqliteGuestExecRepository(fixture.database);
      final job = (await jobs.get(fixture.operationId))!;
      final operation = await SqliteOperationRepository(
        fixture.database,
      ).get(fixture.operationId);
      final events = await SqliteEventRepository(fixture.database).list();
      final outbox = await SqliteEventRepository(
        fixture.database,
      ).readUnpublishedOutbox();
      fixture.database.close();
      final historical = sqlite3.open(fixture.databasePath);
      historical.execute('DROP TRIGGER test_run_system_info_immutable');
      historical.execute(
        'ALTER TABLE test_run_collection DROP COLUMN system_info_json',
      );
      historical.execute('DROP TABLE test_run_step_artifacts');
      historical.execute('DROP TABLE guest_diagnostic_attempts');
      historical.execute('DROP INDEX guest_collection_receipt_operation_idx');
      historical.execute(
        'ALTER TABLE vm_runtime DROP COLUMN display_observed_at',
      );
      historical.execute('ALTER TABLE vm_runtime DROP COLUMN display_state');
      historical.execute(
        'ALTER TABLE vm_runtime DROP COLUMN driver_operation_id',
      );
      historical.execute('DELETE FROM schema_migrations WHERE version = 21');
      historical.execute('DELETE FROM schema_migrations WHERE version = 20');
      historical.execute('DROP TABLE test_run_step_execs');
      historical.execute('DELETE FROM schema_migrations WHERE version = 19');
      historical.execute('DROP TABLE guest_artifact_mappings');
      historical.execute('DROP TABLE guest_artifact_receipts');
      historical.execute(
        'DROP TRIGGER guest_exec_jobs_immutable_control_epoch',
      );
      historical.execute(
        'ALTER TABLE guest_exec_jobs DROP COLUMN control_epoch_id',
      );
      historical.execute('DELETE FROM schema_migrations WHERE version = 18');
      historical.userVersion = 17;
      historical.dispose();
      fixture.database = await GaoVmDatabase.open(fixture.databasePath);
      expect(fixture.database.schemaVersion, 21);
      final recovered = (await SqliteGuestExecRepository(
        fixture.database,
      ).get(fixture.operationId))!;
      expect(recovered.vmId, job.vmId);
      expect(recovered.attemptId, job.attemptId);
      expect(recovered.driverGeneration, job.driverGeneration);
      expect(recovered.startedAt, job.startedAt);
      expect(recovered.completedAt, job.completedAt);
      expect(recovered.controlEpochId, isNull);
      expect(
        await SqliteOperationRepository(
          fixture.database,
        ).get(fixture.operationId),
        operation,
      );
      expect(await SqliteEventRepository(fixture.database).list(), events);
      expect(
        (await SqliteEventRepository(
          fixture.database,
        ).readUnpublishedOutbox()).map((row) => row.id),
        outbox.map((row) => row.id),
      );
    },
  );
  test(
    'replacement control in the same generation cannot refresh an original terminal receipt',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (original, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      await _capture(fixture, service, original, control, _result(id, 0));
      await original.close();
      final (replacement, _) = await fixture.ready();
      final nextService = fixture.service();
      await expectLater(
        nextService
            .captureExecStatus(
              connection: replacement,
              operationId: fixture.operationId,
              attemptId: fixture.attemptId,
              request: _request,
              deadline: _deadline(),
            )
            .timeout(const Duration(milliseconds: 200)),
        throwsA(_failure(GuestArtifactFailure.superseded)),
      );
      expect(replacement.isReady, isTrue);
    },
  );
  test(
    'capture validation uses the durable original request rather than a looser caller threshold',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, _) = await fixture.ready();
      final service = fixture.service();
      final modified = Map<String, Object?>.from(_request.toJson());
      modified['capture'] = {
        'stdout': true,
        'stderr': true,
        'max_inline_bytes': 1048576,
      };
      await expectLater(
        service
            .captureExecStatus(
              connection: connection,
              operationId: fixture.operationId,
              attemptId: fixture.attemptId,
              request: GuestExecRequest.fromJson(modified),
              deadline: _deadline(),
            )
            .timeout(const Duration(milliseconds: 200)),
        throwsA(isA<ArgumentError>()),
      );
      expect(connection.isReady, isTrue);
    },
  );
  test(
    'refreshing exec metadata cannot extend the original attempt deadline',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final originalDeadline = _deadline(const Duration(milliseconds: 150));
      await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
        deadline: originalDeadline,
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));
      final retried = service.captureExecStatus(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: _request,
        deadline: _deadline(),
      );
      await expectLater(
        retried.timeout(const Duration(milliseconds: 200)),
        throwsA(
          isA<GuestBridgeException>().having(
            (e) => e.code,
            'failure',
            GuestBridgeFailure.deadlineExpired,
          ),
        ),
      );
      expect(connection.isReady, isTrue);
    },
  );
  for (final boundary in [
    'mapping',
    'staged',
    'generation',
    'epoch',
    'driver-owner',
  ]) {
    test(
      '$boundary failure before SQLite commit leaves no public artifact or ACK',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final (connection, control) = await fixture.ready();
        final id = ArtifactId.generate();
        final body = [4, 3, 2, 1];
        if (boundary == 'mapping') {
          await fixture.database.transaction(
            (db) => db.execute(
              "CREATE TRIGGER reject_mapping BEFORE INSERT ON guest_artifact_mappings BEGIN SELECT RAISE(ABORT, 'fixture mapping failure'); END",
            ),
          );
        }
        Future<void>? invalidation;
        final service = fixture.service(
          onCheckpoint: (checkpoint, _) {
            if (checkpoint != ArtifactPublicationCheckpoint.staged) return;
            if (boundary == 'staged') throw StateError('fixture stage failure');
            if (boundary == 'epoch') invalidation = connection.close();
            if (boundary == 'driver-owner') fixture.driverActive = false;
            if (boundary == 'generation') {
              invalidation = fixture.database.transaction(
                (db) => db.execute(
                  'UPDATE vm_runtime SET driver_generation = 9 WHERE vm_id = ?',
                  [fixture.vmId.value],
                ),
              );
            }
          },
        );
        final receipt = await _capture(
          fixture,
          service,
          connection,
          control,
          _result(id, body.length),
        );
        final rejected = expectLater(
          service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
          throwsA(anyOf(isA<Exception>(), isA<StateError>())),
        );
        final binary = await _binary(fixture);
        await binary.send(_ready(fixture, id, body));
        binary.socket.add(_length(body.length));
        binary.socket.add(body);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        await rejected;
        await invalidation;
        await expectLater(binary.read(), throwsA(isA<StateError>()));
        expect(
          await service.readExecSnapshot(
            fixture.operationId,
            fixture.attemptId,
          ),
          isNotNull,
        );
        expect(
          await service.readExecResult(fixture.operationId, fixture.attemptId),
          isNull,
        );
        expect(
          (await service.artifacts.listForVm(fixture.vmId)).items,
          isEmpty,
        );
        expect(
          (await SqliteEventRepository(
            fixture.database,
          ).list()).where((event) => event.type == 'artifact.created'),
          isEmpty,
        );
        expect(
          await Directory(
            fixture.artifactRoot.path,
          ).list().where((entity) => entity is Directory).toList(),
          isEmpty,
        );
      },
    );
  }
  test(
    'ACK loss after commit preserves both sibling references and downloadable host bytes after reopen',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final body = [255, 0, 7];
      final stdoutId = ArtifactId.generate();
      final stderrId = ArtifactId.generate();
      final original = _result(stdoutId, body.length);
      original['stderr'] = {
        'mode': 'artifact',
        'artifact_id': stderrId.value,
        'size_bytes': 5,
      };
      Future<void>? closing;
      final service = fixture.service(
        onCheckpoint: (checkpoint, _) {
          if (checkpoint == ArtifactPublicationCheckpoint.committed)
            closing = connection.close();
        },
      );
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        original,
      );
      final publishing = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 8,
      );
      final binary = await _binary(fixture);
      await binary.send(_ready(fixture, stdoutId, body));
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      final publication = await publishing;
      await closing;
      expect(publication.acknowledged, isFalse);
      await expectLater(binary.read(), throwsA(isA<StateError>()));
      await service.close();
      fixture.database.close();
      fixture.database = await GaoVmDatabase.open(fixture.databasePath);
      final recovered = fixture.service();
      expect(
        await recovered.readExecSnapshot(
          fixture.operationId,
          fixture.attemptId,
        ),
        JsonObjectValue.fromJson(original),
      );
      expect(
        await recovered.readExecResult(fixture.operationId, fixture.attemptId),
        isNull,
      );
      final download = await recovered.artifacts.download(
        publication.artifact.id,
      );
      expect(await download.bytes.expand((chunk) => chunk).toList(), body);
      expect((await recovered.artifacts.listForVm(fixture.vmId)).items, [
        publication.artifact,
      ]);
    },
  );
  for (final caseName in [
    'early-end',
    'overlong',
    'oversized-chunk',
    'huge-chunk',
    'truncated',
    'digest',
  ]) {
    test(
      '$caseName binary body is never published and does not close control',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final (connection, control) = await fixture.ready();
        final service = fixture.service();
        final id = ArtifactId.generate();
        final body = [1, 2, 3];
        final receipt = await _capture(
          fixture,
          service,
          connection,
          control,
          _result(id, body.length),
        );
        final rejected = expectLater(
          service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
          throwsA(
            anyOf(
              _failure(GuestArtifactFailure.invalidMessage),
              isA<GuestBridgeException>(),
              isA<ArtifactContentMismatch>(),
            ),
          ),
        );
        final binary = await _binary(fixture);
        await binary.send(_ready(fixture, id, body));
        switch (caseName) {
          case 'early-end':
            binary.socket.add(_length(0));
          case 'overlong':
            binary.socket.add(_length(4));
          case 'oversized-chunk':
            binary.socket.add(_length(8193));
          case 'huge-chunk':
            binary.socket.add(_length(4294967295));
          case 'truncated':
            binary.socket.add(_length(3));
            binary.socket.add([1]);
          case 'digest':
            binary.socket.add(_length(3));
            binary.socket.add([3, 2, 1]);
            binary.socket.add(_length(0));
        }
        await binary.socket.flush();
        if (caseName == 'truncated') binary.socket.destroy();
        await rejected;
        expect(connection.isReady, isTrue);
        expect(
          (await service.artifacts.listForVm(fixture.vmId)).items,
          isEmpty,
        );
        expect(
          await service.readExecResult(fixture.operationId, fixture.attemptId),
          isNull,
        );
      },
    );
  }
  for (final mutation in [
    'vm',
    'operation',
    'generation',
    'version',
    'extra',
    'nested-extra',
    'artifact',
    'kind',
    'mime',
    'size',
    'stream',
    'digest',
    'fractional-size',
    'fractional-generation',
    'malformed-json',
    'duplicate',
  ]) {
    test('binary metadata rejects $mutation before reading a body', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
      );
      final rejected = expectLater(
        service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
        throwsA(_failure(GuestArtifactFailure.invalidMessage)),
      );
      final binary = await _binary(fixture);
      final ready = _ready(fixture, id, []);
      final descriptor = ready['artifact'] as Map;
      switch (mutation) {
        case 'vm':
          ready['vm_id'] = VmId.generate().value;
        case 'operation':
          ready['operation_id'] = OperationId.generate().value;
        case 'generation':
          ready['driver_generation'] = 9;
        case 'version':
          ready['protocol_version'] = 'gaovm.binary.v2';
        case 'extra':
          ready['extra'] = true;
        case 'nested-extra':
          descriptor['extra'] = true;
        case 'artifact':
          descriptor['artifact_id'] = ArtifactId.generate().value;
        case 'kind':
          descriptor['kind'] = 'stderr';
        case 'mime':
          descriptor['content_type'] = '';
        case 'size':
          descriptor['size_bytes'] = 1;
        case 'stream':
          descriptor['stream_id'] = 'a' * 63;
        case 'digest':
          descriptor['digest'] = 'sha256:' + 'A' * 64;
      }
      var raw = jsonEncode(ready);
      if (mutation == 'fractional-size')
        raw = raw.replaceFirst(
          '"size_bytes":0',
          '"size_bytes":0.00000000000000000001',
        );
      if (mutation == 'fractional-generation')
        raw = raw.replaceFirst(
          '"driver_generation":8',
          '"driver_generation":8.00000000000000000001',
        );
      if (mutation == 'malformed-json') raw = '[]';
      if (mutation == 'duplicate')
        raw = raw.replaceFirst(
          '"size_bytes":0',
          '"size_bytes":0,"size_bytes":0',
        );
      await binary.sendRaw(raw);
      await rejected;
      expect(connection.isReady, isTrue);
      expect((await service.artifacts.listForVm(fixture.vmId)).items, isEmpty);
    });
  }
  for (final length in [0, 4097, 4294967295]) {
    test(
      'binary header length $length fails without a header allocation or wait',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.close);
        final (connection, control) = await fixture.ready();
        final service = fixture.service();
        final id = ArtifactId.generate();
        final receipt = await _capture(
          fixture,
          service,
          connection,
          control,
          _result(id, 0),
        );
        final rejected = expectLater(
          service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
          throwsA(_failure(GuestArtifactFailure.invalidMessage)),
        );
        final binary = await _binary(fixture);
        binary.socket.add(_length(length));
        await binary.socket.flush();
        await rejected.timeout(const Duration(seconds: 1));
        expect(connection.isReady, isTrue);
      },
    );
  }
  test(
    'one sealed source cannot admit two active host readers and binary backpressure leaves health responsive',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
      );
      final first = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 8,
      );
      final firstClosed = expectLater(
        first,
        throwsA(
          anyOf(
            isA<GuestBridgeException>(),
            _failure(GuestArtifactFailure.superseded),
          ),
        ),
      );
      final binary = await _binary(fixture);
      await binary.send(_ready(fixture, id, []));
      await expectLater(
        Future.sync(
          () => service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
        ),
        throwsA(_failure(GuestArtifactFailure.limitExceeded)),
      );
      final health = connection.health(deadline: _deadline());
      final call = await control.read();
      expect(call['method'], 'health');
      await control.reply(call, {
        'status': 'ok',
        'uptime_seconds': 2,
        'checks': {'dispatcher': 'ok'},
      });
      await health;
      await service.close();
      await firstClosed;
      expect(connection.isReady, isTrue);
    },
  );
  test(
    'binary-side exec metadata accepts legal MIME and exact integer decimal spellings',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final body = [1, 2, 3];
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, body.length),
      );
      final publishing = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 8,
      );
      final binary = await _binary(fixture);
      final ready = _ready(fixture, id, body);
      (ready['artifact'] as Map)['content_type'] = 'text/plain; charset=utf-8';
      final raw = jsonEncode(ready)
          .replaceFirst('"driver_generation":8', '"driver_generation":8.0')
          .replaceFirst('"size_bytes":3', '"size_bytes":30e-1');
      await binary.sendRaw(raw);
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      final publication = await publishing;
      expect(publication.artifact.contentType, 'text/plain; charset=utf-8');
      expect((await binary.read())['kind'], 'committed');
    },
  );
  test(
    'escaped duplicate binary members fail as a bounded protocol error before any body or ACK',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
      );
      final rejected = expectLater(
        service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
        throwsA(_failure(GuestArtifactFailure.invalidMessage)),
      );
      final binary = await _binary(fixture);
      final raw = jsonEncode(_ready(fixture, id, []));
      await binary.sendRaw(
        raw.replaceFirst(
          '"size_bytes":0',
          '"size_bytes":0,"\\u0073ize_bytes":0',
        ),
      );
      await rejected;
      expect(connection.isReady, isTrue);
      expect(
        await service.readExecResult(fixture.operationId, fixture.attemptId),
        isNull,
      );
    },
  );
  test(
    'authorized binary open errors are typed and leave the original control epoch reusable',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final id = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(id, 0),
      );
      final rejected = expectLater(
        service.receiveOutput(receipt, output: 'stdout', maxBytes: 8),
        throwsA(
          isA<GuestBinaryRemoteException>().having(
            (e) => e.code,
            'code',
            'ARTIFACT_NOT_FOUND',
          ),
        ),
      );
      final binary = await fixture.accept('binary');
      await binary.bytes(4);
      await binary.read();
      await binary.send({
        ...fixture.binding,
        'protocol_version': 'gaovm.binary.v1',
        'kind': 'error',
        'artifact_id': id.value,
        'error': {
          'code': 'ARTIFACT_NOT_FOUND',
          'message': 'artifact is not available',
          'retryable': false,
        },
      });
      await rejected;
      expect(connection.isReady, isTrue);
      expect(
        await service.readExecResult(fixture.operationId, fixture.attemptId),
        isNull,
      );
      final publishing = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 8,
      );
      final retry = await fixture.accept('binary');
      await retry.bytes(4);
      await retry.read();
      await retry.send(_ready(fixture, id, []));
      retry.socket.add(_length(0));
      await retry.socket.flush();
      expect((await publishing).acknowledged, isTrue);
      expect((await retry.read())['size_bytes'], 0);
    },
  );
  test(
    'same sealed source retries without another resource, event or public ID',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final service = fixture.service();
      final body = [5, 0, 255];
      final guestId = ArtifactId.generate();
      final receipt = await _capture(
        fixture,
        service,
        connection,
        control,
        _result(guestId, body.length),
      );
      final ids = <ArtifactId>[];
      for (var index = 0; index < 2; index++) {
        final publishing = service.receiveOutput(
          receipt,
          output: 'stdout',
          maxBytes: 64,
        );
        // Install the failure handler before peer IO to avoid unhandled futures.
        final observed = publishing.then((value) => value);
        final binary = await fixture.accept('binary');
        await binary.bytes(4);
        await binary.read();
        await binary.send(_ready(fixture, guestId, body));
        binary.socket.add(_length(body.length));
        binary.socket.add(body);
        binary.socket.add(_length(0));
        await binary.socket.flush();
        final published = await observed;
        ids.add(published.artifact.id);
        expect((await binary.read())['kind'], 'committed');
      }
      expect(ids[1], ids[0]);
      expect(
        (await SqliteEventRepository(
          fixture.database,
        ).list()).where((event) => event.type == 'artifact.created'),
        hasLength(1),
      );
    },
  );
  test(
    'binary commit ACK follows a durable terminal snapshot and host publication',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final (connection, control) = await fixture.ready();
      final body = [0, 255, 128, 10, 13, 42];
      final guestId = ArtifactId.generate();
      final result = _result(guestId, body.length);
      final service = fixture.service();
      final capturing = service.captureExecStatus(
        connection: connection,
        operationId: fixture.operationId,
        attemptId: fixture.attemptId,
        request: _request,
        deadline: _deadline(),
      );
      final status = await control.read();
      expect(status['method'], 'exec.status');
      await control.reply(status, result);
      final receipt = await capturing;
      final publishing = service.receiveOutput(
        receipt,
        output: 'stdout',
        maxBytes: 64,
      );
      final binary = await fixture.accept('binary');
      expect(await binary.bytes(4), ascii.encode('GAB1'));
      final open = await binary.read();
      expect(open, {
        ...fixture.binding,
        'protocol_version': 'gaovm.binary.v1',
        'kind': 'open',
        'artifact_id': guestId.value,
        'source': {'kind': 'exec_output', 'output': 'stdout'},
      });
      await binary.send(_ready(fixture, guestId, body));
      // The guest does not close its write side: only the explicit end marker
      // ends the body, and arbitrary non-UTF-8 bytes are preserved exactly.
      binary.socket.add(_length(body.length));
      binary.socket.add(body);
      binary.socket.add(_length(0));
      await binary.socket.flush();
      final ack = await binary.read();
      expect(ack, {
        ...fixture.binding,
        'protocol_version': 'gaovm.binary.v1',
        'kind': 'committed',
        'artifact_id': guestId.value,
        'stream_id': _streamId,
        'size_bytes': body.length,
        'digest': 'sha256:${sha256.convert(body)}',
      });
      // A separate connection observes committed rows at the instant of ACK.
      // This is not a nested savepoint or an in-memory publication attestation.
      final observer = await GaoVmDatabase.open(fixture.databasePath);
      late Artifact hostArtifact;
      try {
        final recovered = fixture.service(database: observer);
        expect(
          await recovered.readExecSnapshot(
            fixture.operationId,
            fixture.attemptId,
          ),
          JsonObjectValue.fromJson(result),
        );
        final publicResult = (await recovered.readExecResult(
          fixture.operationId,
          fixture.attemptId,
        ))!.toJson();
        final hostId = ArtifactId(
          (publicResult['stdout'] as Map)['artifact_id'] as String,
        );
        expect(hostId, isNot(guestId));
        final artifact = (await ArtifactRepository(observer).get(hostId))!;
        expect(artifact.operationId, fixture.operationId);
        expect(artifact.vmId, fixture.vmId);
        final download = await recovered.artifacts.download(hostId);
        expect(await download.bytes.expand((chunk) => chunk).toList(), body);
        final created = (await SqliteEventRepository(
          observer,
        ).list()).where((event) => event.type == 'artifact.created');
        expect(created, hasLength(1));
        expect(
          await SqliteEventRepository(observer).readUnpublishedOutbox(),
          isNotEmpty,
        );
        final published = await publishing;
        hostArtifact = published.artifact;
        expect(published.artifact, artifact);
        expect(published.acknowledged, isTrue);
      } finally {
        observer.close();
      }
      await service.close();
      await connection.close();
      await _httpDownload(
        fixture,
        service.artifacts,
        hostArtifact,
        guestId,
        body,
      );
    },
  );
}

Future<TestRun> _oneInlineRun(
  _Fixture fixture,
  Map<String, Object?> stdout,
) async {
  final run = await fixture.runningTestRun(
    stepRequests: [
      TestStepRequest(argv: ['first'], timeoutSeconds: 30),
    ],
  );
  final runs = SqliteTestRunRepository(fixture.database);
  await runs.startStep(run.id, index: 0);
  await runs.finishStep(
    run.id,
    index: 0,
    state: TestStepState.succeeded,
    result: JsonObjectValue.fromJson({
      'state': 'succeeded',
      'exit_code': 0,
      'stdout': stdout,
      'stderr': {
        'mode': 'inline',
        'text': '',
        'size_bytes': 0,
        'truncated': false,
      },
      'duration_ms': 1,
      'timed_out': false,
      'signal': null,
    }),
  );
  return runs.transition(
    run.id,
    expectedState: TestRunState.runningSteps,
    nextState: TestRunState.collecting,
    outcome: TestRunState.succeeded,
  );
}

Future<TestRunCollectionWorker> _collector(
  _Fixture fixture,
  HostGuestArtifactService service,
) async {
  final path = await Directory('${fixture.root.path}/bundles').create();
  imageFileMode(path.path, 0x1c0);
  final bundles = await OwnedImageDirectory.open(path);
  addTearDown(bundles.close);
  final worker = TestRunCollectionWorker(
    database: fixture.database,
    bundles: bundles,
    artifacts: service.artifacts,
  );
  addTearDown(worker.close);
  return worker;
}

Map<String, Object?> _collectionDescriptor(
  ArtifactId id,
  List<int> body, {
  String streamId = _streamId,
  String kind = 'file',
}) => {
  'artifact_id': id.value,
  'kind': kind,
  'content_type': 'application/octet-stream',
  'size_bytes': body.length,
  'digest': 'sha256:${sha256.convert(body)}',
  'stream_id': streamId,
};

Future<GuestCollectionArtifactReceipt> _captureCollection(
  _Fixture fixture,
  HostGuestArtifactService service,
  GuestControlConnection connection,
  _Peer control,
  List<Map<String, Object?>> descriptors,
) async {
  final capturing = service.captureCollection(
    connection: connection,
    operationId: fixture.operationId,
    attemptId: fixture.attemptId,
    request: JsonObjectValue.fromJson({
      'paths': [
        for (var index = 0; index < descriptors.length; index++)
          {'path': 'diagnostic-$index', 'kind': descriptors[index]['kind']},
      ],
      'max_total_bytes': 8,
    }),
    deadline: _deadline(),
  );
  final call = await control.read();
  expect(call['method'], 'artifact.collect');
  await control.reply(call, {'artifacts': descriptors});
  return capturing;
}

Matcher _failure(GuestArtifactFailure code) =>
    isA<GuestArtifactException>().having((e) => e.code, 'failure', code);
Future<_Peer> _binary(_Fixture fixture) async {
  final peer = await fixture.accept('binary');
  expect(await peer.bytes(4), ascii.encode('GAB1'));
  await peer.read();
  return peer;
}

Future<GuestExecArtifactReceipt> _capture(
  _Fixture fixture,
  HostGuestArtifactService service,
  GuestControlConnection connection,
  _Peer control,
  Map<String, Object?> result, {
  GuestBridgeDeadline? deadline,
}) async {
  final capturing = service.captureExecStatus(
    connection: connection,
    operationId: fixture.operationId,
    attemptId: fixture.attemptId,
    request: _request,
    deadline: deadline ?? _deadline(),
  );
  final status = await control.read();
  expect(status['method'], 'exec.status');
  await control.reply(status, result);
  return capturing;
}

const _streamId =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _core = [
  'health',
  'system.info',
  'exec.start',
  'exec.status',
  'exec.cancel',
  'artifact.collect',
];
final _request = GuestExecRequest.fromJson({
  'argv': ['gaoos-test'],
  'cwd': '/',
  'env': <String, String>{},
  'timeout_seconds': 30,
  'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
});
GuestBridgeDeadline _deadline([Duration budget = const Duration(seconds: 5)]) =>
    GuestBridgeDeadline.after(budget);
Map<String, Object?> _result(ArtifactId id, int size) => {
  'state': 'succeeded',
  'exit_code': 0,
  'stdout': {'mode': 'artifact', 'artifact_id': id.value, 'size_bytes': size},
  'stderr': {'mode': 'inline', 'text': '', 'truncated': false, 'size_bytes': 0},
  'duration_ms': 10,
  'timed_out': false,
  'signal': null,
};
Map<String, Object?> _ready(_Fixture fixture, ArtifactId id, List<int> body) =>
    {
      ...fixture.binding,
      'protocol_version': 'gaovm.binary.v1',
      'kind': 'ready',
      'artifact': {
        'artifact_id': id.value,
        'kind': 'stdout',
        'content_type': 'application/octet-stream',
        'size_bytes': body.length,
        'digest': 'sha256:${sha256.convert(body)}',
        'stream_id': _streamId,
      },
    };
Uint8List _length(int length) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, length, Endian.big);

final class _Fixture implements GuestBridgeProvider {
  _Fixture(
    this.root,
    this.database,
    this.artifactRoot,
    this.layout,
    this.paths,
    this.listener,
    this.vmId,
    this.operationId,
    this.attemptId, {
    required bool ownsCatalog,
    required this.databasePath,
    this.rustGuest,
  }) : _ownsCatalog = ownsCatalog,
       accepted = listener == null ? null : StreamIterator(listener) {
    bridge = GuestBridgeClient(
      paths: paths,
      correlation: correlation,
      authToken: 'fixture-private-token',
      isSessionActive: () => driverActive,
      sessionClosed: driverClosed.future,
    );
    session = HostGuestSession(
      bridge: this,
      correlation: correlation,
      frameTimeout: const Duration(seconds: 2),
    );
  }
  final Directory root;
  GaoVmDatabase database;
  final OwnedImageDirectory artifactRoot;
  final DriverRuntimeLayout layout;
  final DriverRuntimePaths paths;
  final ServerSocket? listener;
  final StreamIterator<Socket>? accepted;
  final _RustGuest? rustGuest;
  final VmId vmId;
  final OperationId operationId;
  final RequestId attemptId;
  final bool _ownsCatalog;
  final String databasePath;
  final driverClosed = Completer<Object?>();
  late final GuestBridgeClient bridge;
  late final HostGuestSession session;
  final peers = <_Peer>[];
  final services = <HostGuestArtifactService>[];
  bool driverActive = true;
  bool allowFailedPublicationCleanup = false;
  final transferBudget = GuestArtifactBudget(
    maxTransfers: 2,
    maxReservedBytes: 256 * 1024 * 1024,
  );
  DriverCorrelation get correlation =>
      DriverCorrelation(vmId: vmId, driverGeneration: 8, operationId: null);
  Map<String, Object?> get binding => {
    'vm_id': vmId.value,
    'driver_generation': 8,
    'operation_id': operationId.value,
  };
  static Future<_Fixture> create({
    _Fixture? catalogOwner,
    String? rustFixture,
    GuestExecRequest Function(String)? requestForRoot,
  }) async {
    final root =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gva-');
    imageFileMode(root.path, 0x1c0);
    final databasePath =
        catalogOwner?.databasePath ?? '${root.path}/catalog.db';
    final database =
        catalogOwner?.database ?? await GaoVmDatabase.open(databasePath);
    final vm = await SqliteVmRepository(
      database,
    ).create(name: 'artifact-guest', spec: _spec);
    final vmId = vm.metadata.id;
    final state =
        VmControllerState.initial(
          vmId: vmId,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ).copyWith(
          phase: VmPhase.running,
          desiredState: DesiredState.running,
          observedGeneration: 1,
          driverGeneration: 8,
          activeDriverGeneration: 8,
          activeSpecGeneration: 1,
        );
    final persistence = SqliteVmStateEffectAdapter(database);
    await persistence.persistVm(state);
    await persistence.persistRuntime(state);
    await persistence.persistGuestReadiness(state, true);
    final operation = await SqliteOperationRepository(database).create(
      type: 'guest.exec',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.fromJson(
        (requestForRoot?.call(root.path) ?? _request).toJson(),
      ),
    );
    final attempt = RequestId.generate();
    // The original authenticated connection is captured before the start marker.
    await database.transaction(
      (db) => db.execute(
        '''
      INSERT INTO guest_exec_jobs(operation_id, vm_id, driver_generation,
        spec_generation, applied_intent_revision, created_at)
      VALUES (?, ?, 8, 1, 0, ?)
    ''',
        [
          operation.id.value,
          vmId.value,
          DateTime.now().toUtc().toIso8601String(),
        ],
      ),
    );
    final OwnedImageDirectory artifactRoot;
    if (catalogOwner == null) {
      final artifacts = await Directory('${root.path}/artifacts').create();
      imageFileMode(artifacts.path, 0x1c0);
      artifactRoot = await OwnedImageDirectory.open(artifacts);
    } else {
      artifactRoot = catalogOwner.artifactRoot;
    }
    final layout = DriverRuntimeLayout('${root.path}/run');
    final paths = await layout.create(
      DriverCorrelation(vmId: vmId, driverGeneration: 8, operationId: null),
    );
    final listener = rustFixture != null
        ? null
        : await ServerSocket.bind(
            InternetAddress(
              paths.guestSocketPath,
              type: InternetAddressType.unix,
            ),
            0,
          );
    final rustGuest = rustFixture == null
        ? null
        : await _RustGuest.start(rustFixture, paths.guestSocketPath, root);
    final protection = await Process.run('/bin/chmod', [
      '600',
      paths.guestSocketPath,
    ]);
    if (protection.exitCode != 0) throw StateError('fixture protection failed');
    return _Fixture(
      root,
      database,
      artifactRoot,
      layout,
      paths,
      listener,
      vmId,
      operation.id,
      attempt,
      ownsCatalog: catalogOwner == null,
      databasePath: databasePath,
      rustGuest: rustGuest,
    );
  }

  HostGuestArtifactService service({
    GaoVmDatabase? database,
    GuestArtifactBudget? budget,
    void Function(ArtifactPublicationCheckpoint, ArtifactId)? onCheckpoint,
  }) {
    final catalog = database ?? this.database;
    final service = HostGuestArtifactService(
      database: catalog,
      artifacts: ArtifactApplicationService(
        database: catalog,
        directory: artifactRoot,
        onCheckpoint: onCheckpoint,
      ),
      budget: budget ?? transferBudget,
    );
    services.add(service);
    return service;
  }

  @override
  Future<GuestBridgeChannel> openGuestChannel({
    required GuestBridgeStreamKind streamKind,
    required RequestId requestId,
    required OperationId? operationId,
    required GuestBridgeDeadline deadline,
  }) => bridge.openAndJoin(
    streamKind: streamKind,
    requestId: requestId,
    operationId: operationId,
    deadline: deadline,
  );
  Future<_Peer> accept(String streamKind) async {
    if (!await accepted!.moveNext())
      throw StateError('fixture listener closed');
    final peer = _Peer(accepted!.current);
    peers.add(peer);
    final opening = await peer.read();
    expect(opening['protocol_version'], 'gaovm.bridge.v1');
    expect(opening['auth_token'], 'fixture-private-token');
    expect(opening['stream_kind'], streamKind);
    await peer.send({...opening..remove('auth_token'), 'kind': 'ready'});
    return peer;
  }

  Future<(GuestControlConnection, _Peer)> ready({
    bool beginAttempt = true,
  }) async {
    final peerFuture = () async {
      final control = await accept('control');
      final hello = await control.read();
      await control.reply(hello, {'accepted_capabilities': _core});
      await control.send({
        ...hello,
        'id': 'guest-hello',
        'params': {
          'peer_role': 'guest',
          'offered_capabilities': _core,
          'required_capabilities': _core,
        },
      });
      await control.read();
      await control.reply(await control.read(), {
        'status': 'ok',
        'uptime_seconds': 1,
        'checks': {'dispatcher': 'ok'},
      });
      return control;
    }();
    final connection = await session.connect(deadline: _deadline());
    final jobs = SqliteGuestExecRepository(database);
    if (beginAttempt && (await jobs.get(operationId))!.startedAt == null) {
      await jobs.beginAttempt(
        operationId,
        attemptId: attemptId,
        controlEpochId: connection.epochId,
        executionState:
            VmControllerState.initial(
              vmId: vmId,
              specGeneration: 1,
              restartPolicy: RestartPolicy.never,
            ).copyWith(
              phase: VmPhase.running,
              desiredState: DesiredState.running,
              observedGeneration: 1,
              driverGeneration: 8,
              activeDriverGeneration: 8,
              activeSpecGeneration: 1,
            ),
        stillCurrent: () => connection.isReady,
      );
    }
    return (connection, await peerFuture);
  }

  VmController? _controller;
  int checkpoint = 0;
  Future<TestRun> runningTestRun({
    List<TestStepRequest>? stepRequests,
    num? timeoutSeconds = 300,
  }) async {
    await acceptance.cancel(
      OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: utf8.encode('{}'),
        operationId: operationId,
      ),
    );
    await SqliteGuestExecRepository(database).cancelBeforeStart(operationId);
    checkpoint = 1;
    await database.transaction((db) {
      db.execute('UPDATE vms SET intent_revision = 1 WHERE id = ?', [
        vmId.value,
      ]);
      db.execute(
        'UPDATE vm_runtime SET applied_intent_revision = 1 WHERE vm_id = ?',
        [vmId.value],
      );
    });
    final operations = SqliteOperationRepository(database);
    final start = await operations.createAndStart(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.fromJson({
        'intent_revision': 1,
        'spec_generation': 1,
      }),
    );
    await operations.succeed(start.id);
    final runs = SqliteTestRunRepository(database);
    final run = await runs.create(
      spec: TestRunSpec(
        source: ImageTestRunSource(ImageId.generate()),
        wait: VmWaitSpec(
          condition: WaitCondition.guestAgentReady,
          timeoutSeconds: 30,
        ),
        steps:
            stepRequests ??
            [
              for (final name in ['first', 'second'])
                TestStepRequest(argv: [name], timeoutSeconds: 30),
            ],
        cleanup: CleanupPolicy.retain,
        timeoutSeconds: timeoutSeconds,
        retainOnFailure: true,
      ),
      requestId: RequestId.generate(),
    );
    await runs.transition(
      run.id,
      expectedState: TestRunState.pending,
      nextState: TestRunState.provisioning,
    );
    await runs.transition(
      run.id,
      expectedState: TestRunState.provisioning,
      nextState: TestRunState.startingVm,
      vmId: vmId,
    );
    await database.transaction(
      (db) => db.execute(
        '''
      INSERT INTO test_run_vm_start(test_run_id, vm_id, operation_id, intent_revision, driver_generation)
      VALUES (?, ?, ?, 1, 8)
    ''',
        [run.id.value, vmId.value, start.id.value],
      ),
    );
    await runs.transition(
      run.id,
      expectedState: TestRunState.startingVm,
      nextState: TestRunState.waitingReady,
    );
    return runs.transition(
      run.id,
      expectedState: TestRunState.waitingReady,
      nextState: TestRunState.runningSteps,
    );
  }

  GuestExecApplicationService get acceptance => GuestExecApplicationService(
    database: database,
    resolveController: resolveController,
  );
  Future<VmController?> resolveController(VmId id) async {
    if (id != vmId) return null;
    return _controller ??= VmController(
      initialState:
          VmControllerState.initial(
            vmId: vmId,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            phase: VmPhase.running,
            desiredState: DesiredState.running,
            observedGeneration: 1,
            driverGeneration: 8,
            activeDriverGeneration: 8,
            activeSpecGeneration: 1,
            appliedIntentRevision: checkpoint,
          ),
      effectRunner: _VmHardwareBoundary(),
    );
  }

  Future<void> close() async {
    for (final service in services) {
      try {
        await service.close();
      } on ArtifactPublicationFailure {
        if (!allowFailedPublicationCleanup) rethrow;
      }
    }
    await session.close();
    await bridge.close();
    for (final peer in peers) {
      peer.socket.destroy();
      await peer.iterator.cancel();
    }
    await accepted?.cancel();
    await listener?.close();
    await rustGuest?.close();
    await layout.remove(paths);
    await _controller?.shutdown();
    if (_ownsCatalog) {
      artifactRoot.close();
      database.close();
    }
    await root.delete(recursive: true);
  }
}

Future<int> _watchGuestPid(Directory root) async {
  final events = StreamIterator(root.watch());
  final deadline = _deadline(const Duration(seconds: 15));
  final pidFile = File('${root.path}/exec.pid');
  try {
    while (true) {
      deadline.requireLive();
      if (!await events.moveNext().timeout(deadline.remaining))
        throw StateError('guest PID watch ended');
      if (events.current.path != pidFile.path) continue;
      try {
        final text = await pidFile.readAsString();
        if (RegExp(r'^[1-9][0-9]*$').hasMatch(text)) return int.parse(text);
      } on FileSystemException {
        // A create notification can precede the completed write.
      }
    }
  } finally {
    await events.cancel();
  }
}

Future<GuestControlConnection> _connectRustGuest(_Fixture fixture) async {
  final connection = await fixture.session.connect(
    deadline: _deadline(const Duration(seconds: 15)),
  );
  expect(connection.isReady, isTrue);
  expect(
    await SqliteGuestExecRepository(fixture.database).beginAttempt(
      fixture.operationId,
      attemptId: fixture.attemptId,
      controlEpochId: connection.epochId,
      executionState:
          VmControllerState.initial(
            vmId: fixture.vmId,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            phase: VmPhase.running,
            desiredState: DesiredState.running,
            observedGeneration: 1,
            driverGeneration: 8,
            activeDriverGeneration: 8,
            activeSpecGeneration: 1,
          ),
      stillCurrent: () => connection.isReady,
    ),
    isNotNull,
  );
  return connection;
}

Future<void> _expectRustGrantRetired(
  _Fixture fixture,
  GuestControlConnection connection,
  ArtifactId guestId,
  String output,
) async {
  final deadline = _deadline();
  while (true) {
    deadline.requireLive();
    expect(connection.isActive, isTrue);
    final channel = await fixture.openGuestChannel(
      streamKind: GuestBridgeStreamKind.binary,
      requestId: RequestId.generate(),
      operationId: fixture.operationId,
      deadline: deadline,
    );
    try {
      final open = utf8.encode(
        jsonEncode({
          ...fixture.binding,
          'protocol_version': 'gaovm.binary.v1',
          'kind': 'open',
          'artifact_id': guestId.value,
          'source': {'kind': 'exec_output', 'output': output},
        }),
      );
      await channel.write(
        Uint8List.fromList([
          ...ascii.encode('GAB1'),
          ..._length(open.length),
          ...open,
        ]),
        deadline: deadline,
      );
      Uint8List prefix;
      try {
        prefix = await channel.readExact(4, deadline: deadline);
      } on GuestBridgeException catch (error) {
        // No fresh status/grant was requested. A fully matched retired grant
        // closes silently; a pending ACK can only yield a bounded busy error.
        expect(
          error.code,
          anyOf(GuestBridgeFailure.closed, GuestBridgeFailure.transportFailure),
        );
        return;
      }
      final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
      expect(length, inInclusiveRange(1, 4096));
      final reply =
          jsonDecode(
                utf8.decode(
                  await channel.readExact(length, deadline: deadline),
                ),
              )
              as Map;
      expect(reply['kind'], 'error');
      expect((reply['error'] as Map)['code'], 'ARTIFACT_LIMIT_EXCEEDED');
    } finally {
      await channel.close();
    }
  }
}

final class _RustGuest {
  _RustGuest(this.process)
    : stderr = process.stderr.transform(utf8.decoder).join() {
    exitCode = process.exitCode.then((code) {
      exited = true;
      return code;
    });
  }
  final Process process;
  final Future<String> stderr;
  late final Future<int> exitCode;
  bool exited = false;
  Future<void>? stdoutDone;
  static Future<_RustGuest> start(
    String executable,
    String socket,
    Directory root,
  ) async {
    if (!executable.startsWith('/') || !await File(executable).exists()) {
      throw ArgumentError(
        'GAOVM_GUEST_FIXTURE must name a built absolute fixture executable',
      );
    }
    final source = await Directory('${root.path}/guest-source').create();
    final spool = await Directory('${root.path}/guest-spool').create();
    imageFileMode(source.path, 0x1c0);
    imageFileMode(spool.path, 0x1c0);
    final owned = _RustGuest(
      await Process.start(
        executable,
        [socket, source.path, spool.path],
        environment: {'GAOVM_GUEST_FIXTURE_TOKEN': 'fixture-private-token'},
      ),
    );
    final lines = StreamIterator(
      owned.process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    bool ready;
    try {
      ready =
          await lines.moveNext().timeout(const Duration(seconds: 10)) &&
          lines.current == 'ready';
    } catch (_) {
      await owned.close();
      rethrow;
    }
    if (!ready) {
      await owned.close();
      throw StateError('Rust fixture failed before listening');
    }
    owned.stdoutDone = () async {
      while (await lines.moveNext()) {}
    }();
    return owned;
  }

  Future<void> close() async {
    if (!exited) process.kill(ProcessSignal.sigterm);
    final code = await exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () async {
        if (!exited) process.kill(ProcessSignal.sigkill);
        return exitCode;
      },
    );
    await stdoutDone;
    expect(code, 0, reason: await stderr);
  }
}

final class _VmHardwareBoundary implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      switch (effect) {
        ShutdownDriver(:final driverGeneration, :final operationId) =>
          ControllerDriverShutdownSucceeded(driverGeneration!, operationId!),
        ShutdownLease() => const ControllerLeaseShutdownSucceeded(),
        _ => null,
      };
}

final class _Peer {
  _Peer(this.socket) : iterator = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> iterator;
  final pending = <int>[];
  Future<Uint8List> bytes(int count) async {
    while (pending.length < count) {
      if (!await iterator.moveNext()) throw StateError('fixture EOF');
      pending.addAll(iterator.current);
    }
    final bytes = Uint8List.fromList(pending.take(count).toList());
    pending.removeRange(0, count);
    return bytes;
  }

  Future<Map<String, Object?>> read() async {
    final length = ByteData.sublistView(
      await bytes(4),
    ).getUint32(0, Endian.big);
    return Map<String, Object?>.from(
      jsonDecode(utf8.decode(await bytes(length))) as Map,
    );
  }

  Future<void> send(Map<String, Object?> value) async {
    await sendRaw(jsonEncode(value));
  }

  Future<void> sendRaw(String raw) async {
    final data = utf8.encode(raw);
    socket.add(_length(data.length));
    socket.add(data);
    await socket.flush();
  }

  Future<void> reply(Map<String, Object?> call, Map<String, Object?> result) =>
      send({...call..remove('params'), 'kind': 'response', 'result': result});
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: true, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

Future<void> _httpDownload(
  _Fixture fixture,
  ArtifactApplicationService artifacts,
  Artifact artifact,
  ArtifactId guestId,
  List<int> body,
) async {
  final router = PublicApiRouter();
  ArtifactApiHandlers(artifacts: artifacts).register(router);
  final logger = RotatingLogger(path: '${fixture.root.path}/daemon.log');
  final server = PublicApiServer(
    socketPath: '${fixture.root.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
    logger: logger,
  );
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(server.socketPath, type: InternetAddressType.unix),
      0,
    );
  try {
    await server.start();
    final response = await (await client.getUrl(
      Uri.parse('http://localhost${artifact.downloadUrl}'),
    )).close();
    expect(response.statusCode, 200);
    expect(response.contentLength, body.length);
    expect(
      response.headers.value('digest'),
      'sha-256=${base64.encode(sha256.convert(body).bytes)}',
    );
    expect(
      () => RequestId(response.headers.value('x-request-id')!),
      returnsNormally,
    );
    expect(await response.expand((chunk) => chunk).toList(), body);
    final privateId = await (await client.getUrl(
      Uri.parse('http://localhost/v1/artifacts/${guestId.value}'),
    )).close();
    expect(privateId.statusCode, 404);
    await privateId.drain<void>();
  } finally {
    client.close(force: true);
    await server.close();
    await logger.flush();
  }
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}

final class _ExecApi {
  _ExecApi(this.server, this.logger, this.registry) {
    client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(server.socketPath, type: InternetAddressType.unix),
        0,
      );
  }
  final PublicApiServer server;
  final RotatingLogger logger;
  final VmRegistry registry;
  late final HttpClient client;
  static Future<_ExecApi> open(
    _Fixture fixture,
    GuestExecApplicationService guestExec,
    ArtifactApplicationService artifacts,
  ) async {
    final catalog = SqliteVmRepository(fixture.database);
    final operations = SqliteOperationRepository(fixture.database);
    final registry = VmRegistry(
      repository: catalog,
      operations: operations,
      effectRunner: _VmHardwareBoundary(),
    );
    final feed = SqliteDurableEventFeed(fixture.database);
    final router = PublicApiRouter();
    ResourceApiHandlers(
      vms: VmApplicationService.composed(
        repository: catalog,
        creates: SqliteVmCreateAcceptance(
          database: fixture.database,
          idempotencyRetention: const Duration(days: 1),
        ),
        patches: SqliteVmPatchAcceptor(
          database: fixture.database,
          registry: registry,
          idempotencyRetention: const Duration(days: 1),
        ),
        lifecycle: SqliteVmLifecycleAcceptor(
          database: fixture.database,
          registry: registry,
          idempotencyRetention: const Duration(days: 1),
        ),
        waiter: SqliteVmConditionWaiter(repository: catalog, events: feed),
      ),
      operations: OperationApplicationService(
        repository: operations,
        mutations: guestExec,
        waiter: SqliteOperationWaiter(operations: operations, events: feed),
      ),
      guestExec: guestExec,
    ).register(router);
    ArtifactApiHandlers(artifacts: artifacts).register(router);
    TestRunApiHandlers(
      runs: TestRunApplicationService(database: fixture.database),
    ).register(router);
    final logger = RotatingLogger(path: '${fixture.root.path}/exec-api.log');
    final server = PublicApiServer(
      socketPath: '${fixture.root.path}/exec-api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
      logger: logger,
    );
    await server.start();
    return _ExecApi(server, logger, registry);
  }

  Future<({int status, Map<String, Object?> json, String? location})> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? key,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) request.headers.set('Idempotency-Key', key);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final json = Map<String, Object?>.from(
      jsonDecode(await response.transform(utf8.decoder).join()) as Map,
    );
    return (
      status: response.statusCode,
      json: json,
      location: response.headers.value('location'),
    );
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close();
    await registry.shutdown();
    await logger.flush();
  }
}
