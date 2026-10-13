import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'artifact_application_service.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';

// Matches the TestRun application's fixed capture threshold. Invalid UTF-8
// bytes use the guest's binary spill, never a lossy inline representation.
const _maxInlineBytes = 64 * 1024;

/// Publishes already durable step output only. Never resolves or calls a guest.
final class TestRunStepArtifactCollector {
  TestRunStepArtifactCollector({
    required this.database,
    required this.artifacts,
  });
  final GaoVmDatabase database;
  final ArtifactApplicationService artifacts;

  Future<JsonObjectValue> collect({
    required TestRun run,
    required JsonObjectValue snapshot,
    required DateTime retentionUntil,
    required bool Function() isActive,
  }) async {
    final execution = snapshot.toJson()['execution'] as Map;
    final steps = execution['steps'] as List;
    await database.transaction((db) async {
      _check(db, run, isActive);
      for (var index = 0; index < steps.length; index++) {
        final step = steps[index] as Map;
        final result = step['result'] as Map?;
        final child =
            db.select(
                  'SELECT operation_id FROM test_run_step_execs WHERE test_run_id = ? AND step_index = ?',
                  [run.id.value, index],
                ).singleOrNull?['operation_id']
                as String?;
        for (final output in ['stdout', 'stderr']) {
          if (db.select(
            'SELECT 1 FROM test_run_step_artifacts WHERE test_run_id = ? AND step_index = ? AND kind = ?',
            [run.id.value, index, output],
          ).isNotEmpty)
            continue;
          JsonObjectValue? source;
          OperationError? error;
          if (result?[output] != null) {
            try {
              source = _source(result![output]);
            } on FormatException {
              error = _error(run, index, output, 'invalid_source');
              await SqliteTestRunRepository(
                database,
              ).recordFailure(run.id, error: error);
            }
          }
          db.execute(
            '''
            INSERT INTO test_run_step_artifacts(test_run_id, step_index, kind, artifact_id,
              source_operation_id, source_json, state, error_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ''',
            [
              run.id.value,
              index,
              output,
              ArtifactId.generate().value,
              child,
              source == null ? null : jsonEncode(source.toJson()),
              error != null
                  ? 'failed'
                  : source == null
                  ? 'absent'
                  : 'pending',
              error == null ? null : jsonEncode(error.toJson()),
            ],
          );
        }
      }
    });
    for (final slot in await _slots(run.id)) {
      if (!isActive()) throw StateError('step artifact collector is closed');
      if (slot.state == 'pending') {
        final source = slot.source!.toJson();
        if (source['mode'] == 'artifact') {
          late Artifact original;
          try {
            original = (await artifacts.download(
              ArtifactId(source['artifact_id'] as String),
            )).artifact;
            _ownership(original, run, slot, requireChild: true);
            if (original.sizeBytes != source['size_bytes'])
              throw const FormatException('step artifact size differs');
          } catch (error) {
            if (error is! ArtifactNotFoundException &&
                error is! ArtifactContentUnavailable &&
                error is! FormatException)
              rethrow;
            await database.transaction((db) async {
              _check(db, run, isActive);
              final failure = _error(
                run,
                slot.index,
                slot.output,
                'original_artifact_unavailable',
              );
              await SqliteTestRunRepository(
                database,
              ).recordFailure(run.id, error: failure);
              db.execute(
                "UPDATE test_run_step_artifacts SET state = 'failed', error_json = ? WHERE test_run_id = ? AND step_index = ? AND kind = ? AND state = 'pending'",
                [
                  jsonEncode(failure.toJson()),
                  run.id.value,
                  slot.index,
                  slot.output,
                ],
              );
            });
            continue;
          }
          await database.transaction((db) {
            _check(db, run, isActive);
            _published(db, run, slot, original.id);
          });
        } else {
          final bytes = utf8.encode(source['text'] as String);
          await artifacts.publish(
            artifactId: slot.reservedId,
            bytes: Stream.value(bytes),
            kind: slot.kind,
            contentType: 'text/plain; charset=utf-8',
            maxBytes: _maxInlineBytes,
            expectedSizeBytes: bytes.length,
            expectedDigest: 'sha256:${sha256.convert(bytes)}',
            vmId: run.vmId,
            operationId: slot.operationId ?? run.operationId,
            testRunId: run.id,
            retentionUntil: retentionUntil,
            commitReferences: (artifact) => database.read((db) {
              _check(db, run, isActive);
              _published(db, run, slot, artifact.id);
            }),
          );
          // A previously committed reservation does not rerun commitReferences.
          await database.transaction((db) {
            _check(db, run, isActive);
            _published(db, run, slot, slot.reservedId);
          });
        }
      }
    }
    final slots = await _slots(run.id);
    final hostArtifacts = await _verify(run, slots, isActive);
    final projectedSteps = <Object?>[];
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index] as Map;
      final result = step['result'] as Map?;
      projectedSteps.add({
        ...step,
        if (result != null)
          'result': {
            ...result,
            for (final output in ['stdout', 'stderr'])
              if (result.containsKey(output))
                output: switch (hostArtifacts['$index/$output']) {
                  final artifact? => {
                    'mode': 'artifact',
                    'artifact_id': artifact.id.value,
                    'size_bytes': artifact.sizeBytes,
                  },
                  null => {'mode': 'unavailable'},
                },
          },
      });
    }
    return JsonObjectValue.fromJson({
      'execution': {...execution, 'steps': projectedSteps},
      'step_artifacts': [
        for (final slot in slots)
          {
            'step_index': slot.index,
            'kind': slot.output,
            'state': slot.state,
            'artifact_id': slot.hostId?.value,
            if (slot.source?.toJson()['mode'] == 'inline') 'encoding': 'utf-8',
            if (slot.source?.toJson()['mode'] == 'inline')
              'source_size_bytes': slot.source!.toJson()['size_bytes'],
            if (slot.source?.toJson()['mode'] == 'inline')
              'truncated': slot.source!.toJson()['truncated'],
            if (slot.error != null) 'error': slot.error!.toJson(),
          },
      ],
    });
  }

  /// Repeat immediately before declaring overall collection complete, after
  /// other payloads/report publication may have awaited filesystem work.
  Future<void> verify(TestRun run, {required bool Function() isActive}) async {
    await _verify(run, await _slots(run.id), isActive);
  }

  Future<Map<String, Artifact>> _verify(
    TestRun run,
    List<_Slot> slots,
    bool Function() isActive,
  ) async {
    await database.read((db) => _check(db, run, isActive));
    final verified = <String, Artifact>{};
    for (final slot in slots) {
      if (!isActive() || slot.state == 'pending')
        throw StateError('step artifact verification is unfinished');
      if (slot.state != 'published') continue;
      final source = slot.source!.toJson();
      final artifact = (await artifacts.download(slot.hostId!)).artifact;
      _ownership(
        artifact,
        run,
        slot,
        requireChild: source['mode'] == 'artifact',
      );
      if (artifact.sizeBytes != source['size_bytes'] ||
          (source['mode'] == 'inline' &&
              artifact.digest !=
                  'sha256:${sha256.convert(utf8.encode(source['text'] as String))}'))
        throw ArtifactContentUnavailable(artifact.id);
      verified['${slot.index}/${slot.output}'] = artifact;
    }
    return verified;
  }

  Future<List<_Slot>> _slots(TestRunId id) => database.read(
    (db) => [
      for (final row in db.select(
        'SELECT * FROM test_run_step_artifacts WHERE test_run_id = ? ORDER BY step_index, kind DESC',
        [id.value],
      ))
        _Slot(
          row['step_index'] as int,
          row['kind'] as String,
          ArtifactId(row['artifact_id'] as String),
          row['source_operation_id'] == null
              ? null
              : OperationId(row['source_operation_id'] as String),
          row['source_json'] == null
              ? null
              : JsonObjectValue.fromJson(
                  jsonDecode(row['source_json'] as String),
                ),
          row['state'] as String,
          row['host_artifact_id'] == null
              ? null
              : ArtifactId(row['host_artifact_id'] as String),
          row['error_json'] == null
              ? null
              : OperationError.fromJson(
                  jsonDecode(row['error_json'] as String),
                ),
        ),
    ],
  );

  void _published(Database db, TestRun run, _Slot slot, ArtifactId id) {
    final state = db.select(
      'SELECT state, host_artifact_id FROM test_run_step_artifacts WHERE test_run_id = ? AND step_index = ? AND kind = ?',
      [run.id.value, slot.index, slot.output],
    ).single;
    if (state['state'] == 'published' && state['host_artifact_id'] == id.value)
      return;
    if (state['state'] != 'pending')
      throw StateError('step artifact slot changed');
    db.execute(
      "UPDATE test_run_step_artifacts SET state = 'published', host_artifact_id = ? WHERE test_run_id = ? AND step_index = ? AND kind = ?",
      [id.value, run.id.value, slot.index, slot.output],
    );
  }

  void _ownership(
    Artifact artifact,
    TestRun run,
    _Slot slot, {
    required bool requireChild,
  }) {
    if (artifact.testRunId != run.id ||
        artifact.vmId != run.vmId ||
        artifact.kind != slot.kind ||
        (requireChild && slot.operationId == null) ||
        artifact.operationId != (slot.operationId ?? run.operationId))
      throw const FormatException('step artifact original ownership differs');
  }

  void _check(Database db, TestRun run, bool Function() isActive) {
    if (!isActive() ||
        db
            .select(
              '''
      SELECT 1 FROM test_runs t JOIN operations o ON o.id = t.operation_id
      WHERE t.id = ? AND t.state = 'collecting' AND o.id = ? AND o.state = 'running' AND o.type = 'test.run'
    ''',
              [run.id.value, run.operationId.value],
            )
            .isEmpty)
      throw StateError('TestRun left step artifact collection');
  }

  OperationError _error(TestRun run, int index, String output, String reason) =>
      OperationError(
        code: ErrorCode.internalError,
        message: 'Unable to collect an original TestRun step output.',
        retryable: false,
        details: JsonObjectValue.fromJson({
          'phase': 'collecting',
          'step_index': index,
          'source': output,
          'reason': reason,
          'vm_id': run.vmId?.value,
        }),
      );
}

JsonObjectValue _source(Object? value) {
  if (value is! Map<String, Object?>)
    throw const FormatException('invalid step output');
  final keys = value['mode'] == 'inline'
      ? {'mode', 'text', 'size_bytes', 'truncated'}
      : {'mode', 'artifact_id', 'size_bytes'};
  final size = value['size_bytes'];
  if (value.length != keys.length ||
      !value.keys.every(keys.contains) ||
      size is! int ||
      size < 0 ||
      size > 16 * 1024 * 1024)
    throw const FormatException('invalid step output');
  if (value['mode'] == 'inline') {
    final text = value['text'];
    if (text is! String ||
        size > _maxInlineBytes ||
        text.length > size ||
        value['truncated'] is! bool)
      throw const FormatException('invalid inline step output');
    final bytes = utf8.encode(text);
    if (bytes.length != size || utf8.decode(bytes) != text)
      throw const FormatException('invalid inline step output');
  } else if (value['mode'] == 'artifact') {
    try {
      ArtifactId(value['artifact_id'] as String);
    } catch (_) {
      throw const FormatException('invalid step artifact');
    }
  } else {
    throw const FormatException('invalid step output mode');
  }
  return JsonObjectValue.fromJson(value);
}

final class _Slot {
  const _Slot(
    this.index,
    this.output,
    this.reservedId,
    this.operationId,
    this.source,
    this.state,
    this.hostId,
    this.error,
  );
  final int index;
  final String output;
  final ArtifactId reservedId;
  final OperationId? operationId;
  final JsonObjectValue? source;
  final String state;
  final ArtifactId? hostId;
  final OperationError? error;
  ArtifactKind get kind =>
      output == 'stdout' ? ArtifactKind.stdout : ArtifactKind.stderr;
}
