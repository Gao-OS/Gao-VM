import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'served OpenAPI resource schemas resolve without repository files',
    () async {
      final document = await loadPublicOpenApiDocument(_source);
      final served = await _serve(document);
      expect(served['openapi'], '3.1.0');
      final references = _references(served).toList();
      expect(references, isNotEmpty);
      for (final reference in references) {
        expect(reference, startsWith('#/'), reason: reference);
        expect(_resolve(served, reference), isNotNull, reason: reference);
      }
    },
  );
  test(
    'published VmSpec definitions preserve every canonical constraint',
    () async {
      final canonical = Map<String, Object?>.from(
        jsonDecode(
              await File(
                '../../schemas/vm-spec/v1alpha1.schema.json',
              ).readAsString(),
            )
            as Map,
      );
      final served = await _serve(await loadPublicOpenApiDocument(_source));
      final schemas = (served['components'] as Map)['schemas'] as Map;
      final specReference = (schemas['VmSpec'] as Map)[r'$ref'] as String;
      final publishedDefinitions = _resolve(
        served,
        specReference.substring(0, specReference.lastIndexOf('/')),
      );
      expect(
        _expandReferences(publishedDefinitions, served),
        _expandReferences(canonical[r'$defs'], canonical),
      );
    },
  );
  test('startup refuses unknown external schema references', () async {
    await _withSource(
      _schemaDocument({r'$ref': 'https://schemas.invalid/untrusted.json'}),
      (source) async {
        await expectLater(
          loadPublicOpenApiDocument(source),
          throwsFormatException,
        );
      },
    );
  });
  test('startup refuses unresolved local schema pointers', () async {
    await _withSource(
      _schemaDocument({r'$ref': '#/components/schemas/Absent'}),
      (source) async {
        await expectLater(
          loadPublicOpenApiDocument(source),
          throwsFormatException,
        );
      },
    );
  });
  test('startup refuses a non-string schema reference', () async {
    await _withSource(_schemaDocument({r'$ref': 7}), (source) async {
      await expectLater(
        loadPublicOpenApiDocument(source),
        throwsFormatException,
      );
    });
  });
  test('startup refuses a changed VmSpec reference scope', () async {
    final vmSpec =
        jsonDecode(
              await File(
                '../../schemas/vm-spec/v1alpha1.schema.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    ((vmSpec[r'$defs'] as Map)['vmSpec'] as Map)[r'$id'] =
        'https://schemas.invalid/new-scope';
    await _withSource(
      _schemaDocument({
        r'$ref': r'../vm-spec/v1alpha1.schema.json#/$defs/vmSpec',
      }),
      (source) async {
        await expectLater(
          loadPublicOpenApiDocument(source),
          throwsFormatException,
        );
      },
      vmSpec: vmSpec,
    );
  });
  test('linking never overwrites an existing schema component', () async {
    final vmSpec =
        jsonDecode(
              await File(
                '../../schemas/vm-spec/v1alpha1.schema.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final document = _schemaDocument({
      r'$ref': r'../vm-spec/v1alpha1.schema.json#/$defs/vmSpec',
    });
    ((document['components'] as Map)['schemas']
        as Map)['VmSpecV1Alpha1Definitions'] = {
      'type': 'integer',
    };
    await _withSource(document, (source) async {
      await expectLater(
        loadPublicOpenApiDocument(source).then<void>((_) {}),
        throwsFormatException,
      );
    }, vmSpec: vmSpec);
  });
  test(
    'local-only documents need no VmSpec file and accept escaped pointers',
    () async {
      final document = _schemaDocument({
        'type': 'object',
        'properties': {
          'a b/c~d': {'type': 'string'},
          'same': {
            r'$ref':
                '#%2Fcomponents%2Fschemas%2FSample%2Fproperties%2Fa%20b~1c~0d',
          },
        },
      });
      await _withSource(document, (source) async {
        expect(await _serve(await loadPublicOpenApiDocument(source)), document);
      });
    },
  );
  test(
    'startup bounds an OpenAPI source file to the public JSON budget',
    () async {
      await _withSource(
        _schemaDocument({'description': List.filled(1024 * 1024, 'x').join()}),
        (source) async {
          await expectLater(
            loadPublicOpenApiDocument(source).then<void>((_) {}),
            throwsFormatException,
          );
        },
      );
    },
  );
  test('linked output must fit the API client JSON response budget', () async {
    final text = List.filled(600 * 1024, 'x').join();
    final document = _schemaDocument({
      r'$ref': r'../vm-spec/v1alpha1.schema.json#/$defs/vmSpec',
    });
    (document['info'] as Map)['description'] = text;
    final vmSpec =
        jsonDecode(
              await File(
                '../../schemas/vm-spec/v1alpha1.schema.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    (vmSpec[r'$defs'] as Map)['extra'] = {'description': text};
    await _withSource(document, (source) async {
      await expectLater(
        loadPublicOpenApiDocument(source).then<void>((_) {}),
        throwsFormatException,
      );
    }, vmSpec: vmSpec);
  });
}

final _source = File('../../schemas/openapi/gaovm-v1.yaml');

Map<String, Object?> _schemaDocument(Map<String, Object?> schema) => {
  'openapi': '3.1.0',
  'info': {'title': 'GaoVM', 'version': 'v1'},
  'paths': <String, Object?>{},
  'components': {
    'schemas': {'Sample': schema},
  },
};

Future<void> _withSource(
  Map<String, Object?> document,
  Future<void> Function(File) action, {
  Map<String, Object?>? vmSpec,
}) async {
  final temporary = await Directory.systemTemp.createTemp('gvm-schema-source-');
  imageFileMode(temporary.path, 0x1c0);
  try {
    await Directory('${temporary.path}/openapi').create();
    if (vmSpec != null) {
      await Directory('${temporary.path}/vm-spec').create();
      await File(
        '${temporary.path}/vm-spec/v1alpha1.schema.json',
      ).writeAsString(jsonEncode(vmSpec));
    }
    final source = await File(
      '${temporary.path}/openapi/gaovm-v1.json',
    ).writeAsString(jsonEncode(document));
    await action(source);
  } finally {
    await temporary.delete(recursive: true);
  }
}

Iterable<String> _references(Object? value) sync* {
  if (value is Map) {
    if (value[r'$ref'] case final String reference) yield reference;
    for (final child in value.values) {
      yield* _references(child);
    }
  } else if (value is List) {
    for (final child in value) {
      yield* _references(child);
    }
  }
}

Object? _resolve(Map<String, Object?> document, String reference) {
  Object? value = document;
  for (final part in Uri.parse(reference).fragment.substring(1).split('/')) {
    final key = part.replaceAll('~1', '/').replaceAll('~0', '~');
    value = switch (value) {
      Map() => value[key],
      List() => value[int.parse(key)],
      _ => throw StateError('unresolved schema pointer: $reference'),
    };
  }
  return value;
}

Object? _expandReferences(Object? value, Map<String, Object?> document) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: entry.key == r'$ref'
            ? _expandReferences(
                _resolve(document, entry.value as String),
                document,
              )
            : _expandReferences(entry.value, document),
    };
  }
  if (value is List) {
    return value.map((child) => _expandReferences(child, document)).toList();
  }
  return value;
}

Future<Map<String, Object?>> _serve(Map<String, Object?> document) async {
  final temporary =
      await (Platform.isMacOS
              ? Directory('/private/tmp')
              : Directory.systemTemp)
          .createTemp('gvm-schema-');
  imageFileMode(temporary.path, 0x1c0);
  final server = PublicApiServer(
    socketPath: '${temporary.path}/api.sock',
    openApiDocument: document,
    systemHealth: _Health(),
  );
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(server.socketPath, type: InternetAddressType.unix),
      0,
    );
  try {
    await server.start();
    final request = await client.getUrl(
      Uri.parse('http://localhost/v1/openapi.json'),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value('x-request-id'), startsWith('req_'));
    return Map<String, Object?>.from(
      jsonDecode(await utf8.decoder.bind(response).join()) as Map,
    );
  } finally {
    client.close(force: true);
    await server.close();
    await temporary.delete(recursive: true);
  }
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
