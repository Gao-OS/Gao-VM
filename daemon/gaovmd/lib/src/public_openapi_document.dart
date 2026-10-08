import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

const _vmSpecReference = r'../vm-spec/v1alpha1.schema.json#/$defs/';
const _vmSpecComponent = 'VmSpecV1Alpha1Definitions';
const _vmSpecPointer = '#/components/schemas/$_vmSpecComponent/\$defs/';
const _maxDocumentBytes = 1024 * 1024;

/// Loads the public document and links its canonical VmSpec definitions locally.
/// Only the known VmSpec file is read; references never trigger network access.
Future<Map<String, Object?>> loadPublicOpenApiDocument(File source) async {
  final document = _object(
    jsonDecode(jsonEncode(loadYaml(await _readText(source)))),
    'OpenAPI document',
  );
  if (_references(
    document,
  ).any((node) => (node[r'$ref'] as String).startsWith(_vmSpecReference))) {
    final vmSpec = _object(
      jsonDecode(
        await _readText(
          File.fromUri(
            source.absolute.uri.resolve('../vm-spec/v1alpha1.schema.json'),
          ),
        ),
      ),
      'VmSpec document',
    );
    final definitions = _object(vmSpec[r'$defs'], 'VmSpec definitions');
    for (final node in _references(definitions)) {
      final reference = node[r'$ref'] as String;
      if (reference.startsWith(r'#/$defs/')) {
        node[r'$ref'] = '$_vmSpecPointer${reference.substring(8)}';
      }
    }
    final schemas = _object(
      _object(document['components'], 'OpenAPI components')['schemas'],
      'OpenAPI schemas',
    );
    if (schemas.containsKey(_vmSpecComponent)) {
      throw const FormatException('generated VmSpec component already exists');
    }
    // This is a linked copy of the definitions, not an embedded $id resource.
    // Keeping the original $id here would change the base of local references.
    schemas[_vmSpecComponent] = {
      r'$schema': vmSpec[r'$schema'],
      r'$defs': definitions,
    };
    for (final node in _references(document)) {
      final reference = node[r'$ref'] as String;
      if (reference.startsWith(_vmSpecReference)) {
        node[r'$ref'] =
            '$_vmSpecPointer${reference.substring(_vmSpecReference.length)}';
      }
    }
  }
  for (final node in _references(document)) {
    final reference = node[r'$ref'] as String;
    if (!reference.startsWith('#')) {
      throw const FormatException('unsupported external OpenAPI reference');
    }
    _verifyPointer(document, reference);
  }
  if (utf8.encode(jsonEncode(document)).length > _maxDocumentBytes) {
    throw const FormatException('linked OpenAPI document exceeds 1 MiB');
  }
  return document;
}

Future<String> _readText(File source) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source.openRead()) {
    if (bytes.length + chunk.length > _maxDocumentBytes) {
      throw const FormatException('OpenAPI source exceeds 1 MiB');
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

void _verifyPointer(Map<String, Object?> document, String reference) {
  final pointer = Uri.decodeComponent(reference.substring(1));
  if (pointer.isEmpty) return;
  if (!pointer.startsWith('/')) {
    throw const FormatException('OpenAPI references must use JSON pointers');
  }
  Object? value = document;
  for (final part in pointer.substring(1).split('/')) {
    if (RegExp(r'~(?![01])').hasMatch(part)) {
      throw const FormatException('invalid OpenAPI JSON pointer escape');
    }
    final key = part.replaceAll('~1', '/').replaceAll('~0', '~');
    if (value is Map<String, Object?> && value.containsKey(key)) {
      value = value[key];
    } else if (value is List && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(key)) {
      final index = int.tryParse(key);
      if (index == null || index >= value.length) {
        throw FormatException('unresolved OpenAPI reference: $reference');
      }
      value = value[index];
    } else {
      throw FormatException('unresolved OpenAPI reference: $reference');
    }
  }
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be a JSON object');
  }
  return value;
}

Iterable<Map<String, Object?>> _references(Object? value) sync* {
  if (value is Map<String, Object?>) {
    if (const {
      r'$id',
      r'$anchor',
      r'$dynamicAnchor',
      r'$dynamicRef',
      r'$recursiveAnchor',
      r'$recursiveRef',
    }.any(value.containsKey)) {
      throw const FormatException('unsupported OpenAPI reference scope');
    }
    if (value.containsKey(r'$ref')) {
      if (value[r'$ref'] is! String) {
        throw const FormatException('OpenAPI reference must be a string');
      }
      yield value;
    }
    for (final child in value.values) {
      yield* _references(child);
    }
  } else if (value is List) {
    for (final child in value) {
      yield* _references(child);
    }
  }
}
