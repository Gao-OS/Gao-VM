import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'artifact_application_service.dart';
import 'guest_bridge_client.dart';
import 'guest_exec_request.dart';
import 'guest_exec_repository.dart';
import 'guest_wire_json.dart';
import 'host_guest_session.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

enum GuestArtifactFailure {
  invalidMessage,
  limitExceeded,
  superseded,
  notTerminal,
  publicationConflict,
}

final class GuestArtifactException implements Exception {
  const GuestArtifactException(this.code);
  final GuestArtifactFailure code;
  @override
  String toString() => 'guest artifact failed: ${code.name}';
}

/// A correlated pre-body error from the original authorized binary peer. Fixed
/// diagnostics are validated but never echoed into host logs or public errors.
final class GuestBinaryRemoteException implements Exception {
  const GuestBinaryRemoteException(this.code, this.retryable);
  final String code;
  final bool retryable;
}

/// Inject one process-owned budget, shared across all VMs/services. There is no
/// unbounded waiter queue and no implicit host retention/GC policy.
final class GuestArtifactBudget {
  GuestArtifactBudget({
    required this.maxTransfers,
    required this.maxReservedBytes,
  }) {
    if (maxTransfers < 1 || maxReservedBytes < 0)
      throw ArgumentError('invalid artifact budget');
  }
  final int maxTransfers;
  final int maxReservedBytes;
  int _reservedBytes = 0;
  final Map<VmId, int> _active = {};
  final Set<String> _sources = {};

  void _acquire(VmId vmId, int bytes, String source) {
    if (_sources.contains(source) ||
        _active.values.fold(0, (a, b) => a + b) >= maxTransfers ||
        (_active[vmId] ?? 0) >= 2 ||
        bytes > maxReservedBytes - _reservedBytes) {
      throw const GuestArtifactException(GuestArtifactFailure.limitExceeded);
    }
    _active[vmId] = (_active[vmId] ?? 0) + 1;
    _sources.add(source);
    _reservedBytes += bytes;
  }

  void _release(
    VmId vmId,
    int bytes,
    String source, {
    required bool quarantine,
  }) {
    _sources.remove(source);
    final count = _active[vmId]!;
    if (count == 1) {
      _active.remove(vmId);
    } else {
      _active[vmId] = count - 1;
    }
    // Unconfirmed stage cleanup must not silently return its disk reservation.
    if (!quarantine) _reservedBytes -= bytes;
  }
}

/// Private, original authenticated source proof shared by both binary families.
sealed class _ArtifactReceipt {
  _ArtifactReceipt(
    this.service,
    this.connection,
    this.operationId,
    this.attemptId,
    this.receiptId,
    this.result,
    this.deadline,
  );
  final HostGuestArtifactService service;
  final GuestControlConnection connection;
  final OperationId operationId;
  final RequestId? attemptId;
  final RequestId receiptId;
  final JsonObjectValue result;
  final GuestBridgeDeadline deadline;
  VmId get vmId => connection.correlation.vmId;
  int get generation => connection.correlation.driverGeneration;
}

/// Both sibling exec references commit before any binary ACK.
final class GuestExecArtifactReceipt extends _ArtifactReceipt {
  GuestExecArtifactReceipt._(
    super.service,
    super.connection,
    super.operationId,
    super.attemptId,
    super.receiptId,
    super.result,
    super.deadline,
  );
  @override
  RequestId get attemptId => super.attemptId!;
}

/// The complete collection reply is durable before any sealed source is read.
/// This receipt cannot be constructed from a caller-supplied descriptor.
final class GuestCollectionArtifactReceipt extends _ArtifactReceipt {
  GuestCollectionArtifactReceipt._(
    super.service,
    super.connection,
    super.operationId,
    super.attemptId,
    super.receiptId,
    super.result,
    super.deadline,
  );
}

final class GuestArtifactPublication {
  const GuestArtifactPublication(this.artifact, {required this.acknowledged});
  final Artifact artifact;
  final bool acknowledged;
}

/// One original operation's host-side library composition, not a public
/// driver passthrough. Share the process-owned budget, not an attempt owner.
/// Durable operations remain authoritative; this service never sends exec.start.
final class HostGuestArtifactService {
  HostGuestArtifactService({
    required this.database,
    required this.artifacts,
    required this.budget,
  }) {
    if (!identical(database, artifacts.database))
      throw ArgumentError('artifact catalog differs');
  }
  final GaoVmDatabase database;
  final ArtifactApplicationService artifacts;
  final GuestArtifactBudget budget;
  final Set<_Transfer> _transfers = {};
  final Set<Future<void>> _captures = {};
  final Map<GuestControlConnection, int> _rpcs = {};
  (GuestControlConnection, OperationId, RequestId?, GuestBridgeDeadline)?
  _owner;
  JsonObjectValue? _collectionRequest;
  Future<GuestCollectionArtifactReceipt>? _collectionCapture;
  Future<JsonObjectValue>? _systemInfoCapture;
  bool _closed = false;
  ArtifactPublicationFailure? _cleanupFailure;
  Future<void>? _closeFuture;

  Future<GuestExecArtifactReceipt> captureExecStatus({
    required GuestControlConnection connection,
    required OperationId operationId,
    required RequestId attemptId,
    required GuestExecRequest request,
    required GuestBridgeDeadline deadline,
    Duration? responseTimeout,
  }) => _trackCapture(
    _captureExecStatus(
      connection: connection,
      operationId: operationId,
      attemptId: attemptId,
      request: request,
      deadline: deadline,
      responseTimeout: responseTimeout,
    ),
  );

  Future<GuestExecArtifactReceipt> _captureExecStatus({
    required GuestControlConnection connection,
    required OperationId operationId,
    required RequestId attemptId,
    required GuestExecRequest request,
    required GuestBridgeDeadline deadline,
    Duration? responseTimeout,
  }) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('guest receipt must own its commit');
    void live() {
      deadline.requireLive();
      if (_closed || !connection.isActive)
        throw const GuestArtifactException(GuestArtifactFailure.superseded);
    }

    live();
    await database.read((db) {
      _checkJob(db, connection, operationId, attemptId);
      final stored = JsonObjectValue.fromJson(
        jsonDecode(
          db.select('SELECT request_json FROM operations WHERE id = ?', [
                operationId.value,
              ]).single['request_json']
              as String,
        ),
      );
      if (stored != JsonObjectValue.fromJson(request.toJson()))
        throw ArgumentError('exec capture differs from durable request');
      final rows = db.select(
        "SELECT control_epoch_id FROM guest_artifact_receipts WHERE operation_id = ? AND source_kind = 'exec'",
        [operationId.value],
      );
      if (rows.isNotEmpty &&
          rows.single['control_epoch_id'] != connection.epochId.value) {
        throw const GuestArtifactException(GuestArtifactFailure.superseded);
      }
    });
    final original = _owner ??= (connection, operationId, attemptId, deadline);
    if (!identical(original.$1, connection) ||
        original.$2 != operationId ||
        original.$3 != attemptId) {
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    }
    deadline = original.$4.capped(deadline.remaining);
    live();
    final result = await _rpc(
      connection,
      () => connection.execStatus(
        operationId: operationId,
        request: request,
        deadline: responseTimeout == null
            ? deadline
            : deadline.capped(responseTimeout),
      ),
    );
    final json = result.toJson();
    if (!const {'succeeded', 'failed', 'cancelled'}.contains(json['state'])) {
      throw const GuestArtifactException(GuestArtifactFailure.notTerminal);
    }
    final ids = <Object?>{};
    for (final output in ['stdout', 'stderr']) {
      final ref = json[output] as Map;
      if (ref['mode'] == 'artifact' && !ids.add(ref['artifact_id'])) _invalid();
    }
    final encoded = jsonEncode(json);
    final receiptId = await database.transaction((db) {
      live();
      _checkJob(db, connection, operationId, attemptId);
      final existing = db.select(
        "SELECT * FROM guest_artifact_receipts WHERE operation_id = ? AND source_kind = 'exec'",
        [operationId.value],
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['vm_id'] != connection.correlation.vmId.value ||
            row['driver_generation'] !=
                connection.correlation.driverGeneration ||
            row['control_epoch_id'] != connection.epochId.value ||
            row['attempt_id'] != attemptId.value ||
            row['result_json'] != encoded) {
          throw const GuestArtifactException(
            GuestArtifactFailure.publicationConflict,
          );
        }
        return RequestId(row['id'] as String);
      }
      final id = RequestId.generate();
      db.execute(
        '''
        INSERT INTO guest_artifact_receipts(id, vm_id, driver_generation, operation_id,
          attempt_id, source_kind, control_epoch_id, result_json, created_at) VALUES (?, ?, ?, ?, ?, 'exec', ?, ?, ?)
      ''',
        [
          id.value,
          connection.correlation.vmId.value,
          connection.correlation.driverGeneration,
          operationId.value,
          attemptId.value,
          connection.epochId.value,
          encoded,
          formatPersistenceTimestamp(DateTime.now()),
        ],
      );
      live();
      return id;
    });
    live();
    return GuestExecArtifactReceipt._(
      this,
      connection,
      operationId,
      attemptId,
      receiptId,
      result,
      deadline,
    );
  }

  Future<JsonObjectValue?> readExecSnapshot(
    OperationId id,
    RequestId attemptId,
  ) => SqliteGuestExecRepository(database).readTerminalSnapshot(id, attemptId);

  /// A missing mapping is incomplete, not permission to expose the guest ID or
  /// replay exec.start. Recovery can separately inspect the original snapshot.
  Future<JsonObjectValue?> readExecResult(
    OperationId id,
    RequestId attemptId,
  ) => SqliteGuestExecRepository(database).readTerminalResult(id, attemptId);

  Future<GuestCollectionArtifactReceipt> captureCollection({
    required GuestControlConnection connection,
    required OperationId operationId,
    RequestId? attemptId,
    required JsonObjectValue request,
    required GuestBridgeDeadline deadline,
  }) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('guest collection must own its commit');
    final validated = validateGuestArtifactCollectRequest(request);
    deadline.requireLive();
    if (_closed || !connection.isActive)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    final original = _owner ??= (connection, operationId, attemptId, deadline);
    if (!identical(original.$1, connection) ||
        original.$2 != operationId ||
        original.$3 != attemptId ||
        (_collectionRequest != null && _collectionRequest != validated))
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    _collectionRequest = validated;
    original.$4.requireLive();
    return _collectionCapture ??= _trackCapture(
      _captureCollection(
        connection,
        operationId,
        attemptId,
        validated,
        original.$4.capped(deadline.remaining),
      ),
    );
  }

  Future<T> _trackCapture<T>(Future<T> future) {
    final done = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _captures.add(done);
    unawaited(done.then((_) => _captures.remove(done)));
    return future;
  }

  Future<T> _rpc<T>(
    GuestControlConnection connection,
    Future<T> Function() call,
  ) async {
    if (_closed)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    _rpcs[connection] = (_rpcs[connection] ?? 0) + 1;
    try {
      return await call();
    } finally {
      final count = _rpcs[connection]!;
      if (count == 1) {
        _rpcs.remove(connection);
      } else {
        _rpcs[connection] = count - 1;
      }
    }
  }

  Future<JsonObjectValue> captureSystemInfo({
    required GuestControlConnection connection,
    required OperationId operationId,
    RequestId? attemptId,
    required GuestBridgeDeadline deadline,
  }) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('guest diagnostic must own its commit');
    deadline.requireLive();
    if (_closed || !connection.isActive)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    final original = _owner ??= (connection, operationId, attemptId, deadline);
    if (!identical(original.$1, connection) ||
        original.$2 != operationId ||
        original.$3 != attemptId)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    original.$4.requireLive();
    return _systemInfoCapture ??= _trackCapture(
      _captureSystemInfo(
        connection,
        operationId,
        attemptId,
        original.$4.capped(deadline.remaining),
      ),
    );
  }

  Future<JsonObjectValue> _captureSystemInfo(
    GuestControlConnection connection,
    OperationId operationId,
    RequestId? sourceAttemptId,
    GuestBridgeDeadline deadline,
  ) async {
    void live() {
      deadline.requireLive();
      if (_closed || !connection.isActive)
        throw const GuestArtifactException(GuestArtifactFailure.superseded);
    }

    final diagnosticId = await _claimDiagnostic(
      connection,
      operationId,
      sourceAttemptId,
      'system.info',
      JsonObjectValue.empty,
      deadline,
      live,
    );
    try {
      live();
      final result = await _rpc(
        connection,
        () =>
            connection.systemInfo(operationId: operationId, deadline: deadline),
      );
      await database.transaction((db) {
        live();
        _checkSource(db, connection, operationId, sourceAttemptId);
        db.execute(
          '''
          UPDATE guest_diagnostic_attempts SET result_json = ?, completed_at = ?
          WHERE operation_id = ? AND method = 'system.info' AND attempt_id = ? AND completed_at IS NULL
        ''',
          [
            jsonEncode(result.toJson()),
            formatPersistenceTimestamp(DateTime.now()),
            operationId.value,
            diagnosticId.value,
          ],
        );
        if (db.updatedRows != 1)
          throw const GuestArtifactException(GuestArtifactFailure.superseded);
        live();
      });
      live();
      return result;
    } catch (error) {
      await _failDiagnostic(operationId, 'system.info', diagnosticId, error);
      rethrow;
    }
  }

  Future<JsonObjectValue?> readSystemInfoResult(
    OperationId id,
  ) => database.read((db) {
    final rows = db.select(
      "SELECT result_json FROM guest_diagnostic_attempts WHERE operation_id = ? AND method = 'system.info'",
      [id.value],
    );
    final result = rows.singleOrNull?['result_json'];
    return result == null
        ? null
        : JsonObjectValue.fromJson(jsonDecode(result as String));
  });

  Future<RequestId> _claimDiagnostic(
    GuestControlConnection connection,
    OperationId operationId,
    RequestId? sourceAttemptId,
    String method,
    JsonObjectValue request,
    GuestBridgeDeadline deadline,
    void Function() live,
  ) => database.transaction((db) {
    live();
    _checkSource(db, connection, operationId, sourceAttemptId);
    if (db.select(
      'SELECT 1 FROM guest_diagnostic_attempts WHERE operation_id = ? AND method = ?',
      [operationId.value, method],
    ).isNotEmpty)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    final id = RequestId.generate();
    final now = DateTime.now().toUtc();
    db.execute(
      '''
      INSERT INTO guest_diagnostic_attempts(operation_id, method, attempt_id, vm_id,
        driver_generation, control_epoch_id, source_attempt_id, request_json, started_at, deadline_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        operationId.value,
        method,
        id.value,
        connection.correlation.vmId.value,
        connection.correlation.driverGeneration,
        connection.epochId.value,
        sourceAttemptId?.value,
        jsonEncode(request.toJson()),
        formatPersistenceTimestamp(now),
        formatPersistenceTimestamp(now.add(deadline.remaining)),
      ],
    );
    live();
    return id;
  });

  Future<void> _failDiagnostic(
    OperationId operationId,
    String method,
    RequestId diagnosticId,
    Object error,
  ) => database.transaction((db) {
    db.execute(
      '''
      UPDATE guest_diagnostic_attempts SET error_json = ?, completed_at = ?
      WHERE operation_id = ? AND method = ? AND attempt_id = ? AND completed_at IS NULL
    ''',
      [
        jsonEncode({
          'outcome': 'unknown',
          'cause_type': '${error.runtimeType}',
        }),
        formatPersistenceTimestamp(DateTime.now()),
        operationId.value,
        method,
        diagnosticId.value,
      ],
    );
  });

  Future<GuestCollectionArtifactReceipt> _captureCollection(
    GuestControlConnection connection,
    OperationId operationId,
    RequestId? sourceAttemptId,
    JsonObjectValue request,
    GuestBridgeDeadline deadline,
  ) async {
    void live() {
      deadline.requireLive();
      if (_closed || !connection.isActive)
        throw const GuestArtifactException(GuestArtifactFailure.superseded);
    }

    final diagnosticId = await _claimDiagnostic(
      connection,
      operationId,
      sourceAttemptId,
      'artifact.collect',
      request,
      deadline,
      live,
    );
    try {
      live();
      final result = await _rpc(
        connection,
        () => connection.artifactCollect(
          operationId: operationId,
          request: request,
          deadline: deadline,
        ),
      );
      final receiptId = RequestId.generate();
      await database.transaction((db) {
        live();
        _checkSource(db, connection, operationId, sourceAttemptId);
        final now = formatPersistenceTimestamp(DateTime.now());
        final encoded = jsonEncode(result.toJson());
        db.execute(
          '''
          INSERT INTO guest_artifact_receipts(id, vm_id, driver_generation, operation_id,
            attempt_id, source_kind, control_epoch_id, result_json, created_at)
          VALUES (?, ?, ?, ?, ?, 'collection', ?, ?, ?)
        ''',
          [
            receiptId.value,
            connection.correlation.vmId.value,
            connection.correlation.driverGeneration,
            operationId.value,
            diagnosticId.value,
            connection.epochId.value,
            encoded,
            now,
          ],
        );
        db.execute(
          '''
          UPDATE guest_diagnostic_attempts SET result_json = ?, completed_at = ?
          WHERE operation_id = ? AND method = 'artifact.collect' AND attempt_id = ? AND completed_at IS NULL
        ''',
          [encoded, now, operationId.value, diagnosticId.value],
        );
        if (db.updatedRows != 1)
          throw const GuestArtifactException(GuestArtifactFailure.superseded);
        live();
      });
      live();
      return GuestCollectionArtifactReceipt._(
        this,
        connection,
        operationId,
        sourceAttemptId,
        receiptId,
        result,
        deadline,
      );
    } catch (error) {
      await _failDiagnostic(
        operationId,
        'artifact.collect',
        diagnosticId,
        error,
      );
      rethrow;
    }
  }

  /// Archival projection only. Partial mappings never expose a guest identity.
  Future<JsonObjectValue?> readCollectionResult(OperationId id) async {
    final ids = await database.read((db) {
      final rows = db.select(
        "SELECT * FROM guest_artifact_receipts WHERE operation_id = ? AND source_kind = 'collection'",
        [id.value],
      );
      if (rows.isEmpty) return null;
      final receipt = rows.single;
      final result = JsonObjectValue.fromJson(
        jsonDecode(receipt['result_json'] as String),
      ).toJson();
      final projected = <ArtifactId>[];
      for (final descriptor in result['artifacts'] as List) {
        final mappings = db.select(
          '''
        SELECT host_artifact_id FROM guest_artifact_mappings
        WHERE receipt_id = ? AND guest_artifact_id = ?
      ''',
          [receipt['id'], (descriptor as Map)['artifact_id']],
        );
        if (mappings.isEmpty) return null;
        projected.add(
          ArtifactId(mappings.single['host_artifact_id'] as String),
        );
      }
      return projected;
    });
    if (ids == null) return null;
    final projected = <Object?>[];
    for (final id in ids) {
      final artifact = await artifacts.repository.get(id);
      if (artifact == null) return null;
      projected.add(artifact.toJson());
    }
    return JsonObjectValue.fromJson({'artifacts': projected});
  }

  Future<GuestArtifactPublication> receiveCollectionArtifact(
    GuestCollectionArtifactReceipt receipt, {
    required int index,
    required int maxBytes,
    TestRunId? testRunId,
    DateTime? retentionUntil,
  }) {
    final descriptors = receipt.result.toJson()['artifacts'] as List;
    if (index < 0 || index >= descriptors.length)
      throw RangeError.index(index, descriptors);
    return _receive(
      receipt,
      '$index',
      descriptors[index] as Map,
      maxBytes,
      testRunId,
      retentionUntil,
    );
  }

  Future<GuestArtifactPublication> receiveOutput(
    GuestExecArtifactReceipt receipt, {
    required String output,
    required int maxBytes,
    TestRunId? testRunId,
    DateTime? retentionUntil,
  }) {
    if (!const {'stdout', 'stderr'}.contains(output))
      throw ArgumentError('invalid artifact transfer');
    final reference = receipt.result.toJson()[output] as Map;
    if (reference['mode'] != 'artifact')
      throw ArgumentError('output is not an artifact');
    return _receive(
      receipt,
      output,
      reference,
      maxBytes,
      testRunId,
      retentionUntil,
    );
  }

  Future<GuestArtifactPublication> _receive(
    _ArtifactReceipt receipt,
    String selector,
    Map reference,
    int maxBytes,
    TestRunId? testRunId,
    DateTime? retentionUntil,
  ) {
    if (database.hasActiveCallerTransaction)
      throw StateError('guest transfer must own its commit');
    if (!identical(receipt.service, this) ||
        maxBytes < 0 ||
        maxBytes > maxManagedArtifactBytes)
      throw ArgumentError('invalid artifact transfer');
    if ((reference['size_bytes'] as int) > maxBytes)
      throw const GuestArtifactException(GuestArtifactFailure.limitExceeded);
    if (_closed || !receipt.connection.isActive)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
    receipt.deadline.requireLive();
    final transfer = _Transfer(
      this,
      receipt,
      selector,
      reference,
      maxBytes,
      testRunId,
      retentionUntil,
    );
    budget._acquire(receipt.vmId, maxBytes, transfer.source);
    _transfers.add(transfer);
    unawaited(transfer.run());
    return transfer.result.future;
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    final owned = _transfers.toList();
    for (final transfer in owned) {
      transfer.stop();
    }
    await Future.wait(
      _rpcs.keys.toList().map((connection) => connection.close()),
    );
    await Future.wait([
      ..._captures,
      ...owned.map((transfer) => transfer.done.future),
    ]);
    if (_cleanupFailure case final failure?) throw failure;
  }
}

final class _Transfer {
  _Transfer(
    this.service,
    this.receipt,
    this.selector,
    this.reference,
    this.maxBytes,
    this.testRunId,
    this.retentionUntil,
  );
  final HostGuestArtifactService service;
  final _ArtifactReceipt receipt;
  final String selector;
  final Map reference;
  bool get isCollection => receipt is GuestCollectionArtifactReceipt;
  ArtifactKind get kind => switch (reference['kind'] ?? selector) {
    'stdout' => ArtifactKind.stdout,
    'stderr' => ArtifactKind.stderr,
    'serial' => ArtifactKind.serial,
    'driver' => ArtifactKind.driver,
    'guest-log' => ArtifactKind.guestLog,
    'result' => ArtifactKind.result,
    _ => ArtifactKind.file,
  };
  final int maxBytes;
  final TestRunId? testRunId;
  final DateTime? retentionUntil;
  final result = Completer<GuestArtifactPublication>();
  final done = Completer<void>();
  GuestBridgeChannel? channel;
  bool stopped = false;
  bool quarantine = false;
  GuestBridgeDeadline? phase;
  Timer? timer;
  String get source =>
      '${receipt.vmId.value}/${receipt.generation}/${receipt.operationId.value}/${reference['artifact_id']}';

  void live() {
    (phase ?? receipt.deadline).requireLive();
    if (stopped || service._closed || !receipt.connection.isActive)
      throw const GuestArtifactException(GuestArtifactFailure.superseded);
  }

  void stop() {
    stopped = true;
    unawaited(channel?.close());
  }

  void setPhase(Duration maximum) {
    phase = receipt.deadline.capped(maximum);
    timer?.cancel();
    timer = Timer(
      phase!.remaining,
      () => unawaited(channel?.close(GuestBridgeFailure.deadlineExpired)),
    );
  }

  Future<void> run() async {
    GuestArtifactPublication? publication;
    Object? failure;
    StackTrace? stack;
    try {
      publication = await receive();
    } catch (error, trace) {
      failure = error;
      stack = trace;
      quarantine = error is ArtifactPublicationFailure;
      if (error is ArtifactPublicationFailure)
        service._cleanupFailure ??= error;
    } finally {
      timer?.cancel();
      await channel?.close();
      service.budget._release(
        receipt.vmId,
        maxBytes,
        source,
        quarantine: quarantine,
      );
      service._transfers.remove(this);
      done.complete();
    }
    if (failure != null) {
      result.completeError(failure, stack);
    } else {
      result.complete(publication!);
    }
  }

  Future<GuestArtifactPublication> receive() async {
    live();
    await service.database.read(
      (db) => _checkSource(
        db,
        receipt.connection,
        receipt.operationId,
        receipt.attemptId,
      ),
    );
    setPhase(const Duration(seconds: 5));
    channel = await receipt.connection.openBinaryChannel(
      operationId: receipt.operationId,
      deadline: phase!,
    );
    live();
    final guestId = ArtifactId(reference['artifact_id'] as String);
    final binding = <String, Object?>{
      'protocol_version': 'gaovm.binary.v1',
      'vm_id': receipt.vmId.value,
      'driver_generation': receipt.generation,
      'operation_id': receipt.operationId.value,
    };
    final open = utf8.encode(
      jsonEncode({
        ...binding,
        'kind': 'open',
        'artifact_id': guestId.value,
        'source': isCollection
            ? {'kind': 'collection', 'stream_id': reference['stream_id']}
            : {'kind': 'exec_output', 'output': selector},
      }),
    );
    final preface = Uint8List(8 + open.length);
    preface.setRange(0, 4, ascii.encode('GAB1'));
    ByteData.sublistView(preface).setUint32(4, open.length, Endian.big);
    preface.setRange(8, preface.length, open);
    await channel!.write(preface, deadline: phase!);
    final length = ByteData.sublistView(
      await channel!.readExact(4, deadline: phase!),
    ).getUint32(0, Endian.big);
    if (length < 1 || length > 4096) _invalid();
    final raw = await channel!.readExact(length, deadline: phase!);
    final Map<String, Object?> ready;
    try {
      ready = decodeGuestWireObject(raw);
    } on FormatException {
      _invalid();
    }
    if (ready['kind'] == 'error') {
      _keys(ready, {...binding.keys, 'kind', 'artifact_id', 'error'});
      if (!binding.entries.every((entry) => ready[entry.key] == entry.value) ||
          ready['artifact_id'] != guestId.value)
        _invalid();
      final error = _object(ready['error']);
      _keys(error, {'code', 'message', 'retryable'});
      if (!const {
            'PROTOCOL_VERSION_MISMATCH',
            'INVALID_REQUEST',
            'ARTIFACT_NOT_FOUND',
            'ARTIFACT_LIMIT_EXCEEDED',
            'GUEST_INTERNAL_ERROR',
          }.contains(error['code']) ||
          error['message'] is! String ||
          utf8.encode(error['message'] as String).length > 256 ||
          error['retryable'] is! bool)
        _invalid();
      throw GuestBinaryRemoteException(
        error['code'] as String,
        error['retryable'] as bool,
      );
    }
    _keys(ready, {...binding.keys, 'kind', 'artifact'});
    if (!binding.entries.every((entry) => ready[entry.key] == entry.value) ||
        ready['kind'] != 'ready')
      _invalid();
    final descriptor = _object(ready['artifact']);
    _keys(descriptor, {
      'artifact_id',
      'kind',
      'content_type',
      'size_bytes',
      'digest',
      'stream_id',
    });
    final size = descriptor['size_bytes'];
    if (descriptor['artifact_id'] != guestId.value ||
        descriptor['kind'] != (isCollection ? reference['kind'] : selector) ||
        descriptor['content_type'] is! String ||
        (descriptor['content_type'] as String).isEmpty ||
        (descriptor['content_type'] as String).runes.length > 255 ||
        size is! int ||
        size < 0 ||
        size > maxBytes ||
        size != reference['size_bytes'] ||
        descriptor['digest'] is! String ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(descriptor['digest'] as String) ||
        descriptor['stream_id'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(descriptor['stream_id'] as String))
      _invalid();
    if (isCollection &&
        JsonObjectValue.fromJson(descriptor) !=
            JsonObjectValue.fromJson(reference))
      _invalid();
    setPhase(const Duration(seconds: 30));
    Stream<List<int>> body() async* {
      var total = 0;
      while (true) {
        live();
        final count = ByteData.sublistView(
          await channel!.readExact(4, deadline: phase!),
        ).getUint32(0, Endian.big);
        if (count == 0) {
          if (total != size) _invalid();
          setPhase(const Duration(seconds: 30));
          return;
        }
        if (count > 8192 || count > size - total) _invalid();
        final bytes = await channel!.readExact(count, deadline: phase!);
        live();
        total += count;
        yield bytes;
      }
    }

    final mappings = await service.database.read(
      (db) => db.select(
        'SELECT * FROM guest_artifact_mappings WHERE vm_id = ? AND driver_generation = ? AND operation_id = ? AND guest_artifact_id = ?',
        [
          receipt.vmId.value,
          receipt.generation,
          receipt.operationId.value,
          guestId.value,
        ],
      ),
    );
    Artifact? replay;
    if (mappings.isNotEmpty) {
      final row = mappings.single;
      if (row['receipt_id'] != receipt.receiptId.value ||
          row['selector'] != selector ||
          row['kind'] != descriptor['kind'] ||
          row['content_type'] != descriptor['content_type'] ||
          row['size_bytes'] != size ||
          row['digest'] != descriptor['digest'] ||
          row['retention_until'] !=
              (retentionUntil == null
                  ? null
                  : formatPersistenceTimestamp(retentionUntil!))) {
        throw const GuestArtifactException(
          GuestArtifactFailure.publicationConflict,
        );
      }
      // Re-read from byte zero with the same bounded framing/hash checks, but
      // never allocate another publication identity or discard a committed one.
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      await for (final chunk in body()) {
        hash.add(chunk);
      }
      hash.close();
      if ('sha256:${digest.value}' != descriptor['digest'])
        throw const ArtifactContentMismatch();
      replay = await service.artifacts.publish(
        artifactId: ArtifactId(row['host_artifact_id'] as String),
        bytes: const Stream.empty(),
        kind: kind,
        contentType: descriptor['content_type'] as String,
        maxBytes: maxBytes,
        expectedSizeBytes: size,
        expectedDigest: descriptor['digest'] as String,
        vmId: receipt.vmId,
        operationId: receipt.operationId,
        testRunId: testRunId,
        retentionUntil: retentionUntil,
      );
      live();
      await service.database.read(
        (db) => _checkSource(
          db,
          receipt.connection,
          receipt.operationId,
          receipt.attemptId,
        ),
      );
    }
    final artifact =
        replay ??
        await service.artifacts.publish(
          bytes: body(),
          kind: kind,
          contentType: descriptor['content_type'] as String,
          maxBytes: maxBytes,
          expectedSizeBytes: size,
          expectedDigest: descriptor['digest'] as String,
          vmId: receipt.vmId,
          operationId: receipt.operationId,
          testRunId: testRunId,
          retentionUntil: retentionUntil,
          commitReferences: (artifact) => service.database.read((db) {
            live();
            _checkSource(
              db,
              receipt.connection,
              receipt.operationId,
              receipt.attemptId,
            );
            db.execute(
              '''
          INSERT INTO guest_artifact_mappings(vm_id, driver_generation, operation_id, guest_artifact_id,
            receipt_id, selector, host_artifact_id, kind, content_type, size_bytes, digest, retention_until)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
              [
                receipt.vmId.value,
                receipt.generation,
                receipt.operationId.value,
                guestId.value,
                receipt.receiptId.value,
                selector,
                artifact.id.value,
                descriptor['kind'],
                artifact.contentType,
                artifact.sizeBytes,
                artifact.digest,
                retentionUntil == null
                    ? null
                    : formatPersistenceTimestamp(retentionUntil!),
              ],
            );
            live();
          }),
        );
    try {
      live();
      final ack = utf8.encode(
        jsonEncode({
          ...binding,
          'kind': 'committed',
          'artifact_id': guestId.value,
          'stream_id': descriptor['stream_id'],
          'size_bytes': size,
          'digest': descriptor['digest'],
        }),
      );
      final frame = Uint8List(4 + ack.length);
      ByteData.sublistView(frame).setUint32(0, ack.length, Endian.big);
      frame.setRange(4, frame.length, ack);
      await channel!.write(frame, deadline: phase!);
      return GuestArtifactPublication(artifact, acknowledged: true);
    } catch (_) {
      // A lost ACK cannot roll back a previously committed host artifact.
      return GuestArtifactPublication(artifact, acknowledged: false);
    }
  }
}

void _checkSource(
  Database db,
  GuestControlConnection connection,
  OperationId id,
  RequestId? attemptId,
) {
  if (attemptId != null) {
    _checkJob(db, connection, id, attemptId);
    return;
  }
  // TestRun diagnostics do not claim a new exec. The root may have been
  // cancelled, but collection still belongs to its original successful start.
  final rows = db.select(
    r'''
    SELECT 1 FROM test_runs t JOIN operations parent ON parent.id = t.operation_id
    JOIN test_run_vm_start b ON b.test_run_id = t.id AND b.vm_id = t.vm_id
    JOIN operations start ON start.id = b.operation_id
    JOIN vms v ON v.id = t.vm_id JOIN vm_runtime r ON r.vm_id = t.vm_id
    WHERE t.operation_id = ? AND t.vm_id = ? AND t.state = 'collecting'
      AND parent.type = 'test.run' AND parent.state = 'running'
      AND parent.resource_type = 'test_run' AND parent.resource_id = t.id
      AND start.type = 'vm.start' AND start.state = 'succeeded'
      AND start.resource_type = 'virtual_machine' AND start.resource_id = t.vm_id
      AND b.driver_generation = ? AND r.driver_generation = b.driver_generation
      AND b.abort_operation_id IS NULL
      AND v.intent_revision = b.intent_revision AND r.applied_intent_revision = b.intent_revision
      AND json_extract(start.request_json, '$.intent_revision') = b.intent_revision
      AND json_extract(start.request_json, '$.spec_generation') = v.spec_generation
      AND r.observed_generation = v.spec_generation
      AND v.deleted_at IS NULL AND v.deleting_at IS NULL
  ''',
    [
      id.value,
      connection.correlation.vmId.value,
      connection.correlation.driverGeneration,
    ],
  );
  if (rows.isEmpty)
    throw const GuestArtifactException(GuestArtifactFailure.superseded);
}

void _checkJob(
  Database db,
  GuestControlConnection connection,
  OperationId id,
  RequestId attemptId,
) {
  final rows = db.select(
    '''
    SELECT 1 FROM guest_exec_jobs j JOIN operations o ON o.id = j.operation_id
    JOIN vm_runtime r ON r.vm_id = j.vm_id JOIN vms v ON v.id = j.vm_id
    WHERE j.operation_id = ? AND j.attempt_id = ? AND j.vm_id = ? AND j.driver_generation = ?
      AND j.started_at IS NOT NULL AND j.completed_at IS NULL
      AND j.control_epoch_id = ?
      AND r.driver_generation = j.driver_generation AND v.deleted_at IS NULL
      AND o.type = 'guest.exec' AND o.state = 'running'
      AND o.resource_type = 'virtual_machine' AND o.resource_id = j.vm_id
  ''',
    [
      id.value,
      attemptId.value,
      connection.correlation.vmId.value,
      connection.correlation.driverGeneration,
      connection.epochId.value,
    ],
  );
  if (rows.isEmpty)
    throw const GuestArtifactException(GuestArtifactFailure.superseded);
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) _invalid();
  return value;
}

void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains))
    _invalid();
}

Never _invalid() =>
    throw const GuestArtifactException(GuestArtifactFailure.invalidMessage);

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) {
    value = digest;
  }

  @override
  void close() {}
}
