import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  final vmId = VmId.generate();
  final at = DateTime.utc(2026, 10, 9, 1, 2, 3, 456, 789);

  test(
    'LogReference round trips the frozen fields and explicit nullable artifact',
    () {
      for (final kind in LogKind.values) {
        for (final artifactId in [null, ArtifactId.generate()]) {
          final reference = LogReference(
            kind: kind,
            vmId: vmId,
            sizeBytes: 0,
            updatedAt: at,
            artifactId: artifactId,
          );
          expect(reference.toJson(), {
            'kind': kind.name,
            'vm_id': vmId.value,
            'size_bytes': 0,
            'updated_at': '2026-10-09T01:02:03.456789Z',
            'artifact_id': artifactId?.value,
          });
          expect(LogReference.fromJson(reference.toJson()), reference);
          expect(reference.updatedAt.isUtc, isTrue);
        }
      }
    },
  );

  test(
    'LogReference rejects invalid wire values, omitted fields and host paths',
    () {
      final valid = LogReference(
        kind: LogKind.driver,
        vmId: vmId,
        sizeBytes: 1,
        updatedAt: at,
      ).toJson();
      for (final value in <Object?>[
        null,
        [],
        {},
        {...valid, 'kind': 'stdout'},
        {...valid, 'kind': null},
        {...valid, 'vm_id': ImageId.generate().value},
        {...valid, 'artifact_id': vmId.value},
        {...valid, 'size_bytes': 1.0},
        {...valid, 'size_bytes': '1'},
        {...valid, 'updated_at': '2026-02-30T01:02:03Z'},
        {...valid, 'updated_at': '2026-00-09T01:02:03Z'},
        {...valid, 'updated_at': '2026-10-00T01:02:03Z'},
        {...valid, 'updated_at': '2026-10-09T24:02:03Z'},
        {...valid, 'updated_at': '2026-10-09T01:60:03Z'},
        {...valid, 'updated_at': '2026-10-09T01:02:61Z'},
        {...valid, 'updated_at': '2026-10-09T01:02:03+24:00'},
        {...valid, 'updated_at': '2026-10-09T01:02:03-01:60'},
        {...valid, 'updated_at': '2026-10-09T01:02:03'},
        {...valid, 'path': '/private/host/log'},
        {...valid}..remove('artifact_id'),
      ]) {
        expect(
          () => LogReference.fromJson(value),
          throwsFormatException,
          reason: '$value',
        );
      }
      expect(
        () => LogReference.fromJson({...valid, 'size_bytes': -1}),
        throwsArgumentError,
      );
      final offset = LogReference.fromJson({
        ...valid,
        'updated_at': '2026-10-09T09:02:03+08:00',
      });
      expect(offset.updatedAt, DateTime.utc(2026, 10, 9, 1, 2, 3));
      expect(offset.toJson()['updated_at'], '2026-10-09T01:02:03.000Z');
    },
  );

  test('LogReference cannot emit a timestamp outside the wire year range', () {
    for (final year in [-1, 10000]) {
      expect(
        () => LogReference(
          kind: LogKind.driver,
          vmId: vmId,
          sizeBytes: 1,
          updatedAt: DateTime.utc(year),
        ),
        throwsArgumentError,
      );
    }
  });
}
