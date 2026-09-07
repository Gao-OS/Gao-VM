import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

final _runtimeDeviceIdPattern = RegExp(r'^[a-z][a-z0-9-]{0,31}$');
final _runtimeMacPattern = RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');

final class DriverCorrelation {
  static const maximumDriverGeneration = 9007199254740991;

  DriverCorrelation({
    required this.vmId,
    required this.driverGeneration,
    required this.operationId,
  }) {
    if (driverGeneration < 1 || driverGeneration > maximumDriverGeneration) {
      throw ArgumentError.value(
        driverGeneration,
        'driverGeneration',
        'must be between 1 and $maximumDriverGeneration',
      );
    }
  }

  final VmId vmId;
  final int driverGeneration;
  final OperationId? operationId;

  DriverCorrelation withOperation(OperationId? operationId) =>
      DriverCorrelation(
        vmId: vmId,
        driverGeneration: driverGeneration,
        operationId: operationId,
      );
}

enum DriverCapability {
  runtimeConfigure,
  runtimeStart,
  runtimeStop,
  runtimeKill,
  runtimeStatus,
  displayOpen,
  displayClose,
  displayStatus,
  consoleStatus,
  guestStatus,
}

final class DriverCapabilities {
  DriverCapabilities(Iterable<DriverCapability> values)
    : values = Set<DriverCapability>.unmodifiable(values);

  static final runtimeCore = DriverCapabilities({
    DriverCapability.runtimeConfigure,
    DriverCapability.runtimeStart,
    DriverCapability.runtimeStop,
    DriverCapability.runtimeKill,
    DriverCapability.runtimeStatus,
  });

  static final all = DriverCapabilities(DriverCapability.values);

  final Set<DriverCapability> values;

  bool contains(DriverCapability capability) => values.contains(capability);

  DriverCapabilities negotiate(DriverCapabilities peer) =>
      DriverCapabilities(values.where(peer.values.contains));

  bool containsAll(DriverCapabilities required) =>
      values.containsAll(required.values);
}

final class DriverCapabilityMismatch implements Exception {
  DriverCapabilityMismatch({required this.required, required this.offered});

  final DriverCapabilities required;
  final DriverCapabilities offered;

  @override
  String toString() => 'required driver capabilities were not offered';
}

sealed class RuntimeBootConfiguration {
  const RuntimeBootConfiguration();
}

final class RuntimeLinuxBootConfiguration extends RuntimeBootConfiguration {
  RuntimeLinuxBootConfiguration({
    required this.kernelPath,
    this.initrdPath,
    required this.commandLine,
  }) {
    if (kernelPath.isEmpty) {
      throw ArgumentError('Linux kernel path must not be empty');
    }
    if (commandLine.runes.length > 8192) {
      throw ArgumentError.value(
        commandLine,
        'commandLine',
        'must contain at most 8192 Unicode code points',
      );
    }
  }

  final String kernelPath;
  final String? initrdPath;
  final String commandLine;
}

final class RuntimeEfiBootConfiguration extends RuntimeBootConfiguration {
  RuntimeEfiBootConfiguration({required this.variableStorePath}) {
    if (variableStorePath.isEmpty) {
      throw ArgumentError('EFI variable store path must not be empty');
    }
  }

  final String variableStorePath;
}

final class RuntimeDiskConfiguration {
  RuntimeDiskConfiguration({
    required this.id,
    required this.path,
    required this.writable,
  }) {
    if (!_runtimeDeviceIdPattern.hasMatch(id) || path.isEmpty) {
      throw ArgumentError('runtime disks require valid IDs and paths');
    }
  }

  final String id;
  final String path;
  final bool writable;
}

enum RuntimeNetworkMode { shared, none }

final class RuntimeNetworkConfiguration {
  RuntimeNetworkConfiguration({
    required this.id,
    required this.mode,
    this.macAddress,
  }) {
    if (!_runtimeDeviceIdPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'is invalid');
    }
    if (mode == RuntimeNetworkMode.shared) {
      if (macAddress == null || !_runtimeMacPattern.hasMatch(macAddress!)) {
        throw ArgumentError('shared runtime networks require a valid MAC');
      }
    } else if (macAddress != null &&
        !_runtimeMacPattern.hasMatch(macAddress!)) {
      throw ArgumentError('runtime network MAC address is invalid');
    }
  }

  final String id;
  final RuntimeNetworkMode mode;
  final String? macAddress;
}

final class RuntimeGraphicsConfiguration {
  RuntimeGraphicsConfiguration({
    required this.enabled,
    this.width,
    this.height,
    this.pixelsPerInch,
  }) {
    if (enabled && (width == null || height == null || pixelsPerInch == null)) {
      throw ArgumentError('enabled graphics require complete dimensions');
    }
    _validateOptionalRange(width, 320, 8192, 'width');
    _validateOptionalRange(height, 200, 8192, 'height');
    _validateOptionalRange(pixelsPerInch, 72, 600, 'pixelsPerInch');
  }

  final bool enabled;
  final int? width;
  final int? height;
  final int? pixelsPerInch;
}

final class RuntimeSerialConfiguration {
  RuntimeSerialConfiguration({
    required this.enabled,
    required this.capture,
    required this.logPath,
  }) {
    if (logPath.isEmpty) {
      throw ArgumentError('serial log path must not be empty');
    }
  }

  final bool enabled;
  final bool capture;
  final String logPath;
}

final class RuntimeGuestAgentConfiguration {
  RuntimeGuestAgentConfiguration({
    required this.enabled,
    required this.vsockPort,
  }) {
    if (vsockPort < 1024 || vsockPort > 4294967295) {
      throw ArgumentError.value(
        vsockPort,
        'vsockPort',
        'must be between 1024 and 4294967295',
      );
    }
  }

  final bool enabled;
  final int vsockPort;
}

final class RuntimeDriverConfiguration {
  RuntimeDriverConfiguration({
    required this.architecture,
    required this.cpu,
    required this.memoryBytes,
    required this.boot,
    required Iterable<RuntimeDiskConfiguration> disks,
    required Iterable<RuntimeNetworkConfiguration> networks,
    required this.graphics,
    required this.serial,
    required this.guestAgent,
    required this.bundlePath,
    required this.driverLogPath,
  }) : disks = List<RuntimeDiskConfiguration>.unmodifiable(disks),
       networks = List<RuntimeNetworkConfiguration>.unmodifiable(networks) {
    if (cpu < 1 || cpu > 64) {
      throw ArgumentError.value(cpu, 'cpu', 'must be between 1 and 64');
    }
    if (memoryBytes < 268435456 ||
        memoryBytes > 9007199254740992 ||
        memoryBytes % 1048576 != 0) {
      throw ArgumentError.value(
        memoryBytes,
        'memoryBytes',
        'must be at least 256 MiB and MiB aligned',
      );
    }
    if (this.disks.isEmpty || this.disks.length > 32) {
      throw ArgumentError.value(disks, 'disks', 'must contain 1 to 32 disks');
    }
    if (this.networks.isEmpty || this.networks.length > 8) {
      throw ArgumentError.value(
        networks,
        'networks',
        'must contain 1 to 8 networks',
      );
    }
    if (bundlePath.isEmpty || driverLogPath.isEmpty) {
      throw ArgumentError('runtime paths must not be empty');
    }
    switch (boot) {
      case RuntimeLinuxBootConfiguration(:final kernelPath, :final commandLine):
        if (kernelPath.isEmpty) {
          throw ArgumentError('Linux kernel path must not be empty');
        }
        if (commandLine.runes.length > 8192) {
          throw ArgumentError.value(
            commandLine,
            'boot.commandLine',
            'must contain at most 8192 Unicode code points',
          );
        }
      case RuntimeEfiBootConfiguration(:final variableStorePath):
        if (variableStorePath.isEmpty) {
          throw ArgumentError('EFI variable store path must not be empty');
        }
    }
    for (final disk in this.disks) {
      if (!_runtimeDeviceIdPattern.hasMatch(disk.id) || disk.path.isEmpty) {
        throw ArgumentError('runtime disks require valid IDs and paths');
      }
    }
    if (serial.logPath.isEmpty) {
      throw ArgumentError('serial log path must not be empty');
    }
    if (guestAgent.vsockPort < 1024 || guestAgent.vsockPort > 4294967295) {
      throw ArgumentError.value(
        guestAgent.vsockPort,
        'guestAgent.vsockPort',
        'must be between 1024 and 4294967295',
      );
    }
    if (graphics.enabled &&
        (graphics.width == null ||
            graphics.height == null ||
            graphics.pixelsPerInch == null)) {
      throw ArgumentError('enabled graphics require complete dimensions');
    }
    for (final network in this.networks) {
      if (!_runtimeDeviceIdPattern.hasMatch(network.id)) {
        throw ArgumentError.value(network.id, 'network.id', 'is invalid');
      }
      if (network.mode == RuntimeNetworkMode.shared) {
        final macAddress = network.macAddress;
        if (macAddress == null || !_runtimeMacPattern.hasMatch(macAddress)) {
          throw ArgumentError(
            'shared runtime networks require a valid MAC address',
          );
        }
      } else if (network.macAddress != null &&
          !_runtimeMacPattern.hasMatch(network.macAddress!)) {
        throw ArgumentError('runtime network MAC address is invalid');
      }
    }
    _validateOptionalRange(graphics.width, 320, 8192, 'graphics.width');
    _validateOptionalRange(graphics.height, 200, 8192, 'graphics.height');
    _validateOptionalRange(
      graphics.pixelsPerInch,
      72,
      600,
      'graphics.pixelsPerInch',
    );
  }

  final Architecture architecture;
  final int cpu;
  final int memoryBytes;
  final RuntimeBootConfiguration boot;
  final List<RuntimeDiskConfiguration> disks;
  final List<RuntimeNetworkConfiguration> networks;
  final RuntimeGraphicsConfiguration graphics;
  final RuntimeSerialConfiguration serial;
  final RuntimeGuestAgentConfiguration guestAgent;
  final String bundlePath;
  final String driverLogPath;
}

final class RuntimeDriverLaunch {
  const RuntimeDriverLaunch({required this.correlation});

  final DriverCorrelation correlation;
}

sealed class RuntimeCommand {
  const RuntimeCommand({required this.correlation});

  final DriverCorrelation correlation;
  DriverCapability? get capability;
}

final class RuntimePingCommand extends RuntimeCommand {
  const RuntimePingCommand({required super.correlation});

  @override
  DriverCapability? get capability => null;
}

final class RuntimeConfigureCommand extends RuntimeCommand {
  RuntimeConfigureCommand({
    required super.correlation,
    required this.configuration,
  }) {
    _requireOperation(correlation, 'runtime configure');
  }

  final RuntimeDriverConfiguration configuration;

  @override
  DriverCapability get capability => DriverCapability.runtimeConfigure;
}

final class RuntimeStartCommand extends RuntimeCommand {
  RuntimeStartCommand({required super.correlation}) {
    _requireOperation(correlation, 'runtime start');
  }

  @override
  DriverCapability get capability => DriverCapability.runtimeStart;
}

final class RuntimeStopCommand extends RuntimeCommand {
  RuntimeStopCommand({
    required super.correlation,
    this.gracePeriod = const Duration(seconds: 30),
    this.forceAfterTimeout = true,
  }) {
    _requireOperation(correlation, 'runtime stop');
    if (gracePeriod.isNegative || gracePeriod > const Duration(minutes: 5)) {
      throw ArgumentError.value(
        gracePeriod,
        'gracePeriod',
        'must be between zero and five minutes',
      );
    }
  }

  final Duration gracePeriod;
  final bool forceAfterTimeout;

  @override
  DriverCapability get capability => DriverCapability.runtimeStop;
}

final class RuntimeKillCommand extends RuntimeCommand {
  RuntimeKillCommand({required super.correlation}) {
    _requireOperation(correlation, 'runtime kill');
  }

  @override
  DriverCapability get capability => DriverCapability.runtimeKill;
}

final class RuntimeStatusCommand extends RuntimeCommand {
  const RuntimeStatusCommand({required super.correlation});

  @override
  DriverCapability get capability => DriverCapability.runtimeStatus;
}

final class DisplayOpenCommand extends RuntimeCommand {
  DisplayOpenCommand({required super.correlation, this.activate = true}) {
    _requireOperation(correlation, 'display open');
  }

  final bool activate;

  @override
  DriverCapability get capability => DriverCapability.displayOpen;
}

final class DisplayCloseCommand extends RuntimeCommand {
  DisplayCloseCommand({required super.correlation}) {
    _requireOperation(correlation, 'display close');
  }

  @override
  DriverCapability get capability => DriverCapability.displayClose;
}

final class DisplayStatusCommand extends RuntimeCommand {
  const DisplayStatusCommand({required super.correlation});

  @override
  DriverCapability get capability => DriverCapability.displayStatus;
}

final class ConsoleStatusCommand extends RuntimeCommand {
  const ConsoleStatusCommand({required super.correlation});

  @override
  DriverCapability get capability => DriverCapability.consoleStatus;
}

final class GuestStatusCommand extends RuntimeCommand {
  const GuestStatusCommand({required super.correlation});

  @override
  DriverCapability get capability => DriverCapability.guestStatus;
}

enum RuntimeCommandStatus { accepted, succeeded, noop }

final class RuntimeCommandResult {
  const RuntimeCommandResult({required this.status, this.data});

  final RuntimeCommandStatus status;
  final JsonObjectValue? data;
}

enum RuntimeDriverErrorCode {
  invalidRuntimeConfig,
  invalidRuntimeState,
  runtimeStartFailed,
  runtimeStopFailed,
  runtimeKillFailed,
  driverUnhealthy,
  driverInternalError,
  capabilityMismatch,
  generationMismatch,
  protocolViolation,
  authenticationFailed,
  displayUnavailable,
  cancelled,
}

final class RuntimeDriverError implements Exception {
  RuntimeDriverError({
    required this.code,
    required this.message,
    required this.retryable,
    this.details,
  }) {
    if (message.isEmpty) throw ArgumentError('driver error message is empty');
  }

  final RuntimeDriverErrorCode code;
  final String message;
  final bool retryable;
  final JsonObjectValue? details;

  @override
  String toString() => message;
}

enum RuntimeDriverState {
  configured,
  starting,
  running,
  stopping,
  stopped,
  error,
}

enum RuntimeDisplayState { closed, opening, open, closing, error }

sealed class RuntimeEvent {
  const RuntimeEvent({required this.correlation, required this.occurredAt});

  final DriverCorrelation correlation;
  final DateTime occurredAt;
}

final class RuntimeStateChanged extends RuntimeEvent {
  const RuntimeStateChanged({
    required super.correlation,
    required super.occurredAt,
    required this.state,
  });

  final RuntimeDriverState state;
}

final class RuntimeCleanShutdown extends RuntimeEvent {
  const RuntimeCleanShutdown({
    required super.correlation,
    required super.occurredAt,
  });
}

final class RuntimeErrorEvent extends RuntimeEvent {
  const RuntimeErrorEvent({
    required super.correlation,
    required super.occurredAt,
    required this.error,
  });

  final RuntimeDriverError error;
}

final class DisplayStateChanged extends RuntimeEvent {
  const DisplayStateChanged({
    required super.correlation,
    required super.occurredAt,
    required this.state,
  });

  final RuntimeDisplayState state;
}

final class RuntimeConsoleReady extends RuntimeEvent {
  RuntimeConsoleReady({
    required super.correlation,
    required super.occurredAt,
    required this.logPath,
  }) {
    if (logPath.isEmpty) throw ArgumentError('console log path is empty');
  }

  final String logPath;
}

final class RuntimeGuestChannelReady extends RuntimeEvent {
  RuntimeGuestChannelReady({
    required super.correlation,
    required super.occurredAt,
    required this.ready,
    this.vsockPort,
  }) {
    if (vsockPort != null && (vsockPort! < 1 || vsockPort! > 4294967295)) {
      throw ArgumentError.value(vsockPort, 'vsockPort', 'is out of range');
    }
  }

  final bool ready;
  final int? vsockPort;
}

final class RuntimeDriverWarning extends RuntimeEvent {
  RuntimeDriverWarning({
    required super.correlation,
    required super.occurredAt,
    required this.code,
    required this.message,
    this.details,
  }) {
    if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(code) || message.isEmpty) {
      throw ArgumentError('driver warning code or message is invalid');
    }
  }

  final String code;
  final String message;
  final JsonObjectValue? details;
}

final class RuntimeHeartbeatMissed extends RuntimeEvent {
  const RuntimeHeartbeatMissed({
    required super.correlation,
    required super.occurredAt,
  });
}

enum RuntimeDriverLogStream { stdout, stderr, serial }

final class RuntimeDriverLogChunk {
  RuntimeDriverLogChunk({
    required this.correlation,
    required this.stream,
    required Uint8List bytes,
  }) : _bytes = Uint8List.fromList(bytes);

  final DriverCorrelation correlation;
  final RuntimeDriverLogStream stream;
  final Uint8List _bytes;

  Uint8List get bytes => Uint8List.fromList(_bytes);
}

final class RuntimeDriverExit {
  const RuntimeDriverExit({
    required this.correlation,
    required this.occurredAt,
    required this.clean,
    this.exitCode,
    this.error,
  });

  final DriverCorrelation correlation;
  final DateTime occurredAt;
  final bool clean;
  final int? exitCode;
  final RuntimeDriverError? error;
}

abstract interface class RuntimeDriverFactory {
  Future<RuntimeDriverSession> spawn(RuntimeDriverLaunch launch);

  Future<void> cancelSpawn(DriverCorrelation correlation);

  Future<void> release(DriverCorrelation correlation);
}

abstract interface class RuntimeDriverSession {
  DriverCorrelation get correlation;
  DriverCapabilities get capabilities;
  Stream<RuntimeEvent> get events;
  Stream<RuntimeDriverLogChunk> get logs;
  Future<RuntimeDriverExit> get exited;

  Future<DriverCapabilities> connect(DriverCapabilities required);
  Future<RuntimeCommandResult> execute(RuntimeCommand command);
  Future<RuntimeCommandResult> ping();
  Future<void> cancel(OperationId operationId);
  Future<void> close();
}

void _requireOperation(DriverCorrelation correlation, String command) {
  if (correlation.operationId == null) {
    throw ArgumentError('$command requires operation correlation');
  }
}

void _validateOptionalRange(int? value, int minimum, int maximum, String name) {
  if (value != null && (value < minimum || value > maximum)) {
    throw ArgumentError.value(
      value,
      name,
      'must be between $minimum and $maximum',
    );
  }
}
