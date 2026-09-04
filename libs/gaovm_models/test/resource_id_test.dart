import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  const ulid = '01J00000000000000000000000';

  group('resource IDs', () {
    test('parse every frozen public prefix into its concrete type', () {
      expect(ResourceId.parse('vm_$ulid'), isA<VmId>());
      expect(ResourceId.parse('img_$ulid'), isA<ImageId>());
      expect(ResourceId.parse('op_$ulid'), isA<OperationId>());
      expect(ResourceId.parse('evt_$ulid'), isA<EventId>());
      expect(ResourceId.parse('tr_$ulid'), isA<TestRunId>());
      expect(ResourceId.parse('art_$ulid'), isA<ArtifactId>());
      expect(ResourceId.parse('req_$ulid'), isA<RequestId>());
    });

    test('reject a truncated ID', () {
      expect(() => ResourceId.parse('vm_short'), throwsFormatException);
    });

    test('reject lower-case ULID characters', () {
      expect(
        () => ResourceId.parse('vm_01j00000000000000000000000'),
        throwsFormatException,
      );
    });

    test('reject ambiguous Crockford characters', () {
      expect(
        () => ResourceId.parse('vm_01I00000000000000000000000'),
        throwsFormatException,
      );
    });

    test('reject an unknown resource prefix', () {
      expect(() => ResourceId.parse('wat_$ulid'), throwsFormatException);
    });

    test('reject a concrete ID with the wrong prefix', () {
      expect(() => VmId('img_$ulid'), throwsFormatException);
    });

    test('reject a ULID whose 130-bit encoding exceeds 128 bits', () {
      expect(
        () => ResourceId.parse('vm_81J00000000000000000000000'),
        throwsFormatException,
      );
    });

    test('secure generation produces valid and distinct IDs', () {
      final first = VmId.generate();
      final second = VmId.generate();

      expect(first.value, matches(r'^vm_[0-7][0-9A-HJKMNP-TV-Z]{25}$'));
      expect(second, isNot(first));
      expect(
        first.timestamp.isAfter(DateTime.now().add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('ULID lexical order follows its encoded timestamp', () {
      final first = VmId.generate(timestamp: DateTime.utc(2026));
      final second = VmId.generate(
        timestamp: DateTime.utc(2026).add(const Duration(milliseconds: 1)),
      );

      expect(first.value.compareTo(second.value), isNegative);
      expect(first.timestamp.isBefore(second.timestamp), isTrue);
    });

    test('value equality includes the concrete ID type', () {
      expect(VmId('vm_$ulid'), VmId('vm_$ulid'));
      expect(VmId('vm_$ulid').hashCode, VmId('vm_$ulid').hashCode);
      expect(VmId('vm_$ulid'), isNot(ImageId('img_$ulid')));
    });
  });
}
