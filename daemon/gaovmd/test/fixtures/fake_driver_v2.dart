import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final bridgeScenario = scenario.startsWith('guest-bridge');
  final displayScenario = scenario == 'display-hold';
  final capabilities = [
    ..._capabilities,
    if (bridgeScenario) 'guest.status',
    if (displayScenario) ...['display.open', 'display.close', 'display.status'],
  ];
  ServerSocket? guestListener;
  final guestSockets = <Socket>[];
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
      'offered_capabilities': capabilities,
      'required_capabilities': _capabilities,
      'implementation': {'name': 'fake-driver-v2', 'version': '1'},
    },
  });
  if (scenario == 'preauth-event') {
    await _event(send, vmId, generation, operationId, 'running');
  }

  var driverHelloAccepted = false;
  var daemonHelloAccepted = false;
  Map<String, Object?>? heldDisplay;
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
          'accepted_capabilities': capabilities,
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
    if (displayScenario && method == 'display.open') {
      heldDisplay = {
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'vm_id': vmId,
          'driver_generation': generation,
          'operation_id': correlatedOperation,
          'status': 'succeeded',
          'data': {'display_state': 'open'},
        },
      };
      await send({
        'jsonrpc': '2.0',
        'method': 'display.state_changed',
        'params': {
          'vm_id': vmId,
          'driver_generation': generation,
          'operation_id': correlatedOperation,
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
          'display_state': 'opening',
        },
      });
      continue;
    }
    if (displayScenario && method == 'session.ping' && heldDisplay != null) {
      await send(heldDisplay);
      heldDisplay = null;
    }
    if (method == 'session.ping' &&
        (scenario == 'heartbeat-hang' || scenario.endsWith('heartbeat-hang')))
      continue;
    if (method == 'guest.status' && scenario == 'guest-bridge-status-hang')
      continue;
    if (method == 'runtime.start' && scenario == 'hang-start') continue;
    if ((method == 'runtime.stop' || method == 'runtime.kill') &&
        scenario == 'ignore-stop') {
      continue;
    }
    if (method == 'guest.status' && bridgeScenario && guestListener == null) {
      final guestPath = '${File(socketPath).parent.path}/guest.sock';
      guestListener = await ServerSocket.bind(
        InternetAddress(guestPath, type: InternetAddressType.unix),
        0,
      );
      final protected = await Process.run('/bin/chmod', ['600', guestPath]);
      if (protected.exitCode != 0) exit(67);
      guestListener.listen((peer) {
        guestSockets.add(peer);
        unawaited(_serveGuestBridge(peer, token, vmId, generation, scenario));
      });
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
        'data': method == 'guest.status' && bridgeScenario
            ? {
                'bridge_protocol_version':
                    scenario == 'guest-bridge-bad-version'
                    ? 'gaovm.bridge.unknown'
                    : 'gaovm.bridge.v1',
                'available': scenario == 'guest-bridge-unavailable'
                    ? false
                    : true,
                'vsock_port': scenario == 'guest-bridge-unavailable'
                    ? null
                    : scenario == 'guest-bridge-invalid-port'
                    ? 0
                    : 10777,
                if (scenario == 'guest-bridge-extra-status') 'extra': true,
              }
            : method == 'session.ping' && bridgeScenario
            ? {'bridge_connections': guestSockets.length}
            : null,
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
      for (final peer in guestSockets) {
        peer.destroy();
      }
      await guestListener?.close();
      await socket.close();
      await listener.close();
      exit(method == 'runtime.stop' ? 0 : 137);
    }
  }
  socket.destroy();
  for (final peer in guestSockets) {
    peer.destroy();
  }
  await guestListener?.close();
  await listener.close();
}

Future<void> _serveGuestBridge(
  Socket socket,
  String token,
  String vmId,
  int generation,
  String scenario,
) async {
  final input = StreamIterator<Uint8List>(socket);
  final pending = <int>[];
  Future<List<int>> read(int count) async {
    while (pending.length < count) {
      if (!await input.moveNext()) throw StateError('fixture EOF');
      pending.addAll(input.current);
    }
    final result = pending.sublist(0, count);
    pending.removeRange(0, count);
    return result;
  }

  try {
    final prefix = ByteData.sublistView(Uint8List.fromList(await read(4)));
    final count = prefix.getUint32(0, Endian.big);
    if (count < 1 || count > 4096) return;
    final opening = Map<String, Object?>.from(
      jsonDecode(utf8.decode(await read(count))) as Map,
    );
    if (opening['auth_token'] != token ||
        opening['vm_id'] != vmId ||
        opening['driver_generation'] != generation ||
        opening['kind'] != 'open')
      return;
    final ready = Map<String, Object?>.from(opening)
      ..remove('auth_token')
      ..['kind'] = 'ready';
    final payload = utf8.encode(jsonEncode(ready));
    final frame = Uint8List(4 + payload.length);
    ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
    frame.setRange(4, frame.length, payload);
    if (scenario.startsWith('guest-bridge-session')) {
      socket.add(frame);
      await socket.flush();
      Future<Map<String, Object?>> control() async {
        final prefix = ByteData.sublistView(Uint8List.fromList(await read(4)));
        final count = prefix.getUint32(0, Endian.big);
        if (count < 1 || count > 16 * 1024 * 1024)
          throw StateError('fixture frame');
        return Map<String, Object?>.from(
          jsonDecode(utf8.decode(await read(count))) as Map,
        );
      }

      final host = await control();
      if (host['protocol_version'] != 'gaovm.guest.v1' ||
          host['vm_id'] != vmId ||
          host['driver_generation'] != generation ||
          host['kind'] != 'request' ||
          host['method'] != 'session.hello' ||
          host['operation_id'] != null ||
          (host['params'] as Map)['peer_role'] != 'host')
        return;
      final common = Map<String, Object?>.from(host)..remove('params');
      await _guestReply(socket, {
        ...common,
        'kind': 'response',
        'result': {'accepted_capabilities': _guestCoreCapabilities},
      });
      await _guestReply(socket, {
        ...common,
        'id': 'guest-hello',
        'kind': 'request',
        'params': {
          'peer_role': 'guest',
          'offered_capabilities': _guestCoreCapabilities,
          'required_capabilities': _guestCoreCapabilities,
        },
      });
      final ack = await control();
      if (ack['kind'] != 'response' || ack['id'] != 'guest-hello') return;
      var healthRequests = 0;
      while (true) {
        final request = await control();
        if (request['kind'] != 'request' || request['method'] != 'health')
          return;
        if (scenario == 'guest-bridge-session-health-hang') continue;
        healthRequests++;
        await _guestReply(socket, {
          ...request..remove('params'),
          'kind': 'response',
          'result': {
            'status':
                scenario == 'guest-bridge-session-health-flap' &&
                    healthRequests == 2
                ? 'degraded'
                : 'ok',
            'uptime_seconds': 1,
          },
        });
      }
    }
    socket.add(frame + utf8.encode('HELLO'));
    if (pending.isNotEmpty) socket.add(pending);
    await socket.flush();
    while (await input.moveNext()) {
      socket.add(input.current);
      await socket.flush();
    }
  } catch (_) {
    // Deliberately closed/failed test connections do not fail the fixture process.
  } finally {
    socket.destroy();
    await input.cancel();
  }
}

Future<void> _guestReply(Socket socket, Map<String, Object?> value) async {
  final payload = utf8.encode(jsonEncode(value));
  final frame = Uint8List(4 + payload.length);
  ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
  frame.setRange(4, frame.length, payload);
  socket.add(frame);
  await socket.flush();
}

const _guestCoreCapabilities = [
  'health',
  'system.info',
  'exec.start',
  'exec.status',
  'exec.cancel',
  'artifact.collect',
];

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
