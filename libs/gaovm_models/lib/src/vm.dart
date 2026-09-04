import 'common.dart';
import 'operation.dart';
import 'resource_id.dart';

const vmApiVersion = 'gaovm.io/v1alpha1';
const vmKind = 'VirtualMachine';

final _deviceIdPattern = RegExp(r'^[a-z][a-z0-9-]{0,31}$');
final _macPattern = RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');

final class VmMetadata extends ValueObject {
  VmMetadata({
    required this.id,
    required this.name,
    Map<String, String> labels = const {},
    required this.revision,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : labels = immutableStringMap(labels),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    requireNonEmpty(name, 'name');
    if (name.length > 128) {
      throw ArgumentError.value(
        name,
        'name',
        'must contain at most 128 characters',
      );
    }
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision', 'must be at least 1');
    }
    validateLabels(this.labels);
  }

  factory VmMetadata.fromJson(Object? value) {
    final json = readJsonObject(value, 'metadata');
    expectJsonKeys(
      json,
      required: const {
        'id',
        'name',
        'labels',
        'revision',
        'created_at',
        'updated_at',
      },
      optional: const {},
      name: 'metadata',
    );
    return VmMetadata(
      id: VmId(requireJson<String>(json, 'id')),
      name: requireJson<String>(json, 'name'),
      labels: readStringMap(json['labels'], 'labels'),
      revision: requireJson<int>(json, 'revision'),
      createdAt: requireDateTime(json, 'created_at'),
      updatedAt: requireDateTime(json, 'updated_at'),
    );
  }

  final VmId id;
  final String name;
  final Map<String, String> labels;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id.value,
    'name': name,
    'labels': Map<String, String>.of(labels),
    'revision': revision,
    'created_at': formatDateTime(createdAt),
    'updated_at': formatDateTime(updatedAt),
  };

  @override
  List<Object?> get equalityFields => [
    id,
    name,
    labels,
    revision,
    createdAt,
    updatedAt,
  ];
}

enum VmBackend { vz }

enum RestartPolicy { never, onFailure, always }

RestartPolicy _parseRestartPolicy(Object? value) => switch (value) {
  'never' => RestartPolicy.never,
  'on_failure' => RestartPolicy.onFailure,
  'always' => RestartPolicy.always,
  _ => throw FormatException('unsupported restart_policy: $value'),
};

String _restartPolicyToJson(RestartPolicy value) => switch (value) {
  RestartPolicy.onFailure => 'on_failure',
  _ => value.name,
};

sealed class BootConfig extends ValueObject {
  const BootConfig();

  factory BootConfig.fromJson(Object? value) {
    final json = readJsonObject(value, 'boot');
    return switch (json['type']) {
      'linux_kernel' => LinuxKernelBoot.fromJson(json),
      'efi' => EfiBoot.fromJson(json),
      _ => throw FormatException('unsupported boot type: ${json['type']}'),
    };
  }

  Map<String, Object?> toJson();
}

final class LinuxKernelBoot extends BootConfig {
  LinuxKernelBoot({
    required this.kernelImageId,
    this.initrdImageId,
    this.commandLine = '',
  }) {
    if (commandLine.length > 8192) {
      throw ArgumentError.value(commandLine, 'commandLine', 'is too long');
    }
  }

  factory LinuxKernelBoot.fromJson(Object? value) {
    final json = readJsonObject(value, 'linux kernel boot');
    expectJsonKeys(
      json,
      required: const {'type', 'kernel_image_id'},
      optional: const {'initrd_image_id', 'command_line'},
      name: 'linux kernel boot',
    );
    if (json['type'] != 'linux_kernel') {
      throw FormatException('linux kernel boot type must be linux_kernel');
    }
    final initrdImageId = nullableJson<String>(json, 'initrd_image_id');
    return LinuxKernelBoot(
      kernelImageId: ImageId(requireJson<String>(json, 'kernel_image_id')),
      initrdImageId: initrdImageId == null ? null : ImageId(initrdImageId),
      commandLine: optionalJson<String>(json, 'command_line') ?? '',
    );
  }

  final ImageId kernelImageId;
  final ImageId? initrdImageId;
  final String commandLine;

  @override
  Map<String, Object?> toJson() => {
    'type': 'linux_kernel',
    'kernel_image_id': kernelImageId.value,
    'initrd_image_id': initrdImageId?.value,
    'command_line': commandLine,
  };

  @override
  List<Object?> get equalityFields => [
    kernelImageId,
    initrdImageId,
    commandLine,
  ];
}

enum EfiVariableStore { managed, external }

final class EfiBoot extends BootConfig {
  EfiBoot({
    this.variableStore = EfiVariableStore.managed,
    this.variableStorePath,
  }) {
    if (variableStorePath != null && variableStorePath!.isEmpty) {
      throw ArgumentError.value(
        variableStorePath,
        'variableStorePath',
        'must not be empty',
      );
    }
    if (variableStore == EfiVariableStore.external &&
        variableStorePath == null) {
      throw ArgumentError('external EFI variable store requires a path');
    }
  }

  factory EfiBoot.fromJson(Object? value) {
    final json = readJsonObject(value, 'EFI boot');
    expectJsonKeys(
      json,
      required: const {'type'},
      optional: const {'variable_store', 'variable_store_path'},
      name: 'EFI boot',
    );
    if (json['type'] != 'efi') {
      throw FormatException('EFI boot type must be efi');
    }
    final variableStore = optionalJson<String>(json, 'variable_store');
    final store = switch (variableStore) {
      null || 'managed' => EfiVariableStore.managed,
      'external' => EfiVariableStore.external,
      final value => throw FormatException(
        'unsupported variable_store: $value',
      ),
    };
    return EfiBoot(
      variableStore: store,
      variableStorePath: optionalJson<String>(json, 'variable_store_path'),
    );
  }

  final EfiVariableStore variableStore;
  final String? variableStorePath;

  @override
  Map<String, Object?> toJson() => {
    'type': 'efi',
    'variable_store': variableStore.name,
    if (variableStorePath != null) 'variable_store_path': variableStorePath,
  };

  @override
  List<Object?> get equalityFields => [variableStore, variableStorePath];
}

sealed class DiskSource extends ValueObject {
  const DiskSource();

  factory DiskSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'disk source');
    return switch (json['type']) {
      'managed_image' => ManagedImageDiskSource.fromJson(json),
      'external' => ExternalDiskSource.fromJson(json),
      _ => throw FormatException('unsupported disk source: ${json['type']}'),
    };
  }

  Map<String, Object?> toJson();
}

final class ManagedImageDiskSource extends DiskSource {
  const ManagedImageDiskSource(this.imageId);

  factory ManagedImageDiskSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'managed image disk source');
    expectJsonKeys(
      json,
      required: const {'type', 'image_id'},
      optional: const {},
      name: 'managed image disk source',
    );
    if (json['type'] != 'managed_image') {
      throw FormatException('managed image disk source has wrong type');
    }
    return ManagedImageDiskSource(
      ImageId(requireJson<String>(json, 'image_id')),
    );
  }

  final ImageId imageId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'managed_image',
    'image_id': imageId.value,
  };

  @override
  List<Object?> get equalityFields => [imageId];
}

final class ExternalDiskSource extends DiskSource {
  ExternalDiskSource(this.path) {
    requireNonEmpty(path, 'path');
  }

  factory ExternalDiskSource.fromJson(Object? value) {
    final json = readJsonObject(value, 'external disk source');
    expectJsonKeys(
      json,
      required: const {'type', 'path'},
      optional: const {},
      name: 'external disk source',
    );
    if (json['type'] != 'external') {
      throw FormatException('external disk source has wrong type');
    }
    return ExternalDiskSource(requireJson<String>(json, 'path'));
  }

  final String path;

  @override
  Map<String, Object?> toJson() => {'type': 'external', 'path': path};

  @override
  List<Object?> get equalityFields => [path];
}

final class VmDisk extends ValueObject {
  VmDisk({required this.id, required this.source, required this.writable}) {
    requirePattern(id, _deviceIdPattern, 'id');
  }

  factory VmDisk.fromJson(Object? value) {
    final json = readJsonObject(value, 'disk');
    expectJsonKeys(
      json,
      required: const {'id', 'source', 'writable'},
      optional: const {},
      name: 'disk',
    );
    return VmDisk(
      id: requireJson<String>(json, 'id'),
      source: DiskSource.fromJson(json['source']),
      writable: requireJson<bool>(json, 'writable'),
    );
  }

  final String id;
  final DiskSource source;
  final bool writable;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source.toJson(),
    'writable': writable,
  };

  @override
  List<Object?> get equalityFields => [id, source, writable];
}

sealed class VmNetwork extends ValueObject {
  const VmNetwork();

  factory VmNetwork.fromJson(Object? value) {
    final json = readJsonObject(value, 'network');
    return switch (json['mode']) {
      'shared' => SharedNetwork.fromJson(json),
      'none' => DisconnectedNetwork.fromJson(json),
      _ => throw FormatException('unsupported network mode: ${json['mode']}'),
    };
  }

  String get id;
  Map<String, Object?> toJson();
}

final class SharedNetwork extends VmNetwork {
  SharedNetwork({required this.id, this.macAddress}) {
    requirePattern(id, _deviceIdPattern, 'id');
    if (macAddress != null) {
      requirePattern(macAddress!, _macPattern, 'macAddress');
    }
  }

  factory SharedNetwork.fromJson(Object? value) {
    final json = readJsonObject(value, 'shared network');
    expectJsonKeys(
      json,
      required: const {'id', 'mode'},
      optional: const {'mac_address'},
      name: 'shared network',
    );
    if (json['mode'] != 'shared') {
      throw FormatException('network mode must be shared');
    }
    return SharedNetwork(
      id: requireJson<String>(json, 'id'),
      macAddress: optionalJson<String>(json, 'mac_address'),
    );
  }

  @override
  final String id;
  final String? macAddress;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'mode': 'shared',
    if (macAddress != null) 'mac_address': macAddress,
  };

  @override
  List<Object?> get equalityFields => [id, macAddress];
}

final class DisconnectedNetwork extends VmNetwork {
  DisconnectedNetwork({required this.id}) {
    requirePattern(id, _deviceIdPattern, 'id');
  }

  factory DisconnectedNetwork.fromJson(Object? value) {
    final json = readJsonObject(value, 'disconnected network');
    expectJsonKeys(
      json,
      required: const {'id', 'mode'},
      optional: const {},
      name: 'disconnected network',
    );
    if (json['mode'] != 'none') {
      throw FormatException('network mode must be none');
    }
    return DisconnectedNetwork(id: requireJson<String>(json, 'id'));
  }

  @override
  final String id;

  @override
  Map<String, Object?> toJson() => {'id': id, 'mode': 'none'};

  @override
  List<Object?> get equalityFields => [id];
}

final class GraphicsConfig extends ValueObject {
  GraphicsConfig({
    required this.enabled,
    this.width,
    this.height,
    this.pixelsPerInch = 144,
  }) {
    if (enabled && (width == null || height == null)) {
      throw ArgumentError('enabled graphics require width and height');
    }
    if (width != null) requireRange(width!, 320, 8192, 'width');
    if (height != null) requireRange(height!, 200, 8192, 'height');
    requireRange(pixelsPerInch, 72, 600, 'pixelsPerInch');
  }

  factory GraphicsConfig.fromJson(Object? value) {
    final json = readJsonObject(value, 'graphics');
    expectJsonKeys(
      json,
      required: const {'enabled'},
      optional: const {'width', 'height', 'pixels_per_inch'},
      name: 'graphics',
    );
    return GraphicsConfig(
      enabled: requireJson<bool>(json, 'enabled'),
      width: optionalJson<int>(json, 'width'),
      height: optionalJson<int>(json, 'height'),
      pixelsPerInch: optionalJson<int>(json, 'pixels_per_inch') ?? 144,
    );
  }

  final bool enabled;
  final int? width;
  final int? height;
  final int pixelsPerInch;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'pixels_per_inch': pixelsPerInch,
  };

  @override
  List<Object?> get equalityFields => [enabled, width, height, pixelsPerInch];
}

final class SerialConfig extends ValueObject {
  const SerialConfig({required this.enabled, required this.capture});

  factory SerialConfig.fromJson(Object? value) {
    final json = readJsonObject(value, 'serial');
    expectJsonKeys(
      json,
      required: const {'enabled', 'capture'},
      optional: const {},
      name: 'serial',
    );
    return SerialConfig(
      enabled: requireJson<bool>(json, 'enabled'),
      capture: requireJson<bool>(json, 'capture'),
    );
  }

  final bool enabled;
  final bool capture;

  Map<String, Object?> toJson() => {'enabled': enabled, 'capture': capture};

  @override
  List<Object?> get equalityFields => [enabled, capture];
}

final class GuestAgentConfig extends ValueObject {
  GuestAgentConfig({
    required this.enabled,
    required this.requiredForReady,
    this.vsockPort = 10777,
  }) {
    if (!enabled && requiredForReady) {
      throw ArgumentError(
        'disabled guest agent cannot be required for readiness',
      );
    }
    requireRange(vsockPort, 1024, 4294967295, 'vsockPort');
  }

  factory GuestAgentConfig.fromJson(Object? value) {
    final json = readJsonObject(value, 'guest_agent');
    expectJsonKeys(
      json,
      required: const {'enabled', 'required_for_ready'},
      optional: const {'vsock_port'},
      name: 'guest_agent',
    );
    return GuestAgentConfig(
      enabled: requireJson<bool>(json, 'enabled'),
      requiredForReady: requireJson<bool>(json, 'required_for_ready'),
      vsockPort: optionalJson<int>(json, 'vsock_port') ?? 10777,
    );
  }

  final bool enabled;
  final bool requiredForReady;
  final int vsockPort;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'required_for_ready': requiredForReady,
    'vsock_port': vsockPort,
  };

  @override
  List<Object?> get equalityFields => [enabled, requiredForReady, vsockPort];
}

sealed class PatchField<T> extends ValueObject {
  const PatchField();

  const factory PatchField.absent() = _AbsentPatchField<T>;
  const factory PatchField.present(T value) = _PresentPatchField<T>;

  bool get isPresent;
  T get value;
}

final class _AbsentPatchField<T> extends PatchField<T> {
  const _AbsentPatchField();

  @override
  bool get isPresent => false;

  @override
  T get value => throw StateError('patch field is absent');

  @override
  List<Object?> get equalityFields => const [];
}

final class _PresentPatchField<T> extends PatchField<T> {
  const _PresentPatchField(this._value);

  final T _value;

  @override
  bool get isPresent => true;

  @override
  T get value => _value;

  @override
  List<Object?> get equalityFields => [_value];
}

final class VmSpecPatch extends ValueObject {
  VmSpecPatch({
    this.backend,
    this.architecture,
    this.guestProfile = const PatchField<String?>.absent(),
    this.cpu,
    this.memoryBytes,
    this.boot,
    Iterable<VmDisk>? disks,
    Iterable<VmNetwork>? networks,
    this.graphics,
    this.serial,
    this.guestAgent,
    this.restartPolicy,
    this.autostart,
  }) : disks = disks == null ? null : List<VmDisk>.unmodifiable(disks),
       networks = networks == null
           ? null
           : List<VmNetwork>.unmodifiable(networks) {
    if (!_hasChanges) {
      throw ArgumentError('VmSpecPatch must contain at least one field');
    }
    if (guestProfile.isPresent && guestProfile.value != null) {
      requireNonEmpty(guestProfile.value!, 'guestProfile');
      if (guestProfile.value!.length > 64) {
        throw ArgumentError.value(
          guestProfile.value,
          'guestProfile',
          'is too long',
        );
      }
    }
    if (cpu != null) requireRange(cpu!, 1, 64, 'cpu');
    if (memoryBytes != null &&
        (memoryBytes! < 268435456 || memoryBytes! % 1048576 != 0)) {
      throw ArgumentError.value(
        memoryBytes,
        'memoryBytes',
        'must be at least 256 MiB and MiB aligned',
      );
    }
    if (this.disks != null &&
        (this.disks!.isEmpty || this.disks!.length > 32)) {
      throw ArgumentError.value(
        this.disks,
        'disks',
        'must contain 1 to 32 disks',
      );
    }
    if (this.networks != null &&
        (this.networks!.isEmpty || this.networks!.length > 8)) {
      throw ArgumentError.value(
        this.networks,
        'networks',
        'must contain 1 to 8 networks',
      );
    }
  }

  factory VmSpecPatch.fromJson(Object? value) {
    final json = readJsonObject(value, 'VmSpecPatch');
    expectJsonKeys(
      json,
      required: const {},
      optional: const {
        'backend',
        'architecture',
        'guest_profile',
        'cpu',
        'memory_bytes',
        'boot',
        'disks',
        'networks',
        'graphics',
        'serial',
        'guest_agent',
        'restart_policy',
        'autostart',
      },
      name: 'VmSpecPatch',
    );
    final backend = json.containsKey('backend')
        ? requireJson<String>(json, 'backend')
        : null;
    if (backend != null && backend != 'vz') {
      throw FormatException('unsupported backend: $backend');
    }
    final guestProfile = json.containsKey('guest_profile')
        ? PatchField<String?>.present(
            nullableJson<String>(json, 'guest_profile'),
          )
        : const PatchField<String?>.absent();
    return VmSpecPatch(
      backend: backend == null ? null : VmBackend.vz,
      architecture: json.containsKey('architecture')
          ? parseArchitecture(json['architecture'])
          : null,
      guestProfile: guestProfile,
      cpu: optionalJson<int>(json, 'cpu'),
      memoryBytes: optionalJson<int>(json, 'memory_bytes'),
      boot: json.containsKey('boot') ? BootConfig.fromJson(json['boot']) : null,
      disks: json.containsKey('disks')
          ? readJsonList(json['disks'], 'disks', VmDisk.fromJson)
          : null,
      networks: json.containsKey('networks')
          ? readJsonList(json['networks'], 'networks', VmNetwork.fromJson)
          : null,
      graphics: json.containsKey('graphics')
          ? GraphicsConfig.fromJson(json['graphics'])
          : null,
      serial: json.containsKey('serial')
          ? SerialConfig.fromJson(json['serial'])
          : null,
      guestAgent: json.containsKey('guest_agent')
          ? GuestAgentConfig.fromJson(json['guest_agent'])
          : null,
      restartPolicy: json.containsKey('restart_policy')
          ? _parseRestartPolicy(json['restart_policy'])
          : null,
      autostart: optionalJson<bool>(json, 'autostart'),
    );
  }

  final VmBackend? backend;
  final Architecture? architecture;
  final PatchField<String?> guestProfile;
  final int? cpu;
  final int? memoryBytes;
  final BootConfig? boot;
  final List<VmDisk>? disks;
  final List<VmNetwork>? networks;
  final GraphicsConfig? graphics;
  final SerialConfig? serial;
  final GuestAgentConfig? guestAgent;
  final RestartPolicy? restartPolicy;
  final bool? autostart;

  bool get _hasChanges =>
      backend != null ||
      architecture != null ||
      guestProfile.isPresent ||
      cpu != null ||
      memoryBytes != null ||
      boot != null ||
      disks != null ||
      networks != null ||
      graphics != null ||
      serial != null ||
      guestAgent != null ||
      restartPolicy != null ||
      autostart != null;

  Map<String, Object?> toJson() => {
    if (backend != null) 'backend': 'vz',
    if (architecture != null) 'architecture': architectureToJson(architecture!),
    if (guestProfile.isPresent) 'guest_profile': guestProfile.value,
    if (cpu != null) 'cpu': cpu,
    if (memoryBytes != null) 'memory_bytes': memoryBytes,
    if (boot != null) 'boot': boot!.toJson(),
    if (disks != null) 'disks': disks!.map((disk) => disk.toJson()).toList(),
    if (networks != null)
      'networks': networks!.map((network) => network.toJson()).toList(),
    if (graphics != null) 'graphics': graphics!.toJson(),
    if (serial != null) 'serial': serial!.toJson(),
    if (guestAgent != null) 'guest_agent': guestAgent!.toJson(),
    if (restartPolicy != null)
      'restart_policy': _restartPolicyToJson(restartPolicy!),
    if (autostart != null) 'autostart': autostart,
  };

  @override
  List<Object?> get equalityFields => [
    backend,
    architecture,
    guestProfile,
    cpu,
    memoryBytes,
    boot,
    disks,
    networks,
    graphics,
    serial,
    guestAgent,
    restartPolicy,
    autostart,
  ];
}

final class VmSpec extends ValueObject {
  VmSpec({
    this.backend = VmBackend.vz,
    this.architecture = Architecture.arm64,
    this.guestProfile,
    required this.cpu,
    required this.memoryBytes,
    required this.boot,
    required Iterable<VmDisk> disks,
    required Iterable<VmNetwork> networks,
    required this.graphics,
    required this.serial,
    required this.guestAgent,
    required this.restartPolicy,
    this.autostart = false,
  }) : disks = List<VmDisk>.unmodifiable(disks),
       networks = List<VmNetwork>.unmodifiable(networks) {
    if (guestProfile != null) {
      requireNonEmpty(guestProfile!, 'guestProfile');
      if (guestProfile!.length > 64) {
        throw ArgumentError.value(guestProfile, 'guestProfile', 'is too long');
      }
    }
    requireRange(cpu, 1, 64, 'cpu');
    if (memoryBytes < 268435456 || memoryBytes % 1048576 != 0) {
      throw ArgumentError.value(
        memoryBytes,
        'memoryBytes',
        'must be at least 256 MiB and MiB aligned',
      );
    }
    if (disks.isEmpty || disks.length > 32) {
      throw ArgumentError.value(disks, 'disks', 'must contain 1 to 32 disks');
    }
    if (networks.isEmpty || networks.length > 8) {
      throw ArgumentError.value(
        networks,
        'networks',
        'must contain 1 to 8 networks',
      );
    }
  }

  factory VmSpec.fromJson(Object? value) {
    final json = readJsonObject(value, 'spec');
    expectJsonKeys(
      json,
      required: const {
        'backend',
        'architecture',
        'cpu',
        'memory_bytes',
        'boot',
        'disks',
        'networks',
        'graphics',
        'serial',
        'guest_agent',
        'restart_policy',
      },
      optional: const {'guest_profile', 'autostart'},
      name: 'spec',
    );
    if (json['backend'] != 'vz') {
      throw FormatException('unsupported backend: ${json['backend']}');
    }
    return VmSpec(
      architecture: parseArchitecture(json['architecture']),
      guestProfile: nullableJson<String>(json, 'guest_profile'),
      cpu: requireJson<int>(json, 'cpu'),
      memoryBytes: requireJson<int>(json, 'memory_bytes'),
      boot: BootConfig.fromJson(json['boot']),
      disks: readJsonList(json['disks'], 'disks', VmDisk.fromJson),
      networks: readJsonList(json['networks'], 'networks', VmNetwork.fromJson),
      graphics: GraphicsConfig.fromJson(json['graphics']),
      serial: SerialConfig.fromJson(json['serial']),
      guestAgent: GuestAgentConfig.fromJson(json['guest_agent']),
      restartPolicy: _parseRestartPolicy(json['restart_policy']),
      autostart: optionalJson<bool>(json, 'autostart') ?? false,
    );
  }

  final VmBackend backend;
  final Architecture architecture;
  final String? guestProfile;
  final int cpu;
  final int memoryBytes;
  final BootConfig boot;
  final List<VmDisk> disks;
  final List<VmNetwork> networks;
  final GraphicsConfig graphics;
  final SerialConfig serial;
  final GuestAgentConfig guestAgent;
  final RestartPolicy restartPolicy;
  final bool autostart;

  Map<String, Object?> toJson() => {
    'backend': 'vz',
    'architecture': architectureToJson(architecture),
    'guest_profile': guestProfile,
    'cpu': cpu,
    'memory_bytes': memoryBytes,
    'boot': boot.toJson(),
    'disks': disks.map((disk) => disk.toJson()).toList(),
    'networks': networks.map((network) => network.toJson()).toList(),
    'graphics': graphics.toJson(),
    'serial': serial.toJson(),
    'guest_agent': guestAgent.toJson(),
    'restart_policy': _restartPolicyToJson(restartPolicy),
    if (autostart) 'autostart': true,
  };

  @override
  List<Object?> get equalityFields => [
    backend,
    architecture,
    guestProfile,
    cpu,
    memoryBytes,
    boot,
    disks,
    networks,
    graphics,
    serial,
    guestAgent,
    restartPolicy,
    autostart,
  ];
}

enum DesiredState { stopped, running }

enum GuestAgentState { disabled, unavailable, connecting, ready, unhealthy }

final class VmStatus extends ValueObject {
  VmStatus({
    required this.desiredState,
    required this.phase,
    required this.specGeneration,
    required this.observedGeneration,
    required this.driverGeneration,
    required this.guestAgent,
    this.restartRequired = false,
    required DateTime lastTransitionAt,
    this.lastError,
  }) : lastTransitionAt = lastTransitionAt.toUtc() {
    if (specGeneration < 1 || observedGeneration < 0 || driverGeneration < 0) {
      throw ArgumentError('generation values are outside their schema range');
    }
  }

  factory VmStatus.fromJson(Object? value) {
    final json = readJsonObject(value, 'status');
    expectJsonKeys(
      json,
      required: const {
        'desired_state',
        'phase',
        'spec_generation',
        'observed_generation',
        'driver_generation',
        'guest_agent',
        'last_transition_at',
        'last_error',
      },
      optional: const {'restart_required'},
      name: 'status',
    );
    return VmStatus(
      desiredState: switch (json['desired_state']) {
        'stopped' => DesiredState.stopped,
        'running' => DesiredState.running,
        final value => throw FormatException(
          'unsupported desired_state: $value',
        ),
      },
      phase: VmPhaseParsing.parse(json['phase']),
      specGeneration: requireJson<int>(json, 'spec_generation'),
      observedGeneration: requireJson<int>(json, 'observed_generation'),
      driverGeneration: requireJson<int>(json, 'driver_generation'),
      guestAgent: switch (json['guest_agent']) {
        'disabled' => GuestAgentState.disabled,
        'unavailable' => GuestAgentState.unavailable,
        'connecting' => GuestAgentState.connecting,
        'ready' => GuestAgentState.ready,
        'unhealthy' => GuestAgentState.unhealthy,
        final value => throw FormatException(
          'unsupported guest_agent state: $value',
        ),
      },
      restartRequired: optionalJson<bool>(json, 'restart_required') ?? false,
      lastTransitionAt: requireDateTime(json, 'last_transition_at'),
      lastError: json['last_error'] == null
          ? null
          : OperationError.fromJson(json['last_error']),
    );
  }

  final DesiredState desiredState;
  final VmPhase phase;
  final int specGeneration;
  final int observedGeneration;
  final int driverGeneration;
  final GuestAgentState guestAgent;
  final bool restartRequired;
  final DateTime lastTransitionAt;
  final OperationError? lastError;

  Map<String, Object?> toJson() => {
    'desired_state': desiredState.name,
    'phase': VmPhaseParsing.toJson(phase),
    'spec_generation': specGeneration,
    'observed_generation': observedGeneration,
    'driver_generation': driverGeneration,
    'guest_agent': guestAgent.name,
    'restart_required': restartRequired,
    'last_transition_at': formatDateTime(lastTransitionAt),
    'last_error': lastError?.toJson(),
  };

  @override
  List<Object?> get equalityFields => [
    desiredState,
    phase,
    specGeneration,
    observedGeneration,
    driverGeneration,
    guestAgent,
    restartRequired,
    lastTransitionAt,
    lastError,
  ];
}

final class VirtualMachine extends ValueObject {
  const VirtualMachine({
    required this.metadata,
    required this.spec,
    required this.status,
  });

  factory VirtualMachine.fromJson(Object? value) {
    final json = readJsonObject(value, 'VirtualMachine');
    expectJsonKeys(
      json,
      required: const {'api_version', 'kind', 'metadata', 'spec', 'status'},
      optional: const {},
      name: 'VirtualMachine',
    );
    if (json['api_version'] != vmApiVersion || json['kind'] != vmKind) {
      throw FormatException('unsupported VirtualMachine api_version or kind');
    }
    return VirtualMachine(
      metadata: VmMetadata.fromJson(json['metadata']),
      spec: VmSpec.fromJson(json['spec']),
      status: VmStatus.fromJson(json['status']),
    );
  }

  final VmMetadata metadata;
  final VmSpec spec;
  final VmStatus status;

  Map<String, Object?> toJson() => {
    'api_version': vmApiVersion,
    'kind': vmKind,
    'metadata': metadata.toJson(),
    'spec': spec.toJson(),
    'status': status.toJson(),
  };

  @override
  List<Object?> get equalityFields => [metadata, spec, status];
}
