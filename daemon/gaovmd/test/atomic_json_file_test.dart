import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atomic-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AtomicJsonFile', () {
    test('writes valid JSON with pretty printing', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({'key': 'value', 'number': 42});

      final content = await File(path).readAsString();
      final decoded = jsonDecode(content);
      expect(decoded['key'], 'value');
      expect(decoded['number'], 42);
      // Should be pretty-printed with indentation.
      expect(content, contains('  "key"'));
    });

    test('file ends with newline', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({'a': 1});

      final content = await File(path).readAsString();
      expect(content.endsWith('\n'), isTrue);
    });

    test('overwrites existing file atomically', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({'version': 1});
      await atomic.write({'version': 2});

      final content = await File(path).readAsString();
      final decoded = jsonDecode(content);
      expect(decoded['version'], 2);
    });

    test('creates parent directories if needed', () async {
      final path = '${tempDir.path}/sub/dir/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({'nested': true});

      final file = File(path);
      expect(await file.exists(), isTrue);
    });

    test('no temp files left after write', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({'clean': true});

      final files = await tempDir.list().toList();
      // Should only have the target file, no .tmp files.
      final tmpFiles =
          files.whereType<File>().where((f) => f.path.contains('.tmp.'));
      expect(tmpFiles, isEmpty);
    });

    test('handles concurrent writes without corruption', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      // Fire multiple writes concurrently.
      await Future.wait([
        atomic.write({'seq': 1}),
        atomic.write({'seq': 2}),
        atomic.write({'seq': 3}),
      ]);

      // File should contain valid JSON (one of the writes wins).
      final content = await File(path).readAsString();
      final decoded = jsonDecode(content);
      expect(decoded['seq'], isA<int>());
    });

    test('writes nested structures correctly', () async {
      final path = '${tempDir.path}/test.json';
      final atomic = AtomicJsonFile(path);

      await atomic.write({
        'nested': {
          'array': [1, 2, 3],
          'deep': {'key': 'value'},
        },
        'null_value': null,
        'bool_value': true,
      });

      final content = await File(path).readAsString();
      final decoded = jsonDecode(content);
      expect((decoded['nested']['array'] as List).length, 3);
      expect(decoded['nested']['deep']['key'], 'value');
      expect(decoded['null_value'], isNull);
      expect(decoded['bool_value'], true);
    });
  });
}
