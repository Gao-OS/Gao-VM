import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

import 'driver_runtime_layout.dart';
import 'runtime_driver.dart';

enum GuestBridgeStreamKind { control, binary }

enum GuestBridgeFailure {
  unavailable,
  limitExceeded,
  authenticationFailed,
  invalidResponse,
  deadlineExpired,
  closed,
  transportFailure,
  unsupported,
}

final class GuestBridgeException implements Exception {
  const GuestBridgeException(this.code);
  final GuestBridgeFailure code;
  @override
  String toString() => 'private guest bridge failed: ${code.name}';
}

/// Optional internal transport capability, separate from VM lifecycle commands.
abstract interface class GuestBridgeProvider {
  /// Failure must join the original opening worker/descriptor cleanup before
  /// returning to an owner that will reuse its binary transfer admission.
  Future<GuestBridgeChannel> openGuestChannel({
    required GuestBridgeStreamKind streamKind,
    required RequestId requestId,
    required OperationId? operationId,
    required GuestBridgeDeadline deadline,
  });
}

/// One monotonic budget, shared across all reads/writes in a protocol phase.
final class GuestBridgeDeadline {
  GuestBridgeDeadline.after(this._budget) : _parent = null {
    if (_budget <= Duration.zero)
      throw ArgumentError('deadline must be positive');
  }
  GuestBridgeDeadline._(this._budget, this._parent);
  final Duration _budget;
  final GuestBridgeDeadline? _parent;
  final Stopwatch _clock = Stopwatch()..start();

  Duration get remaining {
    final own = _budget - _clock.elapsed;
    final parent = _parent?.remaining;
    final value = parent != null && parent < own ? parent : own;
    return value > Duration.zero ? value : Duration.zero;
  }

  GuestBridgeDeadline capped(Duration maximum) =>
      GuestBridgeDeadline._(maximum, this);
  void requireLive() {
    if (remaining == Duration.zero)
      throw const GuestBridgeException(GuestBridgeFailure.deadlineExpired);
  }
}

/// Owned by one authenticated original driver session, never a public endpoint.
/// Callers must negotiate and validate guest.status before using this transport.
final class GuestBridgeClient {
  GuestBridgeClient({
    required this.paths,
    required this.correlation,
    required String authToken,
    required bool Function() isSessionActive,
    required Future<Object?> sessionClosed,
    Future<void> Function(OperationId?)? prepareOpening,
    int? expectedPeerUID,
  }) : _authToken = authToken,
       _isSessionActive = isSessionActive,
       _prepareOpening = prepareOpening,
       _expectedPeerUID = expectedPeerUID ?? _effectiveUID() {
    if (authToken.isEmpty || utf8.encode(authToken).length > 512) {
      throw ArgumentError('invalid private bridge credential');
    }
    final directory = Directory(paths.directory);
    if (!paths.directory.startsWith('/') ||
        directory.uri.pathSegments.where((part) => part.isNotEmpty).last !=
            '${correlation.driverGeneration}' ||
        directory.parent.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last !=
            correlation.vmId.value ||
        paths.socketPath != '${paths.directory}/driver.sock' ||
        utf8.encode(paths.guestSocketPath).length >= 104) {
      throw ArgumentError('invalid private bridge generation layout');
    }
    sessionClosed.then(
      (_) {
        unawaited(close());
      },
      onError: (Object _, StackTrace __) {
        unawaited(close());
      },
    );
  }

  final DriverRuntimePaths paths;
  final DriverCorrelation correlation;
  final String _authToken;
  final bool Function() _isSessionActive;
  final Future<void> Function(OperationId?)? _prepareOpening;
  final int _expectedPeerUID;
  final Set<_GuestBridgeOpening> _openings = {};
  final Set<GuestBridgeChannel> _channels = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  bool get _active => !_closed && _isSessionActive();

  Future<GuestBridgeChannel> open({
    required GuestBridgeStreamKind streamKind,
    required RequestId requestId,
    required OperationId? operationId,
    required GuestBridgeDeadline deadline,
  }) => _beginOpen(streamKind, requestId, operationId, deadline).$1;

  /// The low-level [open] exposes caller failure promptly while retaining its
  /// own eight-opening limit. A composed owner uses this joined boundary before
  /// returning its additional per-VM/global admission or allowing replacement.
  Future<GuestBridgeChannel> openAndJoin({
    required GuestBridgeStreamKind streamKind,
    required RequestId requestId,
    required OperationId? operationId,
    required GuestBridgeDeadline deadline,
  }) async {
    final (result, retired) = _beginOpen(
      streamKind,
      requestId,
      operationId,
      deadline,
    );
    try {
      return await result;
    } catch (_) {
      await retired;
      rethrow;
    }
  }

  (Future<GuestBridgeChannel>, Future<void>) _beginOpen(
    GuestBridgeStreamKind streamKind,
    RequestId requestId,
    OperationId? operationId,
    GuestBridgeDeadline deadline,
  ) {
    if (!_active)
      return (
        Future.error(const GuestBridgeException(GuestBridgeFailure.closed)),
        Future<void>.value(),
      );
    if (streamKind == GuestBridgeStreamKind.binary && operationId == null) {
      return (
        Future.error(
          ArgumentError('binary bridge requires operation correlation'),
        ),
        Future<void>.value(),
      );
    }
    if (_openings.length >= 8)
      return (
        Future.error(
          const GuestBridgeException(GuestBridgeFailure.limitExceeded),
        ),
        Future<void>.value(),
      );
    final opening = _GuestBridgeOpening(
      this,
      streamKind,
      requestId,
      operationId,
      deadline.capped(const Duration(seconds: 5)),
    );
    _openings.add(opening);
    unawaited(opening.run());
    return (opening.result.future, opening.finished.future);
  }

  Future<void> close() => _closeFuture ??= _closeOnce();
  Future<void> _closeOnce() async {
    _closed = true;
    final openings = _openings.toList();
    for (final opening in openings) {
      opening.cancel();
    }
    final channels = _channels.toList();
    await Future.wait<void>([
      for (final opening in openings) opening.finished.future,
      for (final channel in channels)
        () async {
          await channel.close();
          await channel.closed;
        }(),
    ]);
  }
}

final class _GuestBridgeOpening {
  _GuestBridgeOpening(
    this.owner,
    this.kind,
    this.requestId,
    this.operationId,
    this.deadline,
  );
  final GuestBridgeClient owner;
  final GuestBridgeStreamKind kind;
  final RequestId requestId;
  final OperationId? operationId;
  final GuestBridgeDeadline deadline;
  final result = Completer<GuestBridgeChannel>();
  final finished = Completer<void>();
  ConnectionTask<RawSocket>? _task;
  RawSocket? _socket;
  GuestBridgeChannel? _channel;
  Timer? _timer;
  bool _cancelled = false;

  void requireLive() {
    if (_cancelled || !owner._active)
      throw const GuestBridgeException(GuestBridgeFailure.closed);
    deadline.requireLive();
  }

  void cancel([GuestBridgeFailure reason = GuestBridgeFailure.closed]) {
    _cancelled = true;
    _task?.cancel();
    unawaited(_channel?.close(reason));
    if (!result.isCompleted) result.completeError(GuestBridgeException(reason));
  }

  Future<void> run() async {
    var handedOff = false;
    try {
      requireLive();
      _timer = Timer(
        deadline.remaining,
        () => cancel(GuestBridgeFailure.deadlineExpired),
      );
      // Retain admission until the actual status RPC/worker settles, even when
      // its caller deadline has already failed. A late result cannot send bytes.
      await owner._prepareOpening?.call(operationId);
      requireLive();
      await _requirePrivateEndpoint(owner.paths);
      requireLive();
      _task = await RawSocket.startConnect(
        InternetAddress(
          owner.paths.guestSocketPath,
          type: InternetAddressType.unix,
        ),
        0,
      );
      if (_cancelled) _task!.cancel();
      final socket = _socket = await _task!.socket;
      requireLive();
      socket.readEventsEnabled = false;
      socket.writeEventsEnabled = false;
      if (_peerUID(socket) != owner._expectedPeerUID) {
        throw const GuestBridgeException(
          GuestBridgeFailure.authenticationFailed,
        );
      }
      final channel = _channel = GuestBridgeChannel._(
        socket,
        () => owner._active,
      );
      _socket = null;
      owner._channels.add(channel);
      channel.closed.then((_) => owner._channels.remove(channel));
      final expected = <String, Object?>{
        'protocol_version': 'gaovm.bridge.v1',
        'vm_id': owner.correlation.vmId.value,
        'driver_generation': owner.correlation.driverGeneration,
        'request_id': requestId.value,
        'operation_id': operationId?.value,
        'stream_kind': kind.name,
      };
      final payload = utf8.encode(
        jsonEncode({
          ...expected,
          'kind': 'open',
          'auth_token': owner._authToken,
        }),
      );
      if (payload.length > 4096)
        throw const GuestBridgeException(GuestBridgeFailure.invalidResponse);
      final frame = Uint8List(4 + payload.length);
      ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
      frame.setRange(4, frame.length, payload);
      await channel.write(frame, deadline: deadline);
      final prefix = await channel.readExact(4, deadline: deadline);
      final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
      if (length < 1 || length > 4096)
        throw const GuestBridgeException(GuestBridgeFailure.invalidResponse);
      final response = await channel.readExact(length, deadline: deadline);
      _validateResponse(response, expected);
      requireLive();
      handedOff = true;
      result.complete(channel);
    } catch (error) {
      if (!result.isCompleted) {
        result.completeError(
          error is GuestBridgeException
              ? error
              : const GuestBridgeException(GuestBridgeFailure.transportFailure),
        );
      }
    } finally {
      _timer?.cancel();
      if (!handedOff) {
        await _channel?.close();
        final socket = _socket;
        if (socket != null) {
          socket.shutdown(SocketDirection.both);
          await socket.close();
        }
      }
      owner._openings.remove(this);
      finished.complete();
    }
  }
}

/// Single-reader/single-writer bounded byte channel; no guest RPC parsing here.
final class GuestBridgeChannel {
  GuestBridgeChannel._(this._socket, this._isActive) {
    _subscription = _socket.listen(
      _event,
      onError: (Object _) {
        unawaited(close(GuestBridgeFailure.transportFailure));
      },
      onDone: () {
        unawaited(close());
      },
    );
  }
  final RawSocket _socket;
  final bool Function() _isActive;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final Completer<void> _closed = Completer<void>();
  Future<void>? _closeFuture;
  Completer<Uint8List>? _reading;
  Uint8List? _input;
  int _inputOffset = 0;
  GuestBridgeDeadline? _readDeadline;
  Timer? _readTimer;
  Completer<void>? _writing;
  Uint8List? _output;
  int _outputOffset = 0;
  GuestBridgeDeadline? _writeDeadline;
  Timer? _writeTimer;

  Future<void> get closed => _closed.future;
  bool get isActive => _closeFuture == null && _isActive();

  void _requireActive() {
    if (!isActive) throw const GuestBridgeException(GuestBridgeFailure.closed);
  }

  Future<Uint8List> readExact(
    int count, {
    required GuestBridgeDeadline deadline,
  }) => _readBytes(count, deadline);

  /// Wait for only the first byte of an idle control frame. No idle heartbeat
  /// requirement is added; the framing owner starts its budget on this byte.
  /// EOF/owner closure still interrupts this one-byte, single-reader wait.
  Future<Uint8List> readFrameStart() => _readBytes(1, null);

  Future<Uint8List> _readBytes(int count, GuestBridgeDeadline? deadline) {
    _requireActive();
    deadline?.requireLive();
    if (count < 1 || count > 8192 || _reading != null)
      throw ArgumentError('bridge reads must be bounded and serialized');
    final completion = _reading = Completer<Uint8List>();
    _input = Uint8List(count);
    _inputOffset = 0;
    _readDeadline = deadline;
    _readTimer = deadline == null
        ? null
        : Timer(deadline.remaining, () {
            unawaited(close(GuestBridgeFailure.deadlineExpired));
          });
    _socket.readEventsEnabled = true;
    _read();
    return completion.future;
  }

  Future<void> write(Uint8List bytes, {required GuestBridgeDeadline deadline}) {
    _requireActive();
    deadline.requireLive();
    if (bytes.isEmpty || bytes.length > 8192 || _writing != null)
      throw ArgumentError('bridge writes must be bounded and serialized');
    final completion = _writing = Completer<void>();
    _output = Uint8List.fromList(bytes);
    _outputOffset = 0;
    _writeDeadline = deadline.capped(const Duration(seconds: 5));
    _writeTimer = Timer(_writeDeadline!.remaining, () {
      unawaited(close(GuestBridgeFailure.deadlineExpired));
    });
    _write();
    return completion.future;
  }

  void _event(RawSocketEvent event) {
    if (_closeFuture != null) return;
    if (event == RawSocketEvent.read) {
      _read();
    } else if (event == RawSocketEvent.write) {
      _write();
    } else {
      unawaited(close());
    }
  }

  void _read() {
    if (_reading == null || _closeFuture != null) return;
    try {
      _requireActive();
      _readDeadline?.requireLive();
      final bytes = _socket.read(_input!.length - _inputOffset);
      if (bytes == null) return;
      _input!.setRange(_inputOffset, _inputOffset + bytes.length, bytes);
      _inputOffset += bytes.length;
      if (_inputOffset == _input!.length) {
        final completion = _reading!;
        final value = _input!;
        _reading = null;
        _input = null;
        _readTimer?.cancel();
        _readDeadline = null;
        _socket.readEventsEnabled = false;
        completion.complete(value);
      }
    } catch (error) {
      unawaited(
        close(
          error is GuestBridgeException
              ? error.code
              : GuestBridgeFailure.transportFailure,
        ),
      );
    }
  }

  void _write() {
    if (_writing == null || _closeFuture != null) return;
    try {
      _requireActive();
      _writeDeadline!.requireLive();
      final count = _socket.write(
        _output!,
        _outputOffset,
        _output!.length - _outputOffset,
      );
      _outputOffset += count;
      if (_outputOffset == _output!.length) {
        final completion = _writing!;
        _writing = null;
        _output = null;
        _writeTimer?.cancel();
        _writeDeadline = null;
        _socket.writeEventsEnabled = false;
        completion.complete();
      } else {
        _socket.writeEventsEnabled = true;
      }
    } catch (error) {
      unawaited(
        close(
          error is GuestBridgeException
              ? error.code
              : GuestBridgeFailure.transportFailure,
        ),
      );
    }
  }

  Future<void> close([GuestBridgeFailure reason = GuestBridgeFailure.closed]) =>
      _closeFuture ??= _closeOnce(reason);
  Future<void> _closeOnce(GuestBridgeFailure reason) async {
    _readTimer?.cancel();
    _writeTimer?.cancel();
    _reading?.completeError(GuestBridgeException(reason));
    _writing?.completeError(GuestBridgeException(reason));
    _reading = null;
    _writing = null;
    _input = null;
    _output = null;
    _socket.shutdown(SocketDirection.both);
    await _socket.close();
    await _subscription.cancel();
    _closed.complete();
  }
}

void _validateResponse(Uint8List payload, Map<String, Object?> expected) {
  try {
    final value = _FlatBridgeResponse(utf8.decode(payload)).decode();
    final kind = value['kind'];
    final keys = {...expected.keys, 'kind', if (kind == 'error') 'code'};
    if ((kind != 'ready' && kind != 'error') ||
        value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        !expected.entries.every((entry) => value[entry.key] == entry.value)) {
      throw const GuestBridgeException(GuestBridgeFailure.invalidResponse);
    }
    if (kind == 'error') {
      throw GuestBridgeException(switch (value['code']) {
        'GUEST_CHANNEL_UNAVAILABLE' => GuestBridgeFailure.unavailable,
        'CHANNEL_LIMIT_EXCEEDED' => GuestBridgeFailure.limitExceeded,
        _ => GuestBridgeFailure.invalidResponse,
      });
    }
  } on GuestBridgeException {
    rethrow;
  } catch (_) {
    throw const GuestBridgeException(GuestBridgeFailure.invalidResponse);
  }
}

/// Decode member names before inserting them: a normal JSON map loses duplicates.
/// Bridge headers contain only scalars; nested values have no valid wire meaning.
final class _FlatBridgeResponse {
  _FlatBridgeResponse(this.source);
  final String source;
  int offset = 0;

  Map<String, Object?> decode() {
    final result = <String, Object?>{};
    _take(123);
    if (!_consume(125)) {
      do {
        final key = _string();
        if (result.containsKey(key)) _invalid();
        _take(58);
        _space();
        Object? value;
        if (offset < source.length && source.codeUnitAt(offset) == 34) {
          value = _string();
        } else {
          final start = offset;
          while (offset < source.length &&
              ![9, 10, 13, 32, 44, 125].contains(source.codeUnitAt(offset))) {
            offset++;
          }
          final token = source.substring(start, offset);
          value = key == 'driver_generation'
              ? _generation(token)
              : jsonDecode(token);
          if (value is Map || value is List) _invalid();
        }
        result[key] = value;
      } while (_consume(44));
      _take(125);
    }
    _space();
    if (offset != source.length) _invalid();
    return result;
  }

  String _string() {
    _space();
    final start = offset;
    _take(34);
    while (offset < source.length) {
      final unit = source.codeUnitAt(offset++);
      if (unit == 34) {
        return jsonDecode(source.substring(start, offset)) as String;
      }
      if (unit == 92) offset++;
    }
    _invalid();
  }

  void _space() {
    while (offset < source.length &&
        [9, 10, 13, 32].contains(source.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool _consume(int unit) {
    _space();
    if (offset >= source.length || source.codeUnitAt(offset) != unit) {
      return false;
    }
    offset++;
    return true;
  }

  void _take(int unit) {
    if (!_consume(unit)) _invalid();
  }

  int _generation(String token) {
    // Validate the original decimal coefficient/exponent, never a rounded double.
    final match = RegExp(
      r'^(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$',
    ).firstMatch(token);
    if (match == null) _invalid();
    final fraction = match.group(2) ?? '';
    final exponent = int.tryParse(match.group(3) ?? '0');
    if (exponent == null || exponent < -4096 || exponent > 4096) _invalid();
    var digits = '${match.group(1)}$fraction'.replaceFirst(RegExp(r'^0+'), '');
    var shift = exponent - fraction.length;
    while (digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
      shift++;
    }
    if (digits.isEmpty || shift < 0 || digits.length + shift > 16) _invalid();
    final value = int.parse('$digits${'0' * shift}');
    if (value < 1 || value > 9007199254740991) _invalid();
    return value;
  }

  Never _invalid() =>
      throw const GuestBridgeException(GuestBridgeFailure.invalidResponse);
}

Future<void> _requirePrivateEndpoint(DriverRuntimePaths paths) async {
  for (final path in [
    paths.directory,
    Directory(paths.directory).parent.path,
  ]) {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        (await FileStat.stat(path)).mode & 0xfff != 0x1c0) {
      throw const GuestBridgeException(GuestBridgeFailure.authenticationFailed);
    }
  }
  if (await FileSystemEntity.type(paths.guestSocketPath, followLinks: false) !=
          FileSystemEntityType.unixDomainSock ||
      (await FileStat.stat(paths.guestSocketPath)).mode & 0xfff != 0x180) {
    throw const GuestBridgeException(GuestBridgeFailure.authenticationFailed);
  }
}

int _effectiveUID() => ffi.DynamicLibrary.process()
    .lookupFunction<ffi.Uint32 Function(), int Function()>('geteuid')();

int _peerUID(RawSocket socket) {
  if (Platform.isMacOS) {
    // Local SDK sys/un.h and sys/ucred.h: SOL_LOCAL / LOCAL_PEERCRED;
    // xucred is 76 bytes, version 0, uid at offset 4 on supported Darwin ABIs.
    final bytes = socket.getRawOption(RawSocketOption(0, 1, Uint8List(76)));
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.host) != 0)
      throw const GuestBridgeException(GuestBridgeFailure.authenticationFailed);
    return data.getUint32(4, Endian.host);
  }
  if (Platform.isLinux &&
      (ffi.Abi.current() == ffi.Abi.linuxX64 ||
          ffi.Abi.current() == ffi.Abi.linuxArm64)) {
    // Linux asm-generic/socket.h SO_PEERCRED; struct ucred in linux/socket.h.
    final bytes = socket.getRawOption(
      RawSocketOption(RawSocketOption.levelSocket, 17, Uint8List(12)),
    );
    return ByteData.sublistView(bytes).getUint32(4, Endian.host);
  }
  throw const GuestBridgeException(GuestBridgeFailure.unsupported);
}
