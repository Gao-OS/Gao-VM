import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  test(
    'doctor warnings round-trip without failing required host readiness',
    () {
      final report = DoctorResult.fromChecks(const [
        DoctorCheck(
          name: 'database',
          status: DoctorCheckStatus.ok,
          message: 'Readable.',
        ),
        DoctorCheck(
          name: 'guest_profile',
          status: DoctorCheckStatus.warning,
          message: 'Not verified.',
        ),
      ]);
      expect(report.healthy, isTrue);
      final decoded = DoctorResult.fromJson(report.toJson());
      expect(decoded, report);
      expect(decoded.hashCode, report.hashCode);
    },
  );
  test(
    'doctor errors fail readiness and reports freeze their source collection',
    () {
      final checks = [
        const DoctorCheck(
          name: 'runtime',
          status: DoctorCheckStatus.error,
          message: 'Unresolved.',
        ),
      ];
      final report = DoctorResult.fromChecks(checks);
      checks.clear();
      expect(report.healthy, isFalse);
      expect(report.checks, hasLength(1));
      expect(() => report.checks.clear(), throwsUnsupportedError);
      expect(DoctorResult.fromJson(report.toJson()), report);
    },
  );
  test(
    'doctor decoding preserves the frozen schema without extra string or list restrictions',
    () {
      expect(
        DoctorResult.fromJson({
          'healthy': false,
          'checks': <Object?>[],
        }).healthy,
        isFalse,
      );
      final report = DoctorResult.fromJson({
        'healthy': true,
        'checks': [
          {'name': '', 'status': 'warning', 'message': ''},
        ],
      });
      expect(report.checks.single.name, isEmpty);
      expect(report.checks.single.message, isEmpty);
    },
  );
}
