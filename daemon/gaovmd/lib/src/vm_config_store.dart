import 'dart:convert';
import 'dart:io';

import 'atomic_json_file.dart';

typedef ConfigEventEmitter = void Function(String type, Map<String, Object?> payload);

class VmConfigStore {
  VmConfigStore({required this.stateDir});

  final String stateDir;

  String get _configPath => '$stateDir/config.json';
  String get _pendingPath => '$stateDir/pending_config.json';

  Future<Map<String, Object?>> getCurrentConfig() async {
    final file = File(_configPath);
    if (!await file.exists()) {
      return _defaultConfig();
    }
    final config = await _readJsonFile(file);
    _validateFullConfig(config);
    return config;
  }

  Future<Map<String, Object?>?> getPendingConfig() async {
    final file = File(_pendingPath);
    if (!await file.exists()) {
      return null;
    }
    final config = await _readJsonFile(file);
    _validateFullConfig(config);
    return config;
  }

  Future<Map<String, Object?>> getConfigSnapshot() async {
    final current = await getCurrentConfig();
    final pending = await getPendingConfig();
    return {
      'current': current,
      'pending': pending,
      'hasPending': pending != null,
    };
  }

  Future<Map<String, Object?>> setConfig(
    Map<String, Object?> nextConfig, {
    required bool isRunning,
    required ConfigEventEmitter emitEvent,
  }) async {
    _validateFullConfig(nextConfig);
    return _writeConfig(nextConfig, isRunning: isRunning, emitEvent: emitEvent);
  }

  Future<Map<String, Object?>> patchConfig(
    Map<String, Object?> patch, {
    required bool isRunning,
    required ConfigEventEmitter emitEvent,
  }) async {
    _validatePatch(patch);
    final current = await getCurrentConfig();
    final pending = await getPendingConfig();
    final base = isRunning && pending != null ? pending : current;
    final merged = _deepMergeMap(base, patch);
    _validateFullConfig(merged);
    final result = await _writeConfig(merged, isRunning: isRunning, emitEvent: emitEvent);
    return {
      ...result,
      'patchedFrom': isRunning && pending != null ? 'pending' : 'current',
    };
  }

  Future<Map<String, Object?>> _writeConfig(
    Map<String, Object?> nextConfig, {
    required bool isRunning,
    required ConfigEventEmitter emitEvent,
  }) async {
    final current = await getCurrentConfig();
    final pendingBefore = await getPendingConfig();
    final restartRequired = _hasRestartRequiredChange(current, nextConfig);

    if (isRunning && restartRequired) {
      await AtomicJsonFile(_pendingPath).write(nextConfig);
      emitEvent(
        pendingBefore == null ? 'event.pending_config_written' : 'event.pending_config_replaced',
        {
          'restartRequired': true,
          'currentConfigUnchanged': true,
        },
      );
      return {
        'applied': false,
        'restartRequired': true,
        'pendingReplaced': pendingBefore != null,
        'current': current,
        'pending': nextConfig,
      };
    }

    await AtomicJsonFile(_configPath).write(nextConfig);
    if (!isRunning) {
      final pendingFile = File(_pendingPath);
      if (await pendingFile.exists()) {
        await pendingFile.delete();
      }
    }
    emitEvent('config.updated', {
      'restartRequired': restartRequired,
      'applied': true,
      'whileRunning': isRunning,
    });
    return {
      'applied': true,
      'restartRequired': restartRequired,
      'current': nextConfig,
      'pending': isRunning ? pendingBefore : null,
    };
  }

  Future<bool> activatePendingIfPresent({required ConfigEventEmitter emitEvent}) async {
    final pending = await getPendingConfig();
    if (pending == null) {
      return false;
    }
    await AtomicJsonFile(_configPath).write(pending);
    final pendingFile = File(_pendingPath);
    if (await pendingFile.exists()) {
      await pendingFile.delete();
    }
    emitEvent('config.pending_applied', {
      'applied': true,
    });
    return true;
  }

  Future<Map<String, Object?>> _readJsonFile(File file) async {
    final text = await file.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw StateError('Config file must contain a JSON object: ${file.path}');
    }
    return Map<String, Object?>.from(decoded);
  }

  void _validateFullConfig(Map<String, Object?> config) {
    final allowedTop = {'cpu', 'memory', 'boot', 'disk', 'network', 'graphics'};
    final actualTop = config.keys.toSet();
    if (!actualTop.containsAll(allowedTop) || !allowedTop.containsAll(actualTop)) {
      throw StateError('Config must contain exactly keys: ${allowedTop.toList()..sort()}');
    }

    _requireInt(config, 'cpu', min: 1);
    _requireInt(config, 'memory', min: 134217728);

    final boot = _requireObject(config, 'boot');
    _requireExactKeys(boot, {'loader', 'kernelPath', 'initrdPath', 'commandLine'}, path: 'boot');
    _requireString(boot, 'loader', path: 'boot');
    _requireStringOrNull(boot, 'kernelPath', path: 'boot');
    _requireStringOrNull(boot, 'initrdPath', path: 'boot');
    _requireStringOrNull(boot, 'commandLine', path: 'boot');

    final disk = _requireObject(config, 'disk');
    _requireExactKeys(disk, {'path', 'sizeMiB'}, path: 'disk');
    _requireStringOrNull(disk, 'path', path: 'disk');
    final diskSize = disk['sizeMiB'];
    if (diskSize != null && (diskSize is! int || diskSize < 64)) {
      throw StateError('disk.sizeMiB must be null or an integer >= 64');
    }

    final network = _requireObject(config, 'network');
    _requireExactKeys(network, {'mode'}, path: 'network');
    _requireString(network, 'mode', path: 'network');

    final graphics = _requireObject(config, 'graphics');
    _requireExactKeys(graphics, {'enabled', 'width', 'height'}, path: 'graphics');
    _requireBool(graphics, 'enabled', path: 'graphics');
    _requireInt(graphics, 'width', min: 64);
    _requireInt(graphics, 'height', min: 64);
  }

  void _validatePatch(Map<String, Object?> patch) {
    if (patch.isEmpty) {
      throw StateError('Config patch must not be empty');
    }
    final allowedTop = {'cpu', 'memory', 'boot', 'disk', 'network', 'graphics'};
    for (final entry in patch.entries) {
      if (!allowedTop.contains(entry.key)) {
        throw StateError('Unsupported config patch key: ${entry.key}');
      }
      switch (entry.key) {
        case 'cpu':
          if (entry.value is! int || (entry.value as int) < 1) {
            throw StateError('cpu must be an integer >= 1');
          }
        case 'memory':
          if (entry.value is! int || (entry.value as int) < 134217728) {
            throw StateError('memory must be an integer >= 134217728');
          }
        case 'boot':
          _validatePatchObject(
            entry.value,
            allowedKeys: {'loader', 'kernelPath', 'initrdPath', 'commandLine'},
            path: 'boot',
          );
          final boot = Map<String, Object?>.from(entry.value as Map);
          if (boot.containsKey('loader') && boot['loader'] is! String) {
            throw StateError('boot.loader must be a string');
          }
          if (boot.containsKey('kernelPath') &&
              boot['kernelPath'] != null &&
              boot['kernelPath'] is! String) {
            throw StateError('boot.kernelPath must be a string or null');
          }
          if (boot.containsKey('initrdPath') &&
              boot['initrdPath'] != null &&
              boot['initrdPath'] is! String) {
            throw StateError('boot.initrdPath must be a string or null');
          }
          if (boot.containsKey('commandLine') &&
              boot['commandLine'] != null &&
              boot['commandLine'] is! String) {
            throw StateError('boot.commandLine must be a string or null');
          }
        case 'disk':
          _validatePatchObject(entry.value, allowedKeys: {'path', 'sizeMiB'}, path: 'disk');
          final disk = Map<String, Object?>.from(entry.value as Map);
          if (disk.containsKey('path') && disk['path'] != null && disk['path'] is! String) {
            throw StateError('disk.path must be a string or null');
          }
          if (disk.containsKey('sizeMiB') &&
              disk['sizeMiB'] != null &&
              (disk['sizeMiB'] is! int || (disk['sizeMiB'] as int) < 64)) {
            throw StateError('disk.sizeMiB must be null or an integer >= 64');
          }
        case 'network':
          _validatePatchObject(entry.value, allowedKeys: {'mode'}, path: 'network');
          final network = Map<String, Object?>.from(entry.value as Map);
          if (network.containsKey('mode') && network['mode'] is! String) {
            throw StateError('network.mode must be a string');
          }
        case 'graphics':
          _validatePatchObject(entry.value, allowedKeys: {'enabled', 'width', 'height'}, path: 'graphics');
          final graphics = Map<String, Object?>.from(entry.value as Map);
          if (graphics.containsKey('enabled') && graphics['enabled'] is! bool) {
            throw StateError('graphics.enabled must be a bool');
          }
          if (graphics.containsKey('width') &&
              (graphics['width'] is! int || (graphics['width'] as int) < 64)) {
            throw StateError('graphics.width must be an integer >= 64');
          }
          if (graphics.containsKey('height') &&
              (graphics['height'] is! int || (graphics['height'] as int) < 64)) {
            throw StateError('graphics.height must be an integer >= 64');
          }
      }
    }
  }

  void _validatePatchObject(
    Object? value, {
    required Set<String> allowedKeys,
    required String path,
  }) {
    if (value is! Map) {
      throw StateError('$path patch must be a JSON object');
    }
    final obj = Map<String, Object?>.from(value);
    if (obj.isEmpty) {
      throw StateError('$path patch must not be empty');
    }
    for (final key in obj.keys) {
      if (!allowedKeys.contains(key)) {
        throw StateError('Unsupported $path patch key: $key');
      }
    }
  }

  Map<String, Object?> _deepMergeMap(Map<String, Object?> base, Map<String, Object?> patch) {
    final out = <String, Object?>{};
    for (final entry in base.entries) {
      out[entry.key] = _cloneJsonValue(entry.value);
    }
    for (final entry in patch.entries) {
      final existing = out[entry.key];
      final next = entry.value;
      if (existing is Map && next is Map) {
        out[entry.key] = _deepMergeMap(
          Map<String, Object?>.from(existing),
          Map<String, Object?>.from(next),
        );
      } else {
        out[entry.key] = _cloneJsonValue(next);
      }
    }
    return out;
  }

  Object? _cloneJsonValue(Object? value) {
    if (value is Map) {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        out[entry.key.toString()] = _cloneJsonValue(entry.value);
      }
      return out;
    }
    if (value is List) {
      return value.map(_cloneJsonValue).toList(growable: false);
    }
    return value;
  }

  Map<String, Object?> _requireObject(Map<String, Object?> parent, String key) {
    final value = parent[key];
    if (value is! Map) {
      throw StateError('$key must be an object');
    }
    return Map<String, Object?>.from(value);
  }

  void _requireExactKeys(Map<String, Object?> obj, Set<String> keys, {required String path}) {
    final actual = obj.keys.toSet();
    if (!actual.containsAll(keys) || !keys.containsAll(actual)) {
      throw StateError('$path must contain exactly keys: ${keys.toList()..sort()}');
    }
  }

  void _requireInt(Map<String, Object?> obj, String key, {required int min}) {
    final value = obj[key];
    if (value is! int || value < min) {
      throw StateError('$key must be an integer >= $min');
    }
  }

  void _requireString(Map<String, Object?> obj, String key, {String? path}) {
    final value = obj[key];
    if (value is! String) {
      throw StateError('${path == null ? key : '$path.$key'} must be a string');
    }
  }

  void _requireStringOrNull(Map<String, Object?> obj, String key, {String? path}) {
    final value = obj[key];
    if (value != null && value is! String) {
      throw StateError('${path == null ? key : '$path.$key'} must be a string or null');
    }
  }

  void _requireBool(Map<String, Object?> obj, String key, {String? path}) {
    final value = obj[key];
    if (value is! bool) {
      throw StateError('${path == null ? key : '$path.$key'} must be a bool');
    }
  }

  Map<String, Object?> _defaultConfig() {
    return {
      'cpu': 2,
      'memory': 2147483648,
      'boot': {
        'loader': 'linux',
        'kernelPath': null,
        'initrdPath': null,
        'commandLine': null,
      },
      'disk': {
        'path': null,
        'sizeMiB': 8192,
      },
      'network': {
        'mode': 'shared',
      },
      'graphics': {
        'enabled': true,
        'width': 1280,
        'height': 800,
      },
    };
  }
}

bool _hasRestartRequiredChange(Map<String, Object?> current, Map<String, Object?> next) {
  if (!_jsonEquals(current['cpu'], next['cpu'])) return true;
  if (!_jsonEquals(current['memory'], next['memory'])) return true;
  if (!_jsonEquals(current['boot'], next['boot'])) return true;
  if (!_jsonEquals(_getPath(current, ['disk', 'path']), _getPath(next, ['disk', 'path']))) {
    return true;
  }
  if (!_jsonEquals(_getPath(current, ['network', 'mode']), _getPath(next, ['network', 'mode']))) {
    return true;
  }
  if (!_jsonEquals(current['graphics'], next['graphics'])) return true;
  return false;
}

Object? _getPath(Map<String, Object?> root, List<String> path) {
  Object? cur = root;
  for (final segment in path) {
    if (cur is! Map) {
      return null;
    }
    cur = cur[segment];
  }
  return cur;
}

bool _jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    final aMap = a;
    final bMap = b;
    if (a.length != b.length) return false;
    final aKeys = a.keys.map((e) => e.toString()).toSet();
    final bKeys = b.keys.map((e) => e.toString()).toSet();
    if (aKeys.length != bKeys.length || !aKeys.containsAll(bKeys)) return false;
    for (final key in aKeys) {
      if (!_jsonEquals(aMap[key], bMap[key])) return false;
    }
    return true;
  }
  return a == b;
}
