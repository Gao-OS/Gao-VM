import 'dart:collection';

import 'common.dart';

sealed class JsonValue extends ValueObject {
  const JsonValue();

  factory JsonValue.fromJson(Object? value) => switch (value) {
    null => const JsonNullValue(),
    bool() => JsonBooleanValue(value),
    num() => JsonNumberValue(value),
    String() => JsonStringValue(value),
    List() => JsonArrayValue(value.map(JsonValue.fromJson)),
    Map() => JsonObjectValue.fromJson(value),
    _ => throw FormatException('${value.runtimeType} is not a JSON value'),
  };

  Object? toJson();
}

final class JsonNullValue extends JsonValue {
  const JsonNullValue();

  @override
  List<Object?> get equalityFields => const [];

  @override
  Object? toJson() => null;
}

final class JsonBooleanValue extends JsonValue {
  const JsonBooleanValue(this.value);
  final bool value;

  @override
  List<Object?> get equalityFields => [value];

  @override
  Object toJson() => value;
}

final class JsonNumberValue extends JsonValue {
  JsonNumberValue(this.value) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError.value(value, 'value', 'must be a finite JSON number');
    }
  }
  final num value;

  @override
  List<Object?> get equalityFields => [value];

  @override
  Object toJson() => value;
}

final class JsonStringValue extends JsonValue {
  const JsonStringValue(this.value);
  final String value;

  @override
  List<Object?> get equalityFields => [value];

  @override
  Object toJson() => value;
}

final class JsonArrayValue extends JsonValue {
  JsonArrayValue(Iterable<JsonValue> values)
    : values = List<JsonValue>.unmodifiable(values);

  final List<JsonValue> values;

  @override
  List<Object?> get equalityFields => [values];

  @override
  Object toJson() => values.map((value) => value.toJson()).toList();
}

final class JsonProperty extends ValueObject {
  const JsonProperty(this.name, this.value);
  final String name;
  final JsonValue value;

  @override
  List<Object?> get equalityFields => [name, value];
}

final class JsonObjectValue extends JsonValue {
  JsonObjectValue(Iterable<JsonProperty> properties)
    : properties = _canonicalProperties(properties);

  factory JsonObjectValue.fromJson(Object? value) {
    final json = readJsonObject(value, 'JSON value');
    return JsonObjectValue(
      json.entries.map(
        (entry) => JsonProperty(entry.key, JsonValue.fromJson(entry.value)),
      ),
    );
  }

  static final empty = JsonObjectValue(const []);

  final List<JsonProperty> properties;

  JsonValue? operator [](String name) {
    for (final property in properties) {
      if (property.name == name) return property.value;
    }
    return null;
  }

  @override
  List<Object?> get equalityFields => [properties];

  @override
  Map<String, Object?> toJson() => UnmodifiableMapView({
    for (final property in properties) property.name: property.value.toJson(),
  });
}

List<JsonProperty> _canonicalProperties(Iterable<JsonProperty> properties) {
  final result = properties.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (var index = 1; index < result.length; index++) {
    if (result[index - 1].name == result[index].name) {
      throw ArgumentError('JSON object property names must be unique');
    }
  }
  return List<JsonProperty>.unmodifiable(result);
}
