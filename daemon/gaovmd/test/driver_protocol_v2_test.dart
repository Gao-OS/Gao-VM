import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/driver_protocol_v2.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test('encodes canonical hello and lifecycle command correlation', () {
    final correlation = DriverCorrelation(
      vmId: _vmId,
      driverGeneration: 7,
      operationId: _operationId,
    );

    final hello = DriverProtocolV2.encodeHelloRequest(
      id: 0,
      correlation: correlation,
      role: DriverPeerRole.daemon,
      authToken: 'x' * 32,
      offered: DriverCapabilities.all,
      required: DriverCapabilities.runtimeCore,
    );
    expect(hello['method'], 'session.hello');
    expect(hello['params'], containsPair('vm_id', _vmId.value));
    expect(hello['params'], containsPair('driver_generation', 7));
    expect(hello['params'], containsPair('operation_id', null));

    final command = DriverProtocolV2.encodeCommandRequest(
      id: 1,
      command: RuntimeStopCommand(
        correlation: correlation,
        gracePeriod: const Duration(milliseconds: 1500),
        forceAfterTimeout: false,
      ),
    );
    expect(command['method'], 'runtime.stop');
    expect(command['params'], containsPair('operation_id', _operationId.value));
    expect(command['params'], containsPair('grace_period_seconds', 1.5));
    expect(command['params'], containsPair('force_after_timeout', false));
  });

  test('decodes events and rejects foreign command results', () {
    final expected = DriverCorrelation(
      vmId: _vmId,
      driverGeneration: 2,
      operationId: _operationId,
    );
    final event = DriverProtocolV2.decodeEvent({
      'jsonrpc': '2.0',
      'method': 'runtime.state_changed',
      'params': {
        'vm_id': _vmId.value,
        'driver_generation': 2,
        'operation_id': _operationId.value,
        'occurred_at': '2026-09-05T03:00:00Z',
        'runtime_state': 'running',
      },
    }, expectedSession: expected);
    expect(event, isA<RuntimeStateChanged>());
    expect((event as RuntimeStateChanged).state, RuntimeDriverState.running);

    expect(
      () => DriverProtocolV2.decodeCommandResult({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'vm_id': _otherVmId.value,
          'driver_generation': 2,
          'operation_id': _operationId.value,
          'status': 'succeeded',
        },
      }, expected: expected),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.generationMismatch,
        ),
      ),
    );
  });

  test('rejects additional properties and foreign error correlations', () {
    final expected = DriverCorrelation(
      vmId: _vmId,
      driverGeneration: 2,
      operationId: _operationId,
    );
    expect(
      () => DriverProtocolV2.decodeEvent({
        'jsonrpc': '2.0',
        'method': 'runtime.state_changed',
        'params': {
          'vm_id': _vmId.value,
          'driver_generation': 2,
          'operation_id': _operationId.value,
          'occurred_at': '2026-09-05T03:00:00Z',
          'runtime_state': 'running',
          'unexpected': true,
        },
      }, expectedSession: expected),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.protocolViolation,
        ),
      ),
    );

    expect(
      () => DriverProtocolV2.decodeCommandResult({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {
          'code': -32603,
          'message': 'failed',
          'data': {
            'code': 'RUNTIME_START_FAILED',
            'vm_id': _otherVmId.value,
            'driver_generation': 2,
            'operation_id': _operationId.value,
            'retryable': true,
            'details': <String, Object?>{},
          },
        },
      }, expected: expected),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.generationMismatch,
        ),
      ),
    );
  });

  test('requires offset RFC3339 timestamps and signed 32-bit RPC errors', () {
    final expected = DriverCorrelation(
      vmId: _vmId,
      driverGeneration: 2,
      operationId: _operationId,
    );
    expect(
      () => DriverProtocolV2.decodeEvent({
        'jsonrpc': '2.0',
        'method': 'runtime.state_changed',
        'params': {
          'vm_id': _vmId.value,
          'driver_generation': 2,
          'operation_id': _operationId.value,
          'occurred_at': '2026-09-05T03:00:00',
          'runtime_state': 'running',
        },
      }, expectedSession: expected),
      throwsA(isA<RuntimeDriverError>()),
    );
    expect(
      () => DriverProtocolV2.decodeCommandResult({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {
          'code': 2147483648,
          'message': 'failed',
          'data': {
            'code': 'DRIVER_INTERNAL_ERROR',
            'vm_id': _vmId.value,
            'driver_generation': 2,
            'operation_id': _operationId.value,
            'retryable': false,
          },
        },
      }, expected: expected),
      throwsA(isA<RuntimeDriverError>()),
    );
  });
}

final _vmId = VmId('vm_01J00000000000000000000000');
final _otherVmId = VmId('vm_01J00000000000000000000001');
final _operationId = OperationId('op_01J00000000000000000000000');
