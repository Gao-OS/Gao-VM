import 'dart:convert';
import 'dart:typed_data';

/// Shared strict guest decoder: inspect raw member names/numbers before JSON
/// map normalization. The binary caller has already enforced its 4 KiB header.
Map<String, Object?> decodeGuestWireObject(Uint8List bytes) =>
    _GuestJson(utf8.decode(bytes)).decode();

final class _GuestJson {
  _GuestJson(this.source);
  final String source;
  int offset = 0;

  Map<String, Object?> decode() {
    final result = _object(_value(0));
    _space();
    if (offset != source.length) _invalid();
    return result;
  }

  Object? _value(int depth, {bool generation = false}) {
    // Matches the resident Rust decoder's recursion bound; frames are bounded
    // before allocation. No stack exhaustion from untrusted nested details.
    if (depth > 128) _invalid();
    _space();
    if (offset >= source.length) _invalid();
    final first = source.codeUnitAt(offset);
    if (first == 123) {
      offset++;
      final result = <String, Object?>{};
      if (!_consume(125)) {
        do {
          final key = _string();
          if (result.containsKey(key)) _invalid();
          _take(58);
          result[key] = _value(
            depth + 1,
            generation: depth == 0 && key == 'driver_generation',
          );
        } while (_consume(44));
        _take(125);
      }
      return result;
    }
    if (first == 91) {
      offset++;
      final result = <Object?>[];
      if (!_consume(93)) {
        do {
          result.add(_value(depth + 1));
        } while (_consume(44));
        _take(93);
      }
      return result;
    }
    if (first == 34) return _string();
    final start = offset;
    while (offset < source.length &&
        !const {
          9,
          10,
          13,
          32,
          44,
          93,
          125,
        }.contains(source.codeUnitAt(offset))) {
      offset++;
    }
    final token = source.substring(start, offset);
    if (generation) return _generation(token);
    return switch (token) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => _number(token),
    };
  }

  num _number(String token) {
    final match = RegExp(
      r'^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$',
    ).firstMatch(token);
    if (match == null) _invalid();
    // JSON Schema integers include 2.0 and 20e-1. Normalize only when the raw
    // coefficient/exponent proves integrality: a rounded double is not proof.
    final fraction = match.group(3) ?? '';
    var digits = '${match.group(2)}$fraction'.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) return 0;
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent != null &&
        exponent >= -_maxFrameBytes &&
        exponent <= _maxFrameBytes) {
      var shift = exponent - fraction.length;
      var end = digits.length;
      while (end > 0 && digits.codeUnitAt(end - 1) == 48) {
        end--;
      }
      shift += digits.length - end;
      digits = digits.substring(0, end);
      if (shift >= 0 && digits.length + shift <= 19) {
        final integer = int.tryParse('${match.group(1)}$digits${'0' * shift}');
        if (integer != null) return integer;
      }
    }
    final value = num.tryParse(token);
    if (value == null) _invalid();
    return value;
  }

  int _generation(String token) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$',
    ).firstMatch(token);
    if (match == null) _invalid();
    final fraction = match.group(2) ?? '';
    final exponent = int.tryParse(match.group(3) ?? '0');
    if (exponent == null ||
        exponent < -_maxFrameBytes ||
        exponent > _maxFrameBytes)
      _invalid();
    var digits = '${match.group(1)}$fraction'.replaceFirst(RegExp(r'^0+'), '');
    var shift = exponent - fraction.length;
    var end = digits.length;
    while (end > 0 && digits.codeUnitAt(end - 1) == 48) {
      end--;
    }
    shift += digits.length - end;
    digits = digits.substring(0, end);
    if (digits.isEmpty || shift < 0 || digits.length + shift > 16) _invalid();
    final value = int.parse('$digits${'0' * shift}');
    if (value < 1 || value > 9007199254740991) _invalid();
    return value;
  }

  String _string() {
    _space();
    final start = offset;
    _take(34);
    while (offset < source.length) {
      final unit = source.codeUnitAt(offset++);
      if (unit == 92) {
        offset++;
        continue;
      }
      if (unit == 34) {
        final value = jsonDecode(source.substring(start, offset)) as String;
        for (var index = 0; index < value.length; index++) {
          final unit = value.codeUnitAt(index);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (++index >= value.length) _invalid();
            final low = value.codeUnitAt(index);
            if (low < 0xdc00 || low > 0xdfff) _invalid();
          } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            _invalid();
          }
        }
        return value;
      }
    }
    _invalid();
  }

  void _space() {
    while (offset < source.length &&
        const {9, 10, 13, 32}.contains(source.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool _consume(int unit) {
    _space();
    if (offset >= source.length || source.codeUnitAt(offset) != unit)
      return false;
    offset++;
    return true;
  }

  void _take(int unit) {
    if (!_consume(unit)) _invalid();
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) _invalid();
  return value;
}

Never _invalid() => throw const FormatException('invalid guest JSON');
const _maxFrameBytes = 16 * 1024 * 1024;
