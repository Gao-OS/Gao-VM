import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  test('JSON object equality and hash do not depend on property order', () {
    final first = JsonObjectValue.fromJson({
      'alpha': 1,
      'nested': {'enabled': true, 'name': 'vm'},
    });
    final second = JsonObjectValue.fromJson({
      'nested': {'name': 'vm', 'enabled': true},
      'alpha': 1,
    });

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
