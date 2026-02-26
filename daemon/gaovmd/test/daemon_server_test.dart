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
      {Object? params}) async {
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

  @override
  void attachEventEmitter(EventEmitter emitEvent) {}

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
