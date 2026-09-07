import 'dart:async';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';

typedef DriverRpcRequestHandler =
    Future<Map<String, Object?>?> Function(Map<String, Object?> request);
typedef DriverRpcNotificationHandler =
    void Function(Map<String, Object?> notification);

final class DriverRpcChannel {
  DriverRpcChannel(
    this._socket, {
    required DriverRpcRequestHandler onRequest,
    required DriverRpcNotificationHandler onNotification,
    LengthPrefixedJsonRpcCodec codec = const LengthPrefixedJsonRpcCodec(),
  }) : _onRequest = onRequest,
       _onNotification = onNotification,
       _codec = codec {
    _subscription = _codec
        .decodeObjectStream(_socket)
        .listen(
          _onMessage,
          onError: _closeWithError,
          onDone: () =>
              _closeWithError(StateError('driver control socket EOF')),
          cancelOnError: true,
        );
  }

  final Socket _socket;
  final DriverRpcRequestHandler _onRequest;
  final DriverRpcNotificationHandler _onNotification;
  final LengthPrefixedJsonRpcCodec _codec;
  final Map<Object, Completer<Map<String, Object?>>> _pending = {};
  final Completer<Object?> _done = Completer<Object?>();
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void> _writeTail = Future<void>.value();
  int _nextId = 0;
  bool _closed = false;

  Future<Object?> get done => _done.future;
  int get pendingRequestCount => _pending.length;

  Future<Map<String, Object?>> sendRequest(
    Map<String, Object?> Function(int id) build,
  ) {
    if (_closed) return Future.error(StateError('driver channel is closed'));
    final id = _nextId++;
    if (_nextId > 9007199254740991) _nextId = 0;
    final message = build(id);
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send(message).catchError((Object error, StackTrace stackTrace) {
      if (identical(_pending.remove(id), completer) && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> send(Map<String, Object?> message) => _send(message);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    await _subscription?.cancel();
    _subscription = null;
    _completePending(StateError('driver channel closed'));
    if (!_done.isCompleted) _done.complete(null);
  }

  void _onMessage(Map<String, Object?> message) {
    if (message['jsonrpc'] != '2.0') {
      _closeWithError(StateError('invalid JSON-RPC version'));
      return;
    }
    final method = message['method'];
    if (method is String) {
      if (message.containsKey('id')) {
        unawaited(_dispatchRequest(message));
      } else {
        try {
          _onNotification(message);
        } catch (error) {
          _closeWithError(error);
        }
      }
      return;
    }
    final id = message['id'];
    if (id == null ||
        (!message.containsKey('result') && !message.containsKey('error'))) {
      _closeWithError(StateError('invalid JSON-RPC object'));
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) {
      _closeWithError(StateError('unexpected driver response id: $id'));
      return;
    }
    completer.complete(message);
  }

  Future<void> _dispatchRequest(Map<String, Object?> request) async {
    try {
      final response = await _onRequest(request);
      if (response != null) await _send(response);
    } catch (error) {
      _closeWithError(error);
    }
  }

  Future<void> _send(Map<String, Object?> message) {
    if (_closed) return Future.error(StateError('driver channel is closed'));
    final completer = Completer<void>();
    _writeTail = _writeTail
        .catchError((Object _) {})
        .then((_) async {
          if (_closed) throw StateError('driver channel is closed');
          _socket.add(_codec.encodeObject(message));
          await _socket.flush();
        })
        .then(completer.complete, onError: completer.completeError);
    return completer.future;
  }

  void _closeWithError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _completePending(error, stackTrace);
    if (!_done.isCompleted) _done.complete(error);
  }

  void _completePending(Object error, [StackTrace? stackTrace]) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
  }
}
