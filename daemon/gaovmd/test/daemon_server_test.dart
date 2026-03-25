import 'dart:async';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  group('DaemonRpcServer', () {
    test('maps config validation failures to invalidParams', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('vm.config.patch', params: {
        'patch': {'cpu': 0},
      });
      final error = Map<String, Object?>.from(response['error']! as Map);

      expect(error['code'], JsonRpcErrorCode.invalidParams);
      expect(error['message'], contains('cpu must be an integer >= 1'));
    });

    test('serializes concurrent vm.start requests', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final clientA = await harness.connectClient();
      final clientB = await harness.connectClient();
      addTearDown(clientA.close);
      addTearDown(clientB.close);

      final results = await Future.wait([
        clientA.sendRequest('vm.start'),
        clientB.sendRequest('vm.start'),
      ]);

      for (final response in results) {
        expect(response['error'], isNull);
        final result = Map<String, Object?>.from(response['result']! as Map);
        expect(result['actual'], 'running');
      }

      expect(harness.supervisor.maxConcurrentLifecycleCalls, 1);
      expect(harness.supervisor.startCallCount, 2);
    });

    test('driver.exec is disabled by default', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('driver.exec', params: {
        'method': 'vm.status',
      });
      final error = Map<String, Object?>.from(response['error']! as Map);

      expect(error['code'], JsonRpcErrorCode.methodNotFound);
      expect(error['message'], contains('disabled'));
    });

    test('ping returns ok and timestamp', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('ping');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['ok'], true);
      expect(result['ts'], isA<String>());
    });

    test('subscribe_events returns ok', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('subscribe_events');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['ok'], true);
    });

    test('list_vms returns default VM entry', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('list_vms');
      expect(response['error'], isNull);
      final result = response['result'] as List;
      expect(result.length, 1);
      final vm = Map<String, Object?>.from(result.first as Map);
      expect(vm['id'], 'default');
      expect(vm['desired'], 'stopped');
      expect(vm['actual'], 'stopped');
    });

    test('vm.start transitions to running', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('vm.start');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['actual'], 'running');
      expect(result['desired'], 'running');
    });

    test('vm.stop transitions to stopped', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      await client.sendRequest('vm.start');
      final response = await client.sendRequest('vm.stop');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['actual'], 'stopped');
      expect(result['desired'], 'stopped');
    });

    test('vm.status returns status', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('vm.status');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['desired'], 'stopped');
      expect(result['actual'], 'stopped');
    });

    test('vm.status includes driverVm when running', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      await client.sendRequest('vm.start');
      final response = await client.sendRequest('vm.status');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['actual'], 'running');
      expect(result['driverVm'], isNotNull);
    });

    test('vm.open_display delegates to driver', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      await client.sendRequest('vm.start');
      final response = await client.sendRequest('vm.open_display');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['ok'], true);
    });

    test('vm.close_display delegates to driver', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      await client.sendRequest('vm.start');
      final response = await client.sendRequest('vm.close_display');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['ok'], true);
    });

    test('vm.config.get returns config snapshot', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('vm.config.get');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['current'], isNotNull);
      expect(result['hasPending'], false);
    });

    test('vm.config.set applies config', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final config = {
        'cpu': 4,
        'memory': 2147483648,
        'boot': {
          'loader': 'linux',
          'kernelPath': null,
          'initrdPath': null,
          'commandLine': null,
        },
        'disk': {'path': null, 'sizeMiB': 8192},
        'network': {'mode': 'shared'},
        'graphics': {'enabled': true, 'width': 1280, 'height': 800},
      };
      final response = await client.sendRequest('vm.config.set', params: {
        'config': config,
      });
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['applied'], true);
    });

    test('vm.config.patch applies partial update', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('vm.config.patch', params: {
        'patch': {'cpu': 8},
      });
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['applied'], true);
    });

    test('doctor returns health checks', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('doctor');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['ok'], true);
      expect(result['daemon'], isNotNull);
    });

    test('unknown method returns methodNotFound', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      final response = await client.sendRequest('nonexistent.method');
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.methodNotFound);
    });
  });

  group('Display lifecycle serialization', () {
    test('vm.open_display is serialized with vm.start', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      // Start VM first.
      await client.sendRequest('vm.start');

      // Fire vm.open_display and vm.start concurrently.
      final results = await Future.wait([
        client.sendRequest('vm.open_display'),
        client.sendRequest('vm.start'),
      ]);

      // Both should succeed without error.
      for (final response in results) {
        expect(response['error'], isNull);
      }

      // Lifecycle calls should be serialized (max 1 concurrent).
      expect(harness.supervisor.maxConcurrentLifecycleCalls, 1);
    });

    test('vm.close_display is serialized with vm.stop', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final client = await harness.connectClient();
      addTearDown(client.close);

      await client.sendRequest('vm.start');

      final results = await Future.wait([
        client.sendRequest('vm.close_display'),
        client.sendRequest('vm.stop'),
      ]);

      for (final response in results) {
        expect(response['error'], isNull);
      }

      expect(harness.supervisor.maxConcurrentLifecycleCalls, 1);
    });
  });

  group('Event subscription', () {
    test('subscribed client receives events on vm.start', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final subscriber = await harness.connectClient();
      addTearDown(subscriber.close);

      // Subscribe to events.
      await subscriber.sendRequest('subscribe_events');

      // Collect incoming notifications.
      final events = <Map<String, Object?>>[];
      subscriber.onRequest = (request) async {
        if (request['method'] == 'event') {
          events.add(Map<String, Object?>.from(request['params'] as Map));
        }
        return null;
      };

      // Trigger events via another client.
      final controller = await harness.connectClient();
      addTearDown(controller.close);
      await controller.sendRequest('vm.start');

      // Give time for events to propagate.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Should have received at least config.updated and driver.started-like events.
      expect(events, isNotEmpty);
      expect(events.any((e) => e['type'] != null), isTrue);
    });

    test('non-subscribed client does not receive events', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final observer = await harness.connectClient();
      addTearDown(observer.close);

      // Do NOT subscribe to events.
      final events = <Map<String, Object?>>[];
      observer.onRequest = (request) async {
        if (request['method'] == 'event') {
          events.add(Map<String, Object?>.from(request['params'] as Map));
        }
        return null;
      };

      final controller = await harness.connectClient();
      addTearDown(controller.close);
      await controller.sendRequest('vm.start');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events, isEmpty);
    });
  });

  group('Handshake protocol', () {
    test('rejects method before handshake', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final socket = await Socket.connect(
        InternetAddress(harness.socketPath, type: InternetAddressType.unix),
        0,
      );
      final channel = RpcChannel(socket);
      addTearDown(channel.close);

      // Send ping without hello first.
      final response = await channel.sendRequest('ping');
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.handshakeFailed);
      expect(error['message'], contains('hello handshake required'));
    });

    test('rejects protocol mismatch', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final socket = await Socket.connect(
        InternetAddress(harness.socketPath, type: InternetAddressType.unix),
        0,
      );
      final channel = RpcChannel(socket);
      addTearDown(channel.close);

      final response = await channel.sendRequest('hello', params: {
        'protocol': 'gaovm.v999',
        'capabilities': ['hello', 'ping'],
        'requiredCapabilities': ['hello', 'ping'],
      });
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.handshakeFailed);
      expect(error['message'], contains('Protocol mismatch'));
    });

    test('rejects capability mismatch', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final socket = await Socket.connect(
        InternetAddress(harness.socketPath, type: InternetAddressType.unix),
        0,
      );
      final channel = RpcChannel(socket);
      addTearDown(channel.close);

      // Offer no capabilities — required caps won't intersect.
      final response = await channel.sendRequest('hello', params: {
        'protocol': 'gaovm.v1.2',
        'capabilities': [],
        'requiredCapabilities': [],
      });
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.capabilityMismatch);
    });

    test('multiple clients can connect simultaneously', () async {
      final harness = await _TestHarness.start();
      addTearDown(harness.close);

      final clientA = await harness.connectClient();
      final clientB = await harness.connectClient();
      final clientC = await harness.connectClient();
      addTearDown(clientA.close);
      addTearDown(clientB.close);
      addTearDown(clientC.close);

      final results = await Future.wait([
        clientA.sendRequest('ping'),
        clientB.sendRequest('ping'),
        clientC.sendRequest('ping'),
      ]);

      for (final response in results) {
        expect(response['error'], isNull);
      }
    });
  });
}

class _TestHarness {
  _TestHarness._({
    required this.tempDir,
    required this.server,
    required this.supervisor,
    required this.socketPath,
  });

  final Directory tempDir;
  final DaemonRpcServer server;
  final _FakeDriverSupervisor supervisor;
  final String socketPath;

  static Future<_TestHarness> start() async {
    final tempDir = await Directory.systemTemp.createTemp('gaovmd-test-');
    final socketPath = '${tempDir.path}/daemon.sock';
    final supervisor = _FakeDriverSupervisor(stateDir: tempDir.path);
    final configStore = VmConfigStore(stateDir: tempDir.path);
    final server = DaemonRpcServer(
      socketPath: socketPath,
      supervisor: supervisor,
      configStore: configStore,
    );
    await server.start();
    return _TestHarness._(
      tempDir: tempDir,
      server: server,
      supervisor: supervisor,
      socketPath: socketPath,
    );
  }

  Future<RpcChannel> connectClient() async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final channel = RpcChannel(socket);
    final hello = await channel.sendRequest('hello', params: {
      'protocol': _ClientHello.protocol,
      'capabilities': _ClientHello.capabilities,
      'requiredCapabilities': _ClientHello.requiredCapabilities,
    });
    expect(hello['error'], isNull);
    return channel;
  }

  Future<void> close() async {
    await server.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

class _ClientHello {
  static const protocol = 'gaovm.v1.2';
  static const capabilities = ['hello', 'ping'];
  static const requiredCapabilities = ['hello', 'ping'];
}

class _FakeDriverSupervisor extends DriverSupervisor {
  _FakeDriverSupervisor({required super.stateDir})
      : super(driverBinary: '/usr/bin/false');

  bool _desiredRunning = false;
  bool _actualRunning = false;
  int _inFlightLifecycleCalls = 0;
  int maxConcurrentLifecycleCalls = 0;
  int startCallCount = 0;

  @override
  Map<String, Object?> status() => {
        'desired': _desiredRunning ? 'running' : 'stopped',
        'actual': _actualRunning ? 'running' : 'stopped',
        'restartAttempts': 0,
        'maxRestartAttempts': 5,
        'driverPid': null,
        'driverSocketPath': null,
        'lastFailure': null,
      };

  @override
  Future<void> start() async {
    startCallCount += 1;
    _desiredRunning = true;
    await _trackLifecycle(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      _actualRunning = true;
      _emitter?.call('driver.started', {'pid': 12345});
    });
  }

  @override
  Future<void> stop() async {
    _desiredRunning = false;
    await _trackLifecycle(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      _actualRunning = false;
    });
  }

  @override
  Future<Map<String, Object?>> driverExec(String method,
      {Object? params, Duration timeout = const Duration(seconds: 5)}) async {
    return _trackLifecycle(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (method == 'vm.stop') {
        _actualRunning = false;
      } else if (method == 'vm.start') {
        _actualRunning = true;
      }
      return {
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'ok': true, 'method': method},
      };
    });
  }

  @override
  Future<Map<String, Object?>> doctor() async => {
        'ok': true,
        'daemon': status(),
        'checks': const <String, Object?>{},
      };

  EventEmitter? _emitter;

  @override
  void attachEventEmitter(EventEmitter emitEvent) {
    _emitter = emitEvent;
  }

  Future<T> _trackLifecycle<T>(Future<T> Function() op) async {
    _inFlightLifecycleCalls += 1;
    if (_inFlightLifecycleCalls > maxConcurrentLifecycleCalls) {
      maxConcurrentLifecycleCalls = _inFlightLifecycleCalls;
    }
    try {
      return await op();
    } finally {
      _inFlightLifecycleCalls -= 1;
    }
  }
}
