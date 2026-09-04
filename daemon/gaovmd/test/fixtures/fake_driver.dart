import 'dart:async';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';
import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  final socketPath = _optionValue(args, '--socket-path');
  final failVmStartWhen = _optionValue(args, '--fail-vm-start-when');
  final methodLogPath = _optionValue(args, '--method-log');
  final authToken = Platform.environment['GAOVM_AUTH_TOKEN'];
  if (socketPath == null || authToken == null || authToken.isEmpty) {
    stderr.writeln('fake_driver requires --socket-path and GAOVM_AUTH_TOKEN');
    exitCode = 64;
    return;
  }

  final socketFile = File(socketPath);
  await socketFile.parent.create(recursive: true);
  if (await socketFile.exists()) {
    await socketFile.delete();
  }

  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  final socket = await server.first;
  final channel = RpcChannel(socket);
  var vmState = 'stopped';

  channel.onRequest = (request) async {
    final method = request['method'];
    final id = request['id'];
    if (methodLogPath != null && method is String && method.startsWith('vm.')) {
      await File(
        methodLogPath,
      ).writeAsString('$method\n', mode: FileMode.append, flush: true);
    }
    if (method == 'hello') {
      final params = JsonValue.asMap(request['params']);
      if (params['authToken'] != authToken) {
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.authFailed,
          message: 'Auth token mismatch',
        );
      }
      return JsonRpcProtocol.result(
        id: id,
        result: {
          'protocol': DriverSupervisor.protocolVersion,
          'capabilities': DriverSupervisor.daemonCapabilities,
          'acceptedCapabilities': DriverSupervisor.requiredCapabilities,
        },
      );
    }
    if (method == 'ping') {
      return JsonRpcProtocol.result(id: id, result: {'ok': true});
    }
    if (method == 'vm.status') {
      return JsonRpcProtocol.result(id: id, result: {'state': vmState});
    }
    if (method == 'vm.configure') {
      vmState = 'configured';
      return JsonRpcProtocol.result(id: id, result: {'state': vmState});
    }
    if (method == 'vm.start') {
      if (failVmStartWhen != null && await File(failVmStartWhen).exists()) {
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.internalError,
          message: 'Injected vm.start failure',
        );
      }
      vmState = 'running';
      return JsonRpcProtocol.result(id: id, result: {'state': vmState});
    }
    if (method == 'vm.stop') {
      vmState = 'stopped';
      return JsonRpcProtocol.result(id: id, result: {'state': vmState});
    }
    if (method == 'test.crash') {
      Timer(const Duration(milliseconds: 50), () => exit(42));
      return JsonRpcProtocol.result(id: id, result: {'ok': true});
    }
    return JsonRpcProtocol.error(
      id: id,
      code: JsonRpcErrorCode.methodNotFound,
      message: 'Unsupported fake driver method: $method',
    );
  };

  final hello = await channel.sendRequest(
    'hello',
    params: {
      'protocol': DriverSupervisor.protocolVersion,
      'authToken': authToken,
      'capabilities': DriverSupervisor.daemonCapabilities,
      'requiredCapabilities': DriverSupervisor.requiredCapabilities,
    },
  );
  if (hello['error'] != null) {
    stderr.writeln('daemon rejected fake driver hello: ${hello['error']}');
    exitCode = 1;
    await channel.close();
    await server.close();
    return;
  }

  await channel.done;
  await server.close();
}

String? _optionValue(List<String> args, String option) {
  final index = args.indexOf(option);
  if (index < 0 || index + 1 >= args.length) {
    return null;
  }
  return args[index + 1];
}
