import 'package:gaovm_models/gaovm_models.dart';

/// Frozen public argv/cwd/env/capture request. All values remain guest data.
final class GuestExecRequest {
  GuestExecRequest._(this._value);

  factory GuestExecRequest.fromJson(Map<String, Object?> json) {
    _keys(json, {'argv', 'cwd', 'env', 'timeout_seconds', 'capture'});
    final argv = json['argv'];
    if (argv is! List || argv.isEmpty || argv.length > 1024) _invalid();
    for (final argument in argv) {
      _string(argument, 0, 131072);
    }
    _string(json['cwd'], 1, 4096);
    for (final entry in _object(json['env']).entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entry.key)) _invalid();
      _string(entry.value, 0, 131072);
    }
    final timeout = json['timeout_seconds'];
    if (timeout is! num || !timeout.isFinite || timeout <= 0 || timeout > 86400)
      _invalid();
    final capture = _object(json['capture']);
    _keys(capture, {'stdout', 'stderr', 'max_inline_bytes'});
    final inline = capture['max_inline_bytes'];
    if (capture['stdout'] is! bool ||
        capture['stderr'] is! bool ||
        inline is! num ||
        !inline.isFinite ||
        inline < 0 ||
        inline > 1048576 ||
        inline % 1 != 0)
      _invalid();
    return GuestExecRequest._(
      JsonObjectValue.fromJson({
        ...json,
        'capture': {...capture, 'max_inline_bytes': inline.toInt()},
      }),
    );
  }

  final JsonObjectValue _value;
  Map<String, Object?> toJson() => _value.toJson();
  num get timeoutSeconds => _value.toJson()['timeout_seconds'] as num;
  int get maxInlineBytes =>
      (_value.toJson()['capture'] as Map)['max_inline_bytes'] as int;
  Duration get timeout =>
      Duration(microseconds: (timeoutSeconds * 1000000).ceil());
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, Object?>.from(value);
}

void _keys(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains))
    _invalid();
}

void _string(Object? value, int minimum, int maximum) {
  if (value is! String ||
      value.runes.length < minimum ||
      value.runes.length > maximum)
    _invalid();
}

Never _invalid() => throw const FormatException('invalid guest exec request');
