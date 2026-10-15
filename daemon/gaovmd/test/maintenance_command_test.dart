import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  test(
    'maintenance command captures only bounded output after confirmed exit',
    () async {
      final result = await runMaintenanceCommand('/bin/echo', [
        'component-probe',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout, 'component-probe\n');
      expect(result.stderr, isEmpty);
    },
  );

  test(
    'maintenance command refuses oversized output with a confirmed child exit',
    () async {
      await expectLater(
        runMaintenanceCommand('/usr/bin/printf', [
          'x' * 128,
        ], maxOutputBytes: 64),
        throwsA(
          isA<MaintenanceCommandFailure>()
              .having((e) => e.exitConfirmed, 'exit confirmed', true)
              .having((e) => e.reason, 'reason', contains('output limit')),
        ),
      );
    },
  );

  test(
    'maintenance deadline terminates only its owned child and confirms exit',
    () async {
      await expectLater(
        runMaintenanceCommand('/bin/sleep', [
          '0.2',
        ], timeout: const Duration(milliseconds: 20)),
        throwsA(
          isA<MaintenanceCommandFailure>()
              .having((e) => e.exitConfirmed, 'exit confirmed', true)
              .having((e) => e.reason, 'reason', contains('deadline')),
        ),
      );
    },
  );

  test('unending maintenance output is stopped at the byte bound', () async {
    await expectLater(
      runMaintenanceCommand('/usr/bin/yes', [], maxOutputBytes: 64),
      throwsA(
        isA<MaintenanceCommandFailure>()
            .having((e) => e.exitConfirmed, 'exit confirmed', true)
            .having((e) => e.reason, 'reason', contains('output limit')),
      ),
    );
  });
}
