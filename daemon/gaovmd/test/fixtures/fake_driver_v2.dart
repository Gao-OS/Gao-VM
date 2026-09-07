import 'dart:async';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';

Future<void> main(List<String> args) async {
  final values = <String, String>{};
  for (var index = 0; index < args.length; index += 2) {
    if (index + 1 >= args.length) exit(64);
    values[args[index]] = args[index + 1];
  }
  final vmId = values['--vm-id']!;
  final generation = int.parse(values['--generation']!);
  final socketPath = values['--socket-path']!;
  final operationId = values['--operation-id'];
  final scenario = values['--scenario'] ?? 'normal';
  final token = Platform.environment['GAOVM_AUTH_TOKEN']!;
  if (scenario == 'prelisten-log') {
    stdout.add(List<int>.filled(2 * 1024 * 1024, 80));
    await stdout.flush();
  }
  final listener = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  await Process.run('/bin/chmod', ['600', socketPath]);
  final socket = await listener.first;
  final codec = const LengthPrefixedJsonRpcCodec();
  Future<void> tail = Future<void>.value();
  Future<void> send(Map<String, Object?> value) {
    final completer = Completer<void>();
    tail = tail
        .then((_) async {
          socket.add(codec.encodeObject(value));
          await socket.flush();
        })
        .then(completer.complete, onError: completer.completeError);
    return completer.future;
  }

  var nextId = 0;
  final helloVm = scenario == 'bad-generation' ? vmId : vmId;
  final helloGeneration = scenario == 'bad-generation'
      ? generation + 1
      : generation;
  await send({
    'jsonrpc': '2.0',
    'id': nextId++,
    'method': 'session.hello',
    'params': {
      'protocol_version': scenario == 'bad-protocol'
          ? 'gaovm.driver.bad'
          : 'gaovm.driver.v2',
      'peer_role': 'driver',
      'vm_id': helloVm,
      'driver_generation': helloGeneration,
      'operation_id': null,
      'auth_token': scenario == 'bad-token' ? '${token}x' : token,
      'offered_capabilities': _capabilities,
      'required_capabilities': _capabilities,
      'implementation': {'name': 'fake-driver-v2', 'version': '1'},
    },
  });
  if (scenario == 'preauth-event') {
    await _event(send, vmId, generation, operationId, 'running');
  }

  var driverHelloAccepted = false;
  var daemonHelloAccepted = false;
  await for (final message in codec.decodeObjectStream(socket)) {
    final method = message['method'];
    if (method == 'session.hello') {
      final params = Map<String, Object?>.from(message['params']! as Map);
      final accepted =
          params['protocol_version'] == 'gaovm.driver.v2' &&
          params['peer_role'] == 'daemon' &&
          params['vm_id'] == vmId &&
          params['driver_generation'] == generation &&
          params['operation_id'] == null &&
          params['auth_token'] == token;
      if (!accepted) exit(65);
      daemonHelloAccepted = true;
      await send({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'protocol_version': 'gaovm.driver.v2',
          'vm_id': vmId,
          'driver_generation': generation,
          'operation_id': null,
          'accepted_capabilities': _capabilities,
        },
      });
      continue;
    }
    if (message.containsKey('result') || message.containsKey('error')) {
      if (message['id'] == 0 && message['error'] == null) {
        driverHelloAccepted = true;
      }
      continue;
    }
    if (!driverHelloAccepted || !daemonHelloAccepted) exit(66);
    final params = Map<String, Object?>.from(message['params']! as Map);
    final correlatedOperation = params['operation_id'] ?? operationId;
    if (method == 'session.ping' && scenario == 'heartbeat-hang') continue;
    if (method == 'runtime.start' && scenario == 'hang-start') continue;
    if ((method == 'runtime.stop' || method == 'runtime.kill') &&
        scenario == 'ignore-stop') {
      continue;
    }
    await send({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': {
        'vm_id': vmId,
        'driver_generation': generation,
        'operation_id': correlatedOperation,
        'status':
            method == 'runtime.start' ||
                method == 'runtime.stop' ||
                method == 'runtime.kill'
            ? 'accepted'
            : 'succeeded',
        'data': null,
      },
    });
    if (method == 'runtime.configure') {
      await _event(send, vmId, generation, correlatedOperation, 'configured');
    } else if (method == 'runtime.start') {
      await _event(send, vmId, generation, correlatedOperation, 'starting');
      await _event(send, vmId, generation, correlatedOperation, 'running');
      if (scenario == 'large-log') {
        stdout.add(List<int>.filled(200000, 65));
        await stdout.flush();
      } else {
        stdout.writeln('fake driver running $vmId generation=$generation');
      }
    } else if (method == 'runtime.stop' || method == 'runtime.kill') {
      await _event(send, vmId, generation, correlatedOperation, 'stopping');
      if (method == 'runtime.stop' && scenario == 'accepted-stop') continue;
      await _event(send, vmId, generation, correlatedOperation, 'stopped');
      if (method == 'runtime.stop') {
        await send({
          'jsonrpc': '2.0',
          'method': 'runtime.clean_shutdown',
          'params': {
            'vm_id': vmId,
            'driver_generation': generation,
            'operation_id': correlatedOperation,
            'occurred_at': DateTime.now().toUtc().toIso8601String(),
            'clean_shutdown': true,
          },
        });
      }
      await tail;
      await socket.close();
      await listener.close();
      exit(method == 'runtime.stop' ? 0 : 137);
    }
  }
}

Future<void> _event(
  Future<void> Function(Map<String, Object?>) send,
  String vmId,
  int generation,
  Object? operationId,
  String state,
) => send({
  'jsonrpc': '2.0',
  'method': 'runtime.state_changed',
  'params': {
    'vm_id': vmId,
    'driver_generation': generation,
    'operation_id': operationId,
    'occurred_at': DateTime.now().toUtc().toIso8601String(),
    'runtime_state': state,
  },
});

const _capabilities = [
  'runtime.configure',
  'runtime.start',
  'runtime.stop',
  'runtime.kill',
  'runtime.status',
];
