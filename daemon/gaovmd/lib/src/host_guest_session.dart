import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

import 'guest_bridge_client.dart';
import 'guest_exec_request.dart';
import 'guest_wire_json.dart';
import 'runtime_driver.dart';

const _core = {
  'health',
  'system.info',
  'exec.start',
  'exec.status',
  'exec.cancel',
  'artifact.collect',
};
const _capabilities = {..._core, 'service.status', 'shutdown', 'reboot'};
const _maxFrameBytes = 16 * 1024 * 1024;

enum GuestSessionFailure {
  invalidMessage,
  capabilityMismatch,
  unavailable,
  disconnected,
  deadlineExpired,
  closed,
  limitExceeded,
}

final class GuestSessionException implements Exception {
  const GuestSessionException(this.code);
  final GuestSessionFailure code;
  @override
  String toString() => 'guest session failed: ${code.name}';
}

/// The validated wire code/retryability, without reflecting guest diagnostics.
final class GuestRemoteException implements Exception {
  const GuestRemoteException._(this.code, this.retryable);
  final String code;
  final bool retryable;
  @override
  String toString() => 'guest request failed: $code';
}

/// Optional internal ownership capability; absent guest support does not block
/// the base RuntimeDriverSession lifecycle interface.
abstract interface class GuestSessionProvider {
  HostGuestSession get guestSession;
}

/// Ordered local evidence, not durable readiness or a guest-supplied epoch.
final class GuestReadinessObservation {
  const GuestReadinessObservation._(
    this.correlation,
    this.revision,
    this.ready,
    this._stillCurrent,
  );
  final DriverCorrelation correlation;
  final int revision;
  final bool ready;
  final bool Function() _stillCurrent;
  bool get isCurrent => _stillCurrent();
}

/// One host owner per VM/driver generation. Bridge admission is not readiness.
/// This internal control API never accepts a token, socket path or guest port.
final class HostGuestSession {
  HostGuestSession({
    required GuestBridgeProvider bridge,
    required this.correlation,
    required this.frameTimeout,
  }) : _bridge = bridge {
    if (frameTimeout <= Duration.zero)
      throw ArgumentError('invalid frame budget');
  }
  final GuestBridgeProvider _bridge;
  final DriverCorrelation correlation;
  final Duration frameTimeout;
  GuestControlConnection? _connection;
  Future<GuestControlConnection>? _opening;
  bool _closed = false;
  Future<void>? _closeFuture;
  final _readiness = StreamController<GuestReadinessObservation>.broadcast(
    sync: true,
  );
  int _revision = 0;
  bool _lastReady = false;

  bool get isReady => !_closed && (_connection?.isReady ?? false);

  /// Read-only adoption of the existing authenticated epoch. Never opens or
  /// reconnects a channel on behalf of an execution worker or public handler.
  GuestControlConnection? get readyConnection => isReady ? _connection : null;
  Stream<GuestReadinessObservation> get readiness => _readiness.stream;

  void _publishReadiness(bool ready) {
    if (ready && _closed || _lastReady == ready) return;
    _lastReady = ready;
    final revision = ++_revision;
    _readiness.add(
      GuestReadinessObservation._(
        correlation,
        revision,
        ready,
        () =>
            _revision == revision && _lastReady == ready && (!ready || isReady),
      ),
    );
  }

  Future<GuestControlConnection> connect({
    required GuestBridgeDeadline deadline,
  }) {
    if (_closed)
      return Future.error(
        const GuestSessionException(GuestSessionFailure.closed),
      );
    if (_connection case final connection? when connection.isReady) {
      return Future.value(connection);
    }
    return _opening ??= _connect(deadline.capped(const Duration(seconds: 5)));
  }

  /// Recheck health on the current epoch, or reopen after actual channel cleanup.
  /// Concurrent connect/refresh calls share the same owned probe.
  Future<GuestControlConnection> refresh({
    required GuestBridgeDeadline deadline,
  }) {
    if (_closed)
      return Future.error(
        const GuestSessionException(GuestSessionFailure.closed),
      );
    return _opening ??= _connect(deadline.capped(const Duration(seconds: 5)));
  }

  Future<GuestControlConnection> _connect(GuestBridgeDeadline deadline) async {
    GuestControlConnection? connection;
    var created = false;
    try {
      final previous = _connection;
      if (previous != null && !previous._closed) {
        connection = previous;
        await previous.health(deadline: deadline);
        if (_closed)
          throw const GuestSessionException(GuestSessionFailure.closed);
        if (!previous.isReady)
          throw const GuestSessionException(GuestSessionFailure.unavailable);
        return previous;
      }
      // A replacement epoch cannot race the preceding owned descriptor/reader
      // cleanup. Its late callbacks keep their own immutable connection owner.
      await previous?.closed;
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      deadline.requireLive();
      final channel = await _bridge.openGuestChannel(
        streamKind: GuestBridgeStreamKind.control,
        requestId: RequestId.generate(),
        operationId: null,
        deadline: deadline,
      );
      connection = GuestControlConnection._(
        channel,
        _bridge,
        correlation,
        frameTimeout,
        (ready) {
          if (identical(_connection, connection)) _publishReadiness(ready);
        },
      );
      created = true;
      _connection = connection;
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      await connection._negotiate(deadline);
      connection._startReader();
      await connection.health(deadline: deadline);
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      if (!connection.isReady)
        throw const GuestSessionException(GuestSessionFailure.unavailable);
      return connection;
    } catch (error) {
      if (created) {
        await connection?.close();
        if (identical(_connection, connection)) _connection = null;
      }
      if (error is GuestRemoteException) rethrow;
      throw _failure(error);
    } finally {
      _opening = null;
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    _publishReadiness(false);
    await _connection?.close();
    try {
      await _opening;
    } catch (_) {}
    // Subscriber scheduling is not an owned descriptor-cleanup barrier.
    unawaited(_readiness.close());
  }
}

final class GuestHealth {
  GuestHealth._(this.status, this.uptimeSeconds, Map<String, String> checks)
    : checks = Map.unmodifiable(checks);
  final String status;
  final num uptimeSeconds;
  final Map<String, String> checks;
}

/// An individual negotiated control epoch, never reusable after closure.
final class GuestControlConnection {
  GuestControlConnection._(
    this._channel,
    this._bridge,
    this.correlation,
    this._frameTimeout,
    this._onReadiness,
  );
  final GuestBridgeChannel _channel;
  final GuestBridgeProvider _bridge;
  final Set<GuestBridgeChannel> _binaryChannels = {};
  final Set<Completer<void>> _binaryOpenings = {};
  final DriverCorrelation correlation;
  final Duration _frameTimeout;

  /// Local original-owner identity, never a wire credential or public resource.
  final RequestId epochId = RequestId.generate();
  final void Function(bool ready) _onReadiness;
  Set<String> _capabilities = const {};
  bool _negotiated = false;
  bool _healthy = false;
  bool _closed = false;
  final Map<String, _GuestPendingRequest> _pending = {};
  Future<void> _writeTail = Future<void>.value();
  Completer<void>? _readerDone;
  Future<void>? _closeFuture;

  Set<String> get capabilities => _capabilities;

  /// A degraded health reply does not replace the authenticated original owner.
  bool get isActive => !_closed && _negotiated && _channel.isActive;
  bool get isReady => isActive && _healthy;
  Future<void> get closed => _closedDone.future;
  final Completer<void> _closedDone = Completer<void>();

  /// Binary sockets use this epoch's original driver provider. A caller cannot
  /// substitute another VM's bridge or reuse the connection after control EOF.
  Future<GuestBridgeChannel> openBinaryChannel({
    required OperationId operationId,
    required GuestBridgeDeadline deadline,
  }) async {
    if (!isActive)
      throw const GuestSessionException(GuestSessionFailure.closed);
    deadline.requireLive();
    final owned = Completer<void>();
    _binaryOpenings.add(owned);
    try {
      final channel = await _bridge.openGuestChannel(
        streamKind: GuestBridgeStreamKind.binary,
        requestId: RequestId.generate(),
        operationId: operationId,
        deadline: deadline,
      );
      if (!isActive) {
        await channel.close();
        throw const GuestSessionException(GuestSessionFailure.closed);
      }
      _binaryChannels.add(channel);
      channel.closed.then((_) => _binaryChannels.remove(channel));
      return channel;
    } finally {
      _binaryOpenings.remove(owned);
      owned.complete();
    }
  }

  Future<void> _negotiate(GuestBridgeDeadline deadline) async {
    final hello = _request('session.hello', null, {
      'peer_role': 'host',
      'offered_capabilities': _core.toList(),
      'required_capabilities': _core.toList(),
    });
    await _write(hello, deadline);
    Set<String>? accepted;
    Set<String>? acknowledged;
    while (accepted == null || acknowledged == null) {
      final message = await _read(deadline);
      _binding(message);
      if (message['method'] != 'session.hello' ||
          message['operation_id'] != null)
        _invalid();
      if (message['kind'] == 'request' && accepted == null) {
        final params = _object(message['params']);
        _keys(
          params,
          {'peer_role', 'offered_capabilities', 'required_capabilities'},
          optional: {'agent'},
        );
        if (params['peer_role'] != 'guest') _invalid();
        if (params.containsKey('agent')) {
          final agent = _object(params['agent']);
          _keys(agent, {'name', 'version'});
          for (final value in agent.values) {
            if (value is! String || value.isEmpty || value.runes.length > 128)
              _invalid();
          }
        }
        final offered = _capabilitySet(params['offered_capabilities']);
        final required = _capabilitySet(params['required_capabilities']);
        accepted = offered.intersection(_core);
        if (!offered.containsAll(_core) || !accepted.containsAll(required))
          _mismatch();
        if (acknowledged != null && !_same(accepted, acknowledged)) _mismatch();
        await _write({
          ...message..remove('params'),
          'kind': 'response',
          'result': {'accepted_capabilities': accepted.toList()..sort()},
        }, deadline);
      } else if (message['kind'] == 'response' &&
          acknowledged == null &&
          message['id'] == hello['id']) {
        final result = _object(message['result']);
        _keys(result, {'accepted_capabilities'});
        acknowledged = _capabilitySet(result['accepted_capabilities']);
        if (!_core.containsAll(acknowledged) ||
            !acknowledged.containsAll(_core) ||
            (accepted != null && !_same(accepted, acknowledged)))
          _mismatch();
      } else if (message['kind'] == 'error' && message['id'] == hello['id']) {
        final error = _remoteError(message);
        if (error.code == 'CAPABILITY_MISMATCH') _mismatch();
        throw error;
      } else {
        _invalid();
      }
    }
    deadline.requireLive();
    _capabilities = Set.unmodifiable(accepted);
    _negotiated = true;
  }

  Future<GuestHealth> health({
    required GuestBridgeDeadline deadline,
    OperationId? operationId,
  }) async {
    if (_closed || !_negotiated)
      throw const GuestSessionException(GuestSessionFailure.closed);
    final reply = _sendRequest('health', operationId, deadline);
    try {
      final result = await reply;
      _keys(result, {'status', 'uptime_seconds'}, optional: {'checks'});
      final status = result['status'];
      final uptime = result['uptime_seconds'];
      if ((status != 'ok' && status != 'degraded') ||
          uptime is! num ||
          !uptime.isFinite ||
          uptime < 0)
        _invalid();
      final checks = <String, String>{};
      if (result.containsKey('checks')) {
        for (final entry in _object(result['checks']).entries) {
          if (!const {'ok', 'degraded', 'failed'}.contains(entry.value))
            _invalid();
          checks[entry.key] = entry.value as String;
        }
      }
      deadline.requireLive();
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      _healthy = status == 'ok';
      _onReadiness(isReady);
      return GuestHealth._(status as String, uptime, checks);
    } catch (error) {
      if (error is GuestRemoteException) {
        _healthy = false;
        _onReadiness(false);
        rethrow;
      }
      await close();
      throw _failure(error);
    }
  }

  Future<JsonObjectValue> systemInfo({
    required GuestBridgeDeadline deadline,
    OperationId? operationId,
  }) async {
    final reply = _sendRequest('system.info', operationId, deadline);
    try {
      final result = await reply;
      _keys(
        result,
        {'os', 'kernel', 'architecture', 'hostname'},
        optional: {'boot_id'},
      );
      final os = _object(result['os']);
      _keys(os, {'name', 'version'}, optional: {'build_id', 'channel'});
      for (final value in [
        os['name'],
        os['version'],
        result['kernel'],
        result['architecture'],
        result['hostname'],
      ]) {
        if (value is! String || value.isEmpty) _invalid();
      }
      for (final value in [os['build_id'], os['channel'], result['boot_id']]) {
        if (value != null && value is! String) _invalid();
      }
      deadline.requireLive();
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      return JsonObjectValue.fromJson(result);
    } catch (error) {
      if (error is GuestRemoteException) rethrow;
      await close();
      throw _failure(error);
    }
  }

  Future<JsonObjectValue> artifactCollect({
    required OperationId operationId,
    required JsonObjectValue request,
    required GuestBridgeDeadline deadline,
  }) async {
    final params = validateGuestArtifactCollectRequest(request).toJson();
    final paths = params['paths'] as List;
    final maximum = params['max_total_bytes'] as int;
    final result = await _sendRequest(
      'artifact.collect',
      operationId,
      deadline,
      params: params,
    );
    try {
      _keys(result, {'artifacts'});
      final descriptors = result['artifacts'];
      if (descriptors is! List || descriptors.length > paths.length) _invalid();
      final ids = <String>{};
      final streams = <String>{};
      var bytes = 0;
      for (final value in descriptors) {
        final descriptor = _object(value);
        _keys(descriptor, {
          'artifact_id',
          'kind',
          'content_type',
          'size_bytes',
          'digest',
          'stream_id',
        });
        final id = descriptor['artifact_id'];
        if (id is! String) _invalid();
        try {
          ArtifactId(id);
        } on ArgumentError {
          _invalid();
        }
        final kind = descriptor['kind'];
        final mime = descriptor['content_type'];
        final size = descriptor['size_bytes'];
        final digest = descriptor['digest'];
        final stream = descriptor['stream_id'];
        if (kind is! String ||
            kind.isEmpty ||
            kind.runes.length > 64 ||
            mime is! String ||
            mime.isEmpty ||
            mime.runes.length > 255 ||
            size is! int ||
            size < 0 ||
            digest is! String ||
            !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest) ||
            stream is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(stream) ||
            !ids.add(id) ||
            !streams.add(stream))
          _invalid();
        if (size > maximum - bytes) _invalid();
        bytes += size;
      }
      deadline.requireLive();
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      return JsonObjectValue.fromJson(result);
    } catch (error) {
      if (error is GuestRemoteException) rethrow;
      await close();
      throw _failure(error);
    }
  }

  Future<Map<String, Object?>> _sendRequest(
    String method,
    OperationId? operationId,
    GuestBridgeDeadline deadline, {
    Map<String, Object?> params = const {},
  }) {
    if (_closed || !_negotiated)
      throw const GuestSessionException(GuestSessionFailure.closed);
    try {
      deadline.requireLive();
    } catch (error) {
      throw _failure(error);
    }
    if (_pending.length >= 8)
      throw const GuestSessionException(GuestSessionFailure.limitExceeded);
    final request = _request(method, operationId, params);
    final payload = _encodeMessage(request);
    try {
      deadline.requireLive();
    } catch (error) {
      throw _failure(error);
    }
    final pending = _GuestPendingRequest(request, deadline);
    _pending[request['id'] as String] = pending;
    pending.timer = Timer(deadline.remaining, () {
      unawaited(close(GuestSessionFailure.deadlineExpired));
    });
    _writeTail = _writeTail
        .then((_) async {
          if (_closed) return;
          deadline.requireLive();
          await _writePayload(payload, deadline);
        })
        .catchError((Object error) {
          unawaited(close(_failure(error).code));
        });
    return pending.result.future;
  }

  Future<JsonObjectValue> execStart({
    required OperationId operationId,
    required GuestExecRequest request,
    required GuestBridgeDeadline deadline,
  }) => _exec(
    'exec.start',
    operationId,
    request,
    deadline,
    params: request.toJson(),
  );

  Future<JsonObjectValue> execStatus({
    required OperationId operationId,
    required GuestExecRequest request,
    required GuestBridgeDeadline deadline,
  }) => _exec('exec.status', operationId, request, deadline);

  Future<JsonObjectValue> execCancel({
    required OperationId operationId,
    required GuestExecRequest request,
    required GuestBridgeDeadline deadline,
  }) => _exec('exec.cancel', operationId, request, deadline);

  Future<JsonObjectValue> _exec(
    String method,
    OperationId operationId,
    GuestExecRequest request,
    GuestBridgeDeadline deadline, {
    Map<String, Object?> params = const {},
  }) async {
    final reply = _sendRequest(method, operationId, deadline, params: params);
    try {
      final result = await reply;
      _keys(
        result,
        {'state', 'exit_code', 'stdout', 'stderr', 'duration_ms', 'timed_out'},
        optional: {'signal'},
      );
      if (!OperationState.values.any(
            (state) => state.name == result['state'],
          ) ||
          (result['exit_code'] != null && result['exit_code'] is! int) ||
          result['duration_ms'] is! int ||
          (result['duration_ms'] as int) < 0 ||
          result['timed_out'] is! bool ||
          (result['signal'] != null && result['signal'] is! int))
        _invalid();
      for (final name in ['stdout', 'stderr']) {
        final output = _object(result[name]);
        final size = output['size_bytes'];
        if (size is! int || size < 0) _invalid();
        if (output['mode'] == 'inline') {
          _keys(output, {'mode', 'text', 'truncated', 'size_bytes'});
          if (output['text'] is! String || output['truncated'] is! bool)
            _invalid();
          final text = output['text'] as String;
          if (size > request.maxInlineBytes ||
              text.length > size ||
              utf8.encode(text).length != size)
            _invalid();
        } else if (output['mode'] == 'artifact') {
          _keys(output, {'mode', 'artifact_id', 'size_bytes'});
          if (output['artifact_id'] is! String) _invalid();
          ArtifactId(output['artifact_id'] as String);
        } else {
          _invalid();
        }
      }
      deadline.requireLive();
      if (_closed)
        throw const GuestSessionException(GuestSessionFailure.closed);
      return JsonObjectValue.fromJson(result);
    } catch (error) {
      if (error is GuestRemoteException) rethrow;
      await close();
      throw _failure(error);
    }
  }

  void _startReader() {
    _readerDone = Completer<void>();
    unawaited(_readLoop());
  }

  Future<void> _readLoop() async {
    try {
      while (!_closed) {
        final message = await _read(null);
        _binding(message);
        if (message['kind'] == 'event') {
          _event(message);
          continue;
        }
        final pending = _pending[message['id']];
        if (pending == null ||
            !const {'response', 'error'}.contains(message['kind']) ||
            message['method'] != pending.request['method'] ||
            message['operation_id'] != pending.request['operation_id'])
          _invalid();
        pending.deadline.requireLive();
        final error = message['kind'] == 'error' ? _remoteError(message) : null;
        final result = error == null ? _object(message['result']) : null;
        _pending.remove(message['id']);
        pending.timer?.cancel();
        if (error == null) {
          pending.result.complete(result!);
        } else {
          pending.result.completeError(error);
        }
      }
    } catch (error) {
      unawaited(close(_failure(error).code));
    } finally {
      _readerDone!.complete();
    }
  }

  void _event(Map<String, Object?> message) {
    final payload = _object(message['payload']);
    _keys(payload, {}, optional: {'exec_state', 'warning_code', 'message'});
    if (message['occurred_at'] is! String ||
        DateTime.tryParse(message['occurred_at'] as String) == null)
      _invalid();
    if (payload.containsKey('exec_state') &&
        !const {
          'pending',
          'running',
          'succeeded',
          'failed',
          'cancelled',
        }.contains(payload['exec_state']))
      _invalid();
    if (payload.containsKey('warning_code') &&
        (payload['warning_code'] is! String ||
            !RegExp(
              r'^[A-Z][A-Z0-9_]*$',
            ).hasMatch(payload['warning_code'] as String)))
      _invalid();
    if (payload.containsKey('message') && payload['message'] is! String)
      _invalid();
    if (message['method'] == 'exec.state_changed') {
      if (message['operation_id'] == null || !payload.containsKey('exec_state'))
        _invalid();
    } else if (message['method'] != 'guest.warning' ||
        !payload.keys.toSet().containsAll({'warning_code', 'message'})) {
      _invalid();
    }
    // Notifications do not establish health or complete an application request.
    // Durable guest-operation/event integration is owned by application services.
  }

  Map<String, Object?> _request(
    String method,
    OperationId? operationId,
    Map<String, Object?> params,
  ) => {
    'protocol_version': 'gaovm.guest.v1',
    'kind': 'request',
    'id': RequestId.generate().value,
    'method': method,
    'vm_id': correlation.vmId.value,
    'driver_generation': correlation.driverGeneration,
    'operation_id': operationId?.value,
    'params': params,
  };

  void _binding(Map<String, Object?> message) {
    final kind = message['kind'];
    final body = switch (kind) {
      'request' => 'params',
      'response' => 'result',
      'error' => 'error',
      'event' => 'payload',
      _ => '',
    };
    _keys(message, {
      'protocol_version',
      'kind',
      if (kind == 'event') 'occurred_at' else 'id',
      'method',
      'vm_id',
      'driver_generation',
      'operation_id',
      body,
    });
    if (message['protocol_version'] != 'gaovm.guest.v1' ||
        message['vm_id'] != correlation.vmId.value ||
        message['driver_generation'] != correlation.driverGeneration ||
        message['method'] is! String ||
        (kind != 'event' &&
            (message['id'] is! String ||
                (message['id'] as String).isEmpty ||
                (message['id'] as String).runes.length > 128)))
      _invalid();
    if (message['operation_id'] != null) {
      if (message['operation_id'] is! String) _invalid();
      OperationId(message['operation_id'] as String);
    }
  }

  Future<Map<String, Object?>> _read(GuestBridgeDeadline? deadline) async {
    final Uint8List prefix;
    if (deadline == null) {
      final first = await _channel.readFrameStart();
      deadline = GuestBridgeDeadline.after(_frameTimeout);
      prefix = Uint8List(4)..[0] = first.single;
      prefix.setRange(1, 4, await _channel.readExact(3, deadline: deadline));
    } else {
      prefix = await _channel.readExact(4, deadline: deadline);
    }
    final count = ByteData.sublistView(prefix).getUint32(0, Endian.big);
    if (count < 1 || count > _maxFrameBytes) _invalid();
    final payload = Uint8List(count);
    for (var offset = 0; offset < count;) {
      final length = count - offset > 8192 ? 8192 : count - offset;
      payload.setRange(
        offset,
        offset + length,
        await _channel.readExact(length, deadline: deadline),
      );
      offset += length;
    }
    final value = decodeGuestWireObject(payload);
    deadline.requireLive();
    return value;
  }

  Future<void> _write(
    Map<String, Object?> message,
    GuestBridgeDeadline deadline,
  ) => _writePayload(_encodeMessage(message), deadline);

  Future<void> _writePayload(
    Uint8List payload,
    GuestBridgeDeadline deadline,
  ) async {
    final frame = Uint8List(4 + payload.length);
    ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
    frame.setRange(4, frame.length, payload);
    for (var offset = 0; offset < frame.length; offset += 8192) {
      final end = offset + 8192 > frame.length ? frame.length : offset + 8192;
      await _channel.write(
        Uint8List.sublistView(frame, offset, end),
        deadline: deadline,
      );
    }
  }

  Future<void> close([
    GuestSessionFailure reason = GuestSessionFailure.closed,
  ]) => _closeFuture ??= _close(reason);
  Future<void> _close(GuestSessionFailure reason) async {
    _closed = true;
    _healthy = false;
    _onReadiness(false);
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.result.completeError(GuestSessionException(reason));
    }
    _pending.clear();
    await _channel.close();
    await Future.wait(
      _binaryChannels.toList().map((channel) => channel.close()),
    );
    await Future.wait(
      _binaryOpenings.toList().map((opening) => opening.future),
    );
    await _channel.closed;
    await _readerDone?.future;
    await _writeTail;
    _closedDone.complete();
  }
}

GuestRemoteException _remoteError(Map<String, Object?> message) {
  final error = _object(message['error']);
  _keys(error, {'code', 'message', 'retryable'}, optional: {'details'});
  if (!const {
        'PROTOCOL_VERSION_MISMATCH',
        'CAPABILITY_MISMATCH',
        'CAPABILITY_NOT_SUPPORTED',
        'INVALID_REQUEST',
        'EXEC_NOT_FOUND',
        'EXEC_START_FAILED',
        'EXEC_CANCEL_FAILED',
        'EXEC_TIMEOUT',
        'OUTPUT_LIMIT_EXCEEDED',
        'ARTIFACT_NOT_FOUND',
        'ARTIFACT_LIMIT_EXCEEDED',
        'SERVICE_NOT_FOUND',
        'POWER_ACTION_FAILED',
        'GUEST_INTERNAL_ERROR',
      }.contains(error['code']) ||
      error['message'] is! String ||
      (error['message'] as String).isEmpty ||
      error['retryable'] is! bool)
    _invalid();
  if (error.containsKey('details')) _object(error['details']);
  return GuestRemoteException._(
    error['code'] as String,
    error['retryable'] as bool,
  );
}

final class _GuestPendingRequest {
  _GuestPendingRequest(this.request, this.deadline);
  final Map<String, Object?> request;
  final GuestBridgeDeadline deadline;
  final Completer<Map<String, Object?>> result =
      Completer<Map<String, Object?>>();
  Timer? timer;
}

/// Pure validation also used before committing a diagnostic start marker.
JsonObjectValue validateGuestArtifactCollectRequest(JsonObjectValue request) {
  final params = request.toJson();
  _keys(params, {'paths', 'max_total_bytes'}, optional: {'follow_symlinks'});
  final paths = params['paths'];
  final maximum = params['max_total_bytes'];
  if (paths is! List ||
      paths.isEmpty ||
      paths.length > 256 ||
      maximum is! num ||
      !maximum.isFinite ||
      maximum < 0 ||
      maximum % 1 != 0 ||
      (maximum is double && maximum >= 9223372036854775808.0) ||
      (params.containsKey('follow_symlinks') &&
          params['follow_symlinks'] != false))
    _invalid();
  for (final value in paths) {
    final path = _object(value);
    _keys(path, {'path', 'kind'}, optional: {'content_type'});
    for (final (key, bound) in [
      ('path', 4096),
      ('kind', 64),
      ('content_type', 255),
    ]) {
      if (key == 'content_type' && !path.containsKey(key)) continue;
      final text = path[key];
      if (text is! String || text.isEmpty || text.runes.length > bound)
        _invalid();
    }
  }
  return JsonObjectValue.fromJson({
    ...params,
    'max_total_bytes': maximum.toInt(),
  });
}

GuestSessionException _failure(Object error) => error is GuestSessionException
    ? error
    : GuestSessionException(
        error is GuestBridgeException
            ? switch (error.code) {
                GuestBridgeFailure.deadlineExpired =>
                  GuestSessionFailure.deadlineExpired,
                GuestBridgeFailure.closed => GuestSessionFailure.disconnected,
                GuestBridgeFailure.limitExceeded =>
                  GuestSessionFailure.limitExceeded,
                GuestBridgeFailure.unavailable ||
                GuestBridgeFailure.unsupported =>
                  GuestSessionFailure.unavailable,
                _ => GuestSessionFailure.invalidMessage,
              }
            : GuestSessionFailure.invalidMessage,
      );
Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) _invalid();
  return value;
}

void _keys(
  Map<String, Object?> value,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!value.keys.toSet().containsAll(required) ||
      !value.keys.every({...required, ...optional}.contains))
    _invalid();
}

Set<String> _capabilitySet(Object? value) {
  if (value is! List ||
      !value.every(_capabilities.contains) ||
      value.toSet().length != value.length)
    _invalid();
  return value.cast<String>().toSet();
}

bool _same(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
Never _invalid() =>
    throw const GuestSessionException(GuestSessionFailure.invalidMessage);
Never _mismatch() =>
    throw const GuestSessionException(GuestSessionFailure.capabilityMismatch);

/// Inspect decoded member names before building maps. Preserve the original
/// binding number rather than trusting a rounded JSON double.
Uint8List _encodeMessage(Map<String, Object?> message) {
  final buffer = _GuestFrameBuffer();
  JsonUtf8Encoder(null, null, 8192).startChunkedConversion(buffer)
    ..add(message)
    ..close();
  return buffer.bytes.takeBytes();
}

/// Stop encoding at the frame budget, before admitting a request or allocating
/// an entire oversized argv/environment message. Buffers are owned by the codec.
final class _GuestFrameBuffer implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > _maxFrameBytes) {
      throw const GuestSessionException(GuestSessionFailure.limitExceeded);
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
