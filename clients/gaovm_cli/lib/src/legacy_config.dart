part of '../gaovm_cli.dart';

/// Transitional input translation only. Desired state and revision enforcement
/// remain owned by the public VM application service, never a local config file.
Future<JsonObjectValue> _legacyConfigBody(
  GaoVmApiClient client,
  _Options options,
) async {
  final legacy = _body(options.bodyJson!).toJson();
  final complete = options.legacyConfig == 'config-set';
  _legacyKeys(legacy, const {
    'cpu',
    'memory',
    'boot',
    'disk',
    'network',
    'graphics',
  }, complete);
  for (final field in ['cpu', 'memory']) {
    if (legacy.containsKey(field) && legacy[field] is! int) {
      throw FormatException('$field must be an integer');
    }
  }
  final nested = <String, Map<String, Object?>>{};
  for (final (field, keys) in [
    ('boot', const {'loader', 'kernelPath', 'initrdPath', 'commandLine'}),
    ('disk', const {'path', 'sizeMiB'}),
    ('network', const {'mode'}),
    ('graphics', const {'enabled', 'width', 'height'}),
  ]) {
    if (!legacy.containsKey(field)) continue;
    final object = legacy[field];
    if (object is! Map<String, Object?>) {
      throw FormatException('$field must be an object');
    }
    _legacyKeys(object, keys, complete);
    nested[field] = object;
  }
  // The old size hint was a creation input, not a supported disk resize action.
  if (nested['disk']?['sizeMiB'] != null) {
    throw const FormatException(
      'disk.sizeMiB cannot resize an existing VM; use null',
    );
  }
  final boot = nested['boot'];
  if (boot != null) {
    if (boot.containsKey('loader') &&
        !const {'linux', 'auto'}.contains(boot['loader'])) {
      throw const FormatException('legacy boot.loader must be linux or auto');
    }
    for (final key in ['kernelPath', 'initrdPath']) {
      if (!boot.containsKey(key) || key == 'initrdPath' && boot[key] == null)
        continue;
      if (boot[key] is! String || !(boot[key] as String).startsWith('img_')) {
        throw FormatException(
          '$key now requires a public img_ ID; import the file with image import first',
        );
      }
      _id(boot[key] as String, 'img_');
    }
    if (boot['commandLine'] != null && boot['commandLine'] is! String) {
      throw const FormatException('boot.commandLine must be a string or null');
    }
  }
  VirtualMachine? current;
  if (nested.isNotEmpty) {
    final response = await client.request(
      'GET',
      '/v1/vms/${options.command[2]}',
      timeout: options.timeout,
    );
    current = _legacyVmResponse(response, options.command[2]);
  }
  try {
    final values = <String, Object?>{
      if (legacy.containsKey('cpu')) 'cpu': legacy['cpu'],
      if (legacy.containsKey('memory')) 'memory_bytes': legacy['memory'],
    };
    if (boot != null) {
      final before = current!.spec.boot;
      if (before is! LinuxKernelBoot) {
        throw const FormatException(
          'legacy boot updates require a Linux-kernel VM; use vm patch for EFI',
        );
      }
      values['boot'] = {
        ...before.toJson(),
        if (boot.containsKey('kernelPath'))
          'kernel_image_id': boot['kernelPath'],
        if (boot.containsKey('initrdPath'))
          'initrd_image_id': boot['initrdPath'],
        if (boot.containsKey('commandLine'))
          'command_line': boot['commandLine'] ?? '',
      };
    }
    if (nested['disk'] case final disk?) {
      if (current!.spec.disks.length != 1) {
        throw const FormatException(
          'legacy disk updates require exactly one disk; use vm patch',
        );
      }
      final before = current.spec.disks.single;
      if (!disk.containsKey('path') ||
          disk['path'] is! String ||
          !(disk['path'] as String).startsWith('/') ||
          (disk['path'] as String).contains('\u0000')) {
        throw const FormatException(
          'legacy disk.path must be an absolute external path',
        );
      }
      values['disks'] = [
        {
          ...before.toJson(),
          'source': {'type': 'external', 'path': disk['path']},
        },
      ];
    }
    if (nested['network'] case final network?) {
      if (current!.spec.networks.length != 1) {
        throw const FormatException(
          'legacy network updates require exactly one interface; use vm patch',
        );
      }
      final before = current.spec.networks.single;
      final mode = network['mode'];
      if (mode != 'shared' && mode != 'none') {
        throw const FormatException(
          'legacy network.mode must be shared or none',
        );
      }
      values['networks'] = [
        {
          if (mode == 'shared' && before is SharedNetwork) ...before.toJson(),
          'id': before.id,
          'mode': mode,
        },
      ];
    }
    if (nested['graphics'] case final graphics?) {
      values['graphics'] = {...current!.spec.graphics.toJson(), ...graphics};
    }
    final patch = VmSpecPatch.fromJson(values);
    return JsonObjectValue.fromJson({'spec': patch.toJson()});
  } on ArgumentError catch (error) {
    throw FormatException('invalid legacy config: $error');
  }
}

VirtualMachine _legacyVmResponse(ApiResponse response, String target) {
  try {
    final vm = VirtualMachine.fromJson(response.body.toJson());
    if (response.status != HttpStatus.ok ||
        vm.metadata.id.value != target ||
        response.etag != '"${vm.metadata.revision}"') {
      throw const ApiProtocolException('invalid legacy VM response or target');
    }
    return vm;
  } on FormatException {
    throw const ApiProtocolException('invalid legacy VM response');
  } on ArgumentError {
    throw const ApiProtocolException('invalid legacy VM response');
  }
}

void _legacyKeys(Map<String, Object?> value, Set<String> keys, bool complete) {
  if (value.isEmpty ||
      value.keys.any((key) => !keys.contains(key)) ||
      complete && !value.keys.toSet().containsAll(keys)) {
    throw FormatException(
      'legacy config expects ${complete ? 'exactly' : 'a nonempty subset of'} ${keys.join(', ')}',
    );
  }
}
