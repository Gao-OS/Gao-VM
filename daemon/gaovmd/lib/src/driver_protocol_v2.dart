import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';

enum DriverPeerRole { daemon, driver }

final class DriverHello {
  const DriverHello({
    required this.role,
    required this.correlation,
    required this.authToken,
    required this.offered,
    required this.required,
  });

  final DriverPeerRole role;
  final DriverCorrelation correlation;
  final String authToken;
  final DriverCapabilities offered;
  final DriverCapabilities required;
}

final class DriverProtocolV2 {
  static const version = 'gaovm.driver.v2';
  static final _offsetDateTime = RegExp(
    r'^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$',
  );

  static Map<String, Object?> encodeHelloRequest({
    required Object id,
    required DriverCorrelation correlation,
    required DriverPeerRole role,
    required String authToken,
    required DriverCapabilities offered,
    required DriverCapabilities required,
  }) {
    _validateRpcId(id);
    if (authToken.length < 32 || authToken.length > 1024) {
      throw ArgumentError.value(
        authToken,
        'authToken',
        'must be 32-1024 bytes',
      );
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session.hello',
      'params': {
        'protocol_version': version,
        'peer_role': role.name,
        'vm_id': correlation.vmId.value,
        'driver_generation': correlation.driverGeneration,
        'operation_id': null,
        'auth_token': authToken,
        'offered_capabilities': _encodeCapabilities(offered),
        'required_capabilities': _encodeCapabilities(required),
        'implementation': {'name': 'gaovmd', 'version': '0.1.0'},
      },
    };
  }

  static DriverHello decodeHelloRequest(
    Map<String, Object?> message, {
    required DriverCorrelation expectedSession,
  }) {
    _requireEnvelope(message, method: 'session.hello', request: true);
    final params = _object(message['params'], 'hello params');
    if (params['protocol_version'] != version) {
      throw _protocolError('driver protocol version mismatch');
    }
    final role = switch (params['peer_role']) {
      'daemon' => DriverPeerRole.daemon,
      'driver' => DriverPeerRole.driver,
      _ => throw _protocolError('invalid driver peer role'),
    };
    _requireKeys(
      params,
      required: const {
        'protocol_version',
        'peer_role',
        'vm_id',
        'driver_generation',
        'operation_id',
        'auth_token',
        'offered_capabilities',
        'required_capabilities',
      },
      allowed: const {
        'protocol_version',
        'peer_role',
        'vm_id',
        'driver_generation',
        'operation_id',
        'auth_token',
        'offered_capabilities',
        'required_capabilities',
        'implementation',
      },
      name: 'hello params',
    );
    final correlation = _decodeCorrelation(params, allowNullOperation: true);
    _requireSessionCorrelation(correlation, expectedSession);
    if (correlation.operationId != null) {
      throw _protocolError('hello operation_id must be null');
    }
    final token = params['auth_token'];
    if (token is! String || token.length < 32 || token.length > 1024) {
      throw _protocolError('hello auth token is invalid');
    }
    if (params['implementation'] case final implementation?) {
      final value = _object(implementation, 'hello implementation');
      _requireKeys(
        value,
        required: const {'name', 'version'},
        name: 'hello implementation',
      );
      for (final field in const ['name', 'version']) {
        final text = _requiredString(value[field], 'implementation.$field');
        if (text.length > 128) {
          throw _protocolError('implementation.$field is too long');
        }
      }
    }
    return DriverHello(
      role: role,
      correlation: correlation,
      authToken: token,
      offered: _decodeCapabilities(params['offered_capabilities']),
      required: _decodeCapabilities(params['required_capabilities']),
    );
  }

  static Map<String, Object?> encodeHelloResult({
    required Object? id,
    required DriverCorrelation correlation,
    required DriverCapabilities accepted,
  }) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': {
      'protocol_version': version,
      'vm_id': correlation.vmId.value,
      'driver_generation': correlation.driverGeneration,
      'operation_id': null,
      'accepted_capabilities': _encodeCapabilities(accepted),
    },
  };

  static DriverCapabilities decodeHelloResult(
    Map<String, Object?> message, {
    required DriverCorrelation expectedSession,
  }) {
    final result = _resultOrThrow(
      message,
      expected: expectedSession.withOperation(null),
    );
    _requireKeys(
      result,
      required: const {
        'protocol_version',
        'vm_id',
        'driver_generation',
        'operation_id',
        'accepted_capabilities',
      },
      name: 'hello result',
    );
    if (result['protocol_version'] != version) {
      throw _protocolError('hello response protocol version mismatch');
    }
    final correlation = _decodeCorrelation(result, allowNullOperation: true);
    _requireSessionCorrelation(correlation, expectedSession);
    if (correlation.operationId != null) {
      throw _protocolError('hello result operation_id must be null');
    }
    return _decodeCapabilities(result['accepted_capabilities']);
  }

  static Map<String, Object?> encodeCommandRequest({
    required Object id,
    required RuntimeCommand command,
  }) {
    _validateRpcId(id);
    final correlation = _correlationJson(command.correlation);
    final (method, params) = switch (command) {
      RuntimePingCommand() => ('session.ping', correlation),
      RuntimeConfigureCommand(:final configuration) => (
        'runtime.configure',
        {...correlation, 'configuration': _configurationJson(configuration)},
      ),
      RuntimeStartCommand() => ('runtime.start', correlation),
      RuntimeStopCommand(:final gracePeriod, :final forceAfterTimeout) => (
        'runtime.stop',
        {
          ...correlation,
          'grace_period_seconds': gracePeriod.inMicroseconds / 1000000,
          'force_after_timeout': forceAfterTimeout,
        },
      ),
      RuntimeKillCommand() => ('runtime.kill', correlation),
      RuntimeStatusCommand() => ('runtime.status', correlation),
      DisplayOpenCommand(:final activate) => (
        'display.open',
        {
          ...correlation,
          'display': {'activate': activate},
        },
      ),
      DisplayCloseCommand() => ('display.close', correlation),
      DisplayStatusCommand() => ('display.status', correlation),
      ConsoleStatusCommand() => ('console.status', correlation),
      GuestStatusCommand() => ('guest.status', correlation),
    };
    return {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
  }

  static RuntimeCommandResult decodeCommandResult(
    Map<String, Object?> message, {
    required DriverCorrelation expected,
  }) {
    final result = _resultOrThrow(message, expected: expected);
    _requireKeys(
      result,
      required: const {'vm_id', 'driver_generation', 'operation_id', 'status'},
      allowed: const {
        'vm_id',
        'driver_generation',
        'operation_id',
        'status',
        'data',
      },
      name: 'command result',
    );
    final correlation = _decodeCorrelation(result, allowNullOperation: true);
    _requireSessionCorrelation(correlation, expected);
    if (correlation.operationId != expected.operationId) {
      throw _generationError('driver response operation correlation mismatch');
    }
    final status = switch (result['status']) {
      'accepted' => RuntimeCommandStatus.accepted,
      'succeeded' => RuntimeCommandStatus.succeeded,
      'noop' => RuntimeCommandStatus.noop,
      _ => throw _protocolError('invalid driver command status'),
    };
    final data = result['data'];
    return RuntimeCommandResult(
      status: status,
      data: data == null
          ? null
          : JsonObjectValue.fromJson(_object(data, 'command result data')),
    );
  }

  static RuntimeEvent decodeEvent(
    Map<String, Object?> message, {
    required DriverCorrelation expectedSession,
  }) {
    _requireEnvelope(message, request: false);
    final method = message['method'];
    final params = _object(message['params'], 'event params');
    _requireKeys(
      params,
      required: const {
        'vm_id',
        'driver_generation',
        'operation_id',
        'occurred_at',
      },
      allowed: const {
        'vm_id',
        'driver_generation',
        'operation_id',
        'occurred_at',
        'runtime_state',
        'clean_shutdown',
        'error',
        'display_state',
        'console',
        'guest',
        'warning',
      },
      name: 'event params',
    );
    final correlation = _decodeCorrelation(params, allowNullOperation: true);
    _requireSessionCorrelation(correlation, expectedSession);
    final occurredAtValue = params['occurred_at'];
    if (occurredAtValue is! String) {
      throw _protocolError('event occurred_at is missing');
    }
    final occurredAt = _offsetDateTime.hasMatch(occurredAtValue)
        ? DateTime.tryParse(occurredAtValue)?.toUtc()
        : null;
    if (occurredAt == null)
      throw _protocolError('event occurred_at is invalid');
    return switch (method) {
      'runtime.state_changed' => RuntimeStateChanged(
        correlation: correlation,
        occurredAt: occurredAt,
        state: _runtimeState(params['runtime_state']),
      ),
      'runtime.clean_shutdown' => RuntimeCleanShutdown(
        correlation: correlation,
        occurredAt: occurredAt,
      ),
      'runtime.error' => RuntimeErrorEvent(
        correlation: correlation,
        occurredAt: occurredAt,
        error: _decodeEventError(params['error']),
      ),
      'display.state_changed' => DisplayStateChanged(
        correlation: correlation,
        occurredAt: occurredAt,
        state: _displayState(params['display_state']),
      ),
      'console.ready' => _consoleEvent(correlation, occurredAt, params),
      'guest.channel_ready' => _guestEvent(correlation, occurredAt, params),
      'driver.warning' => _warningEvent(correlation, occurredAt, params),
      _ => throw _protocolError('unsupported driver event: $method'),
    };
  }

  static Map<String, Object?> encodeError({
    required Object? id,
    required DriverCorrelation correlation,
    required int rpcCode,
    required String code,
    required String message,
    required bool retryable,
  }) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {
      'code': rpcCode,
      'message': message,
      'data': {
        'code': code,
        ..._correlationJson(correlation),
        'retryable': retryable,
        'details': <String, Object?>{},
      },
    },
  };

  static RuntimeDriverError decodeError(Object? value) {
    final error = _object(value, 'driver error');
    _requireKeys(
      error,
      required: const {'code', 'message', 'data'},
      name: 'driver error',
    );
    final rpcCode = error['code'];
    if (rpcCode is! int || rpcCode < -2147483648 || rpcCode > 2147483647) {
      throw _protocolError('driver error code must be a signed 32-bit integer');
    }
    final data = _object(error['data'], 'driver error data');
    _requireKeys(
      data,
      required: const {
        'code',
        'vm_id',
        'driver_generation',
        'operation_id',
        'retryable',
      },
      allowed: const {
        'code',
        'vm_id',
        'driver_generation',
        'operation_id',
        'retryable',
        'details',
      },
      name: 'driver error data',
    );
    final code = switch (data['code']) {
      'INVALID_RUNTIME_CONFIG' => RuntimeDriverErrorCode.invalidRuntimeConfig,
      'INVALID_RUNTIME_STATE' => RuntimeDriverErrorCode.invalidRuntimeState,
      'RUNTIME_START_FAILED' => RuntimeDriverErrorCode.runtimeStartFailed,
      'RUNTIME_STOP_FAILED' => RuntimeDriverErrorCode.runtimeStopFailed,
      'RUNTIME_KILL_FAILED' => RuntimeDriverErrorCode.runtimeKillFailed,
      'CAPABILITY_MISMATCH' ||
      'CAPABILITY_NOT_NEGOTIATED' => RuntimeDriverErrorCode.capabilityMismatch,
      'GENERATION_MISMATCH' => RuntimeDriverErrorCode.generationMismatch,
      'AUTHENTICATION_FAILED' => RuntimeDriverErrorCode.authenticationFailed,
      'DISPLAY_UNAVAILABLE' => RuntimeDriverErrorCode.displayUnavailable,
      'PROTOCOL_VERSION_MISMATCH' => RuntimeDriverErrorCode.protocolViolation,
      'DRIVER_INTERNAL_ERROR' => RuntimeDriverErrorCode.driverInternalError,
      _ => throw _protocolError('unknown driver error code'),
    };
    if (data['retryable'] is! bool) {
      throw _protocolError('driver error retryable must be a boolean');
    }
    return RuntimeDriverError(
      code: code,
      message: _requiredString(error['message'], 'driver error message'),
      retryable: data['retryable'] == true,
      details: data['details'] == null
          ? null
          : JsonObjectValue.fromJson(_object(data['details'], 'error details')),
    );
  }

  static Map<String, Object?> _resultOrThrow(
    Map<String, Object?> message, {
    required DriverCorrelation expected,
  }) {
    if (message['jsonrpc'] != '2.0' || !message.containsKey('id')) {
      throw _protocolError('invalid JSON-RPC response');
    }
    _validateDecodedRpcId(message['id']);
    final hasResult = message.containsKey('result');
    final hasError = message.containsKey('error');
    if (hasResult == hasError) {
      throw _protocolError('response must contain exactly one result or error');
    }
    _requireKeys(
      message,
      required: {'jsonrpc', 'id', hasResult ? 'result' : 'error'},
      name: 'JSON-RPC response',
    );
    if (hasError) {
      final error = _object(message['error'], 'driver error');
      final data = _object(error['data'], 'driver error data');
      final correlation = _decodeCorrelation(data, allowNullOperation: true);
      _requireSessionCorrelation(correlation, expected);
      if (correlation.operationId != expected.operationId) {
        throw _generationError('driver error operation correlation mismatch');
      }
      throw decodeError(error);
    }
    return _object(message['result'], 'driver result');
  }

  static Map<String, Object?> _correlationJson(DriverCorrelation value) => {
    'vm_id': value.vmId.value,
    'driver_generation': value.driverGeneration,
    'operation_id': value.operationId?.value,
  };

  static DriverCorrelation _decodeCorrelation(
    Map<String, Object?> value, {
    required bool allowNullOperation,
  }) {
    for (final key in const ['vm_id', 'driver_generation', 'operation_id']) {
      if (!value.containsKey(key)) {
        throw _protocolError('driver correlation is missing $key');
      }
    }
    final operation = value['operation_id'];
    if (!allowNullOperation && operation == null) {
      throw _protocolError('operation_id is required');
    }
    try {
      return DriverCorrelation(
        vmId: VmId(_requiredString(value['vm_id'], 'vm_id')),
        driverGeneration: value['driver_generation']! as int,
        operationId: operation == null
            ? null
            : OperationId(_requiredString(operation, 'operation_id')),
      );
    } catch (error) {
      throw _protocolError('invalid driver correlation: $error');
    }
  }

  static void _requireSessionCorrelation(
    DriverCorrelation actual,
    DriverCorrelation expected,
  ) {
    if (actual.vmId != expected.vmId ||
        actual.driverGeneration != expected.driverGeneration) {
      throw _generationError('driver session correlation mismatch');
    }
  }

  static Map<String, Object?> _configurationJson(
    RuntimeDriverConfiguration value,
  ) => {
    'architecture': value.architecture.name,
    'cpu': value.cpu,
    'memory_bytes': value.memoryBytes,
    'boot': switch (value.boot) {
      RuntimeLinuxBootConfiguration(
        :final kernelPath,
        :final initrdPath,
        :final commandLine,
      ) =>
        {
          'type': 'linux_kernel',
          'kernel_path': kernelPath,
          'initrd_path': initrdPath,
          'command_line': commandLine,
        },
      RuntimeEfiBootConfiguration(:final variableStorePath) => {
        'type': 'efi',
        'variable_store_path': variableStorePath,
      },
    },
    'disks': [
      for (final disk in value.disks)
        {'id': disk.id, 'path': disk.path, 'writable': disk.writable},
    ],
    'networks': [
      for (final network in value.networks)
        {
          'id': network.id,
          'mode': network.mode.name,
          if (network.macAddress != null) 'mac_address': network.macAddress,
        },
    ],
    'graphics': {
      'enabled': value.graphics.enabled,
      if (value.graphics.width != null) 'width': value.graphics.width,
      if (value.graphics.height != null) 'height': value.graphics.height,
      if (value.graphics.pixelsPerInch != null)
        'pixels_per_inch': value.graphics.pixelsPerInch,
    },
    'serial': {
      'enabled': value.serial.enabled,
      'capture': value.serial.capture,
      'log_path': value.serial.logPath,
    },
    'guest_agent': {
      'enabled': value.guestAgent.enabled,
      'vsock_port': value.guestAgent.vsockPort,
    },
    'bundle_path': value.bundlePath,
    'log_paths': {
      'driver': value.driverLogPath,
      'serial': value.serial.logPath,
    },
  };

  static List<String> _encodeCapabilities(DriverCapabilities value) =>
      value.values.map(_capabilityName).toList()..sort();

  static DriverCapabilities _decodeCapabilities(Object? value) {
    if (value is! List) throw _protocolError('capabilities must be an array');
    final capabilities = <DriverCapability>{};
    for (final item in value) {
      capabilities.add(_capability(item));
    }
    if (capabilities.length != value.length) {
      throw _protocolError('capabilities must be unique');
    }
    return DriverCapabilities(capabilities);
  }

  static String _capabilityName(DriverCapability value) => switch (value) {
    DriverCapability.runtimeConfigure => 'runtime.configure',
    DriverCapability.runtimeStart => 'runtime.start',
    DriverCapability.runtimeStop => 'runtime.stop',
    DriverCapability.runtimeKill => 'runtime.kill',
    DriverCapability.runtimeStatus => 'runtime.status',
    DriverCapability.displayOpen => 'display.open',
    DriverCapability.displayClose => 'display.close',
    DriverCapability.displayStatus => 'display.status',
    DriverCapability.consoleStatus => 'console.status',
    DriverCapability.guestStatus => 'guest.status',
  };

  static DriverCapability _capability(Object? value) => switch (value) {
    'runtime.configure' => DriverCapability.runtimeConfigure,
    'runtime.start' => DriverCapability.runtimeStart,
    'runtime.stop' => DriverCapability.runtimeStop,
    'runtime.kill' => DriverCapability.runtimeKill,
    'runtime.status' => DriverCapability.runtimeStatus,
    'display.open' => DriverCapability.displayOpen,
    'display.close' => DriverCapability.displayClose,
    'display.status' => DriverCapability.displayStatus,
    'console.status' => DriverCapability.consoleStatus,
    'guest.status' => DriverCapability.guestStatus,
    _ => throw _protocolError('unknown driver capability: $value'),
  };

  static RuntimeDriverState _runtimeState(Object? value) => switch (value) {
    'configured' => RuntimeDriverState.configured,
    'starting' => RuntimeDriverState.starting,
    'running' => RuntimeDriverState.running,
    'stopping' => RuntimeDriverState.stopping,
    'stopped' => RuntimeDriverState.stopped,
    'error' => RuntimeDriverState.error,
    _ => throw _protocolError('invalid runtime state: $value'),
  };

  static RuntimeDisplayState _displayState(Object? value) => switch (value) {
    'closed' => RuntimeDisplayState.closed,
    'opening' => RuntimeDisplayState.opening,
    'open' => RuntimeDisplayState.open,
    'closing' => RuntimeDisplayState.closing,
    'error' => RuntimeDisplayState.error,
    _ => throw _protocolError('invalid display state: $value'),
  };

  static RuntimeDriverError _decodeEventError(Object? value) {
    final error = _object(value, 'runtime event error');
    _requireKeys(
      error,
      required: const {'code', 'message', 'retryable'},
      allowed: const {'code', 'message', 'retryable', 'details'},
      name: 'runtime event error',
    );
    final code = switch (error['code']) {
      'INVALID_RUNTIME_CONFIG' => RuntimeDriverErrorCode.invalidRuntimeConfig,
      'INVALID_RUNTIME_STATE' => RuntimeDriverErrorCode.invalidRuntimeState,
      'RUNTIME_START_FAILED' => RuntimeDriverErrorCode.runtimeStartFailed,
      'RUNTIME_STOP_FAILED' => RuntimeDriverErrorCode.runtimeStopFailed,
      'RUNTIME_KILL_FAILED' => RuntimeDriverErrorCode.runtimeKillFailed,
      'DRIVER_UNHEALTHY' => RuntimeDriverErrorCode.driverUnhealthy,
      'DRIVER_INTERNAL_ERROR' => RuntimeDriverErrorCode.driverInternalError,
      _ => throw _protocolError('unknown runtime event error code'),
    };
    if (error['retryable'] is! bool) {
      throw _protocolError('runtime event retryable must be a boolean');
    }
    return RuntimeDriverError(
      code: code,
      message: _requiredString(error['message'], 'runtime error message'),
      retryable: error['retryable'] == true,
      details: error['details'] == null
          ? null
          : JsonObjectValue.fromJson(
              _object(error['details'], 'event details'),
            ),
    );
  }

  static RuntimeGuestChannelReady _guestEvent(
    DriverCorrelation correlation,
    DateTime occurredAt,
    Map<String, Object?> params,
  ) {
    final guest = _object(params['guest'], 'guest event');
    _requireKeys(
      guest,
      required: const {'ready'},
      allowed: const {'ready', 'vsock_port'},
      name: 'guest event',
    );
    if (guest['ready'] is! bool) {
      throw _protocolError('guest.ready must be a boolean');
    }
    final port = guest['vsock_port'];
    if (port != null && (port is! int || port < 1 || port > 4294967295)) {
      throw _protocolError('guest.vsock_port is invalid');
    }
    return RuntimeGuestChannelReady(
      correlation: correlation,
      occurredAt: occurredAt,
      ready: guest['ready'] == true,
      vsockPort: guest['vsock_port'] as int?,
    );
  }

  static RuntimeConsoleReady _consoleEvent(
    DriverCorrelation correlation,
    DateTime occurredAt,
    Map<String, Object?> params,
  ) {
    final console = _object(params['console'], 'console event');
    _requireKeys(
      console,
      required: const {'ready', 'log_path'},
      name: 'console event',
    );
    if (console['ready'] != true) {
      throw _protocolError('console.ready must be true');
    }
    return RuntimeConsoleReady(
      correlation: correlation,
      occurredAt: occurredAt,
      logPath: _requiredString(console['log_path'], 'console.log_path'),
    );
  }

  static RuntimeDriverWarning _warningEvent(
    DriverCorrelation correlation,
    DateTime occurredAt,
    Map<String, Object?> params,
  ) {
    final warning = _object(params['warning'], 'warning event');
    _requireKeys(
      warning,
      required: const {'code', 'message'},
      allowed: const {'code', 'message', 'details'},
      name: 'warning event',
    );
    return RuntimeDriverWarning(
      correlation: correlation,
      occurredAt: occurredAt,
      code: _requiredString(warning['code'], 'warning code'),
      message: _requiredString(warning['message'], 'warning message'),
      details: warning['details'] == null
          ? null
          : JsonObjectValue.fromJson(
              _object(warning['details'], 'warning details'),
            ),
    );
  }

  static void _requireEnvelope(
    Map<String, Object?> value, {
    String? method,
    required bool request,
  }) {
    if (value['jsonrpc'] != '2.0' || value['method'] is! String) {
      throw _protocolError('invalid JSON-RPC request');
    }
    if (method != null && value['method'] != method) {
      throw _protocolError('unexpected JSON-RPC method');
    }
    if (request && !value.containsKey('id')) {
      throw _protocolError('JSON-RPC request id is missing');
    }
    if (!request && value.containsKey('id')) {
      throw _protocolError('driver event must be a notification');
    }
    _requireKeys(
      value,
      required: request
          ? const {'jsonrpc', 'id', 'method', 'params'}
          : const {'jsonrpc', 'method', 'params'},
      name: 'JSON-RPC request',
    );
    if (request) _validateDecodedRpcId(value['id']);
  }

  static void _requireKeys(
    Map<String, Object?> value, {
    required Set<String> required,
    Set<String>? allowed,
    required String name,
  }) {
    final missing = required.difference(value.keys.toSet());
    if (missing.isNotEmpty) {
      throw _protocolError('$name is missing ${missing.toList()..sort()}');
    }
    final extras = value.keys.toSet().difference(allowed ?? required);
    if (extras.isNotEmpty) {
      throw _protocolError(
        '$name contains unsupported keys ${extras.toList()..sort()}',
      );
    }
  }

  static Map<String, Object?> _object(Object? value, String name) {
    if (value is! Map) throw _protocolError('$name must be an object');
    try {
      return Map<String, Object?>.from(value);
    } catch (_) {
      throw _protocolError('$name contains a non-string key');
    }
  }

  static String _requiredString(Object? value, String name) {
    if (value is! String || value.isEmpty) {
      throw _protocolError('$name must be a non-empty string');
    }
    return value;
  }

  static void _validateRpcId(Object value) {
    if (value is int && value >= 0 && value <= 9007199254740991) return;
    if (value is String && value.isNotEmpty && value.length <= 128) return;
    throw ArgumentError.value(value, 'id', 'is not a valid JSON-RPC id');
  }

  static void _validateDecodedRpcId(Object? value) {
    try {
      _validateRpcId(value as Object);
    } catch (_) {
      throw _protocolError('invalid JSON-RPC id');
    }
  }

  static RuntimeDriverError _protocolError(String message) =>
      RuntimeDriverError(
        code: RuntimeDriverErrorCode.protocolViolation,
        message: message,
        retryable: false,
      );

  static RuntimeDriverError _generationError(String message) =>
      RuntimeDriverError(
        code: RuntimeDriverErrorCode.generationMismatch,
        message: message,
        retryable: false,
      );
}
