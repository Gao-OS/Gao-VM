import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

Map<String, Object?> _validConfig({
  int cpu = 2,
  int memory = 2147483648,
  String loader = 'linux',
  String? kernelPath,
  String? initrdPath,
  String? commandLine,
  String? diskPath,
  int? diskSizeMiB = 8192,
  String networkMode = 'shared',
  bool graphicsEnabled = true,
  int graphicsWidth = 1280,
  int graphicsHeight = 800,
}) {
  return {
    'cpu': cpu,
    'memory': memory,
    'boot': {
      'loader': loader,
      'kernelPath': kernelPath,
      'initrdPath': initrdPath,
      'commandLine': commandLine,
    },
    'disk': {
      'path': diskPath,
      'sizeMiB': diskSizeMiB,
    },
    'network': {
      'mode': networkMode,
    },
    'graphics': {
      'enabled': graphicsEnabled,
      'width': graphicsWidth,
      'height': graphicsHeight,
    },
  };
}

void main() {
  late Directory tempDir;
  late VmConfigStore store;
  late List<Map<String, Object?>> emittedEvents;

  void emitEvent(String type, Map<String, Object?> payload) {
    emittedEvents.add({'type': type, ...payload});
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('config-test-');
    store = VmConfigStore(stateDir: tempDir.path);
    emittedEvents = [];
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('getCurrentConfig', () {
    test('returns default config when no file exists', () async {
      final config = await store.getCurrentConfig();
      expect(config['cpu'], 2);
      expect(config['memory'], 2147483648);
      expect((config['boot'] as Map)['loader'], 'linux');
      expect((config['graphics'] as Map)['enabled'], true);
      expect((config['graphics'] as Map)['width'], 1280);
    });

    test('reads config from file when exists', () async {
      final file = File('${tempDir.path}/config.json');
      await file.writeAsString(jsonEncode(_validConfig(cpu: 4)));
      final config = await store.getCurrentConfig();
      expect(config['cpu'], 4);
    });
  });

  group('setConfig', () {
    test('writes config directly when not running', () async {
      final result = await store.setConfig(
        _validConfig(cpu: 4),
        isRunning: false,
        emitEvent: emitEvent,
      );
      expect(result['applied'], true);

      final saved = await store.getCurrentConfig();
      expect(saved['cpu'], 4);

      expect(emittedEvents.any((e) => e['type'] == 'config.updated'), isTrue);
    });

    test('stages to pending when running and restart required', () async {
      // Write initial config.
      await store.setConfig(
        _validConfig(cpu: 2),
        isRunning: false,
        emitEvent: emitEvent,
      );
      emittedEvents.clear();

      // Change cpu while running — requires restart.
      final result = await store.setConfig(
        _validConfig(cpu: 8),
        isRunning: true,
        emitEvent: emitEvent,
      );
      expect(result['applied'], false);
      expect(result['restartRequired'], true);
      expect(result['pending'], isNotNull);

      // Current config should still be cpu=2.
      final current = await store.getCurrentConfig();
      expect(current['cpu'], 2);

      // Pending should be cpu=8.
      final pending = await store.getPendingConfig();
      expect(pending, isNotNull);
      expect(pending!['cpu'], 8);

      expect(
        emittedEvents.any((e) => e['type'] == 'event.pending_config_written'),
        isTrue,
      );
    });

    test('replaces existing pending config', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      await store.setConfig(_validConfig(cpu: 4),
          isRunning: true, emitEvent: emitEvent);
      emittedEvents.clear();

      await store.setConfig(_validConfig(cpu: 8),
          isRunning: true, emitEvent: emitEvent);

      expect(
        emittedEvents.any((e) => e['type'] == 'event.pending_config_replaced'),
        isTrue,
      );

      final pending = await store.getPendingConfig();
      expect(pending!['cpu'], 8);
    });

    test('throws on invalid config', () {
      expect(
        () => store.setConfig(
          {'cpu': 0},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('clears pending config when not running', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      await store.setConfig(_validConfig(cpu: 4),
          isRunning: true, emitEvent: emitEvent);

      // Pending should exist now.
      expect(await store.getPendingConfig(), isNotNull);

      // Setting config while not running should clear pending.
      await store.setConfig(_validConfig(cpu: 6),
          isRunning: false, emitEvent: emitEvent);
      expect(await store.getPendingConfig(), isNull);
    });
  });

  group('patchConfig', () {
    test('merges patch into current config', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      emittedEvents.clear();

      final result = await store.patchConfig(
        {'cpu': 4},
        isRunning: false,
        emitEvent: emitEvent,
      );
      expect(result['applied'], true);

      final config = await store.getCurrentConfig();
      expect(config['cpu'], 4);
      // Other fields unchanged.
      expect(config['memory'], 2147483648);
    });

    test('deep merges nested objects', () async {
      await store.setConfig(_validConfig(),
          isRunning: false, emitEvent: emitEvent);
      emittedEvents.clear();

      await store.patchConfig(
        {
          'graphics': {'width': 1920},
        },
        isRunning: false,
        emitEvent: emitEvent,
      );

      final config = await store.getCurrentConfig();
      final graphics = config['graphics'] as Map;
      expect(graphics['width'], 1920);
      // Height unchanged.
      expect(graphics['height'], 800);
    });

    test('patches pending config when running and pending exists', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      await store.setConfig(_validConfig(cpu: 4),
          isRunning: true, emitEvent: emitEvent);
      emittedEvents.clear();

      final result = await store.patchConfig(
        {'cpu': 8},
        isRunning: true,
        emitEvent: emitEvent,
      );
      expect(result['patchedFrom'], 'pending');

      final pending = await store.getPendingConfig();
      expect(pending!['cpu'], 8);
    });

    test('rejects empty patch', () {
      expect(
        () => store.patchConfig(
          {},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('rejects invalid patch key', () {
      expect(
        () => store.patchConfig(
          {'unknown_key': 42},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('validates patch values', () {
      expect(
        () => store.patchConfig(
          {'cpu': 0},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });
  });

  group('activatePendingIfPresent', () {
    test('returns false when no pending config', () async {
      final result = await store.activatePendingIfPresent(emitEvent: emitEvent);
      expect(result, false);
    });

    test('activates pending config and removes pending file', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      await store.setConfig(_validConfig(cpu: 4),
          isRunning: true, emitEvent: emitEvent);
      emittedEvents.clear();

      final activated =
          await store.activatePendingIfPresent(emitEvent: emitEvent);
      expect(activated, true);

      final current = await store.getCurrentConfig();
      expect(current['cpu'], 4);

      final pending = await store.getPendingConfig();
      expect(pending, isNull);

      expect(
        emittedEvents.any((e) => e['type'] == 'config.pending_applied'),
        isTrue,
      );
    });
  });

  group('getConfigSnapshot', () {
    test('includes current and pending', () async {
      await store.setConfig(_validConfig(cpu: 2),
          isRunning: false, emitEvent: emitEvent);
      await store.setConfig(_validConfig(cpu: 4),
          isRunning: true, emitEvent: emitEvent);

      final snapshot = await store.getConfigSnapshot();
      expect(snapshot['hasPending'], true);
      expect((snapshot['current'] as Map)['cpu'], 2);
      expect((snapshot['pending'] as Map)['cpu'], 4);
    });

    test('hasPending is false when no pending', () async {
      final snapshot = await store.getConfigSnapshot();
      expect(snapshot['hasPending'], false);
      expect(snapshot['pending'], isNull);
    });
  });

  group('validation', () {
    test('rejects cpu less than 1', () {
      expect(
        () => store.setConfig(
          _validConfig(cpu: 0),
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('rejects memory less than 128 MB', () {
      expect(
        () => store.setConfig(
          _validConfig(memory: 100),
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('rejects disk size less than 64 MiB', () {
      expect(
        () => store.setConfig(
          _validConfig(diskSizeMiB: 32),
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('accepts null disk size', () async {
      final result = await store.setConfig(
        _validConfig(diskSizeMiB: null),
        isRunning: false,
        emitEvent: emitEvent,
      );
      expect(result['applied'], true);
    });

    test('rejects graphics width less than 64', () {
      expect(
        () => store.setConfig(
          _validConfig(graphicsWidth: 32),
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('rejects extra top-level keys', () {
      expect(
        () => store.setConfig(
          {..._validConfig(), 'extra': true},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('rejects missing top-level keys', () {
      expect(
        () => store.setConfig(
          {'cpu': 2},
          isRunning: false,
          emitEvent: emitEvent,
        ),
        throwsA(isA<ConfigValidationException>()),
      );
    });
  });
}
