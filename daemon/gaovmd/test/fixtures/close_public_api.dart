import 'dart:io';

import 'package:gaovmd/src/public_api_server.dart';

Future<void> main(List<String> args) async {
  final mode = args[1];
  final listener = _FaultListenerFactory();
  final server = PublicApiServer(
    socketPath: args.first,
    openApiDocument: const {},
    systemHealth: _Health(),
    listenerFactory: listener,
    beforeSocketQuarantineRename: mode == 'cleanup-error'
        ? (_, _, _) async =>
              throw FileSystemException('injected cleanup failure')
        : null,
  );
  await server.start();
  switch (mode) {
    case 'close':
      await server.close();
    case 'error' || 'cleanup-error':
      listener.emitError();
    case 'eof':
      listener.emitDone();
    default:
      throw ArgumentError.value(mode, 'mode');
  }
  await server.done;
  if (server.isRunning ||
      (mode == 'close'
          ? server.fatalError != null
          : server.fatalError == null)) {
    throw StateError('API close did not settle its lifecycle');
  }
  stdout.writeln('closed');
}

final class _FaultListenerFactory implements PublicApiListenerFactory {
  late PublicApiListenerError _onError;
  late void Function() _onDone;

  @override
  PublicApiBoundListener listen({
    required ServerSocket socket,
    required void Function(HttpRequest request) onRequest,
    required PublicApiListenerError onError,
    required void Function() onDone,
  }) {
    _onError = onError;
    _onDone = onDone;
    return const DartPublicApiListenerFactory().listen(
      socket: socket,
      onRequest: onRequest,
      onError: onError,
      onDone: onDone,
    );
  }

  void emitError() =>
      _onError(StateError('injected listener error'), StackTrace.current);
  void emitDone() => _onDone();
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});

  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
