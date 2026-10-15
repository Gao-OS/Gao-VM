import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native plist decoding is read-only and uses stdin instead of a temporary file',
    () async {
      final result = await runMaintenanceCommand(
        '/usr/bin/plutil',
        ['-convert', 'json', '-o', '-', '-'],
        input: utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>test</key><true/></dict></plist>
'''),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode(result.stdout as String), {'test': true});
    },
    skip: !Platform.isMacOS,
  );

  test(
    'maintenance command supplies bounded stdin and closes it before exit',
    () async {
      final result = await runMaintenanceCommand(
        '/bin/cat',
        [],
        input: utf8.encode('plist bytes'),
      );
      expect(result.exitCode, 0);
      expect(result.stdout, 'plist bytes');
      expect(result.stderr, isEmpty);
    },
  );

  test(
    'oversized maintenance stdin is rejected before spawning a child',
    () async {
      await expectLater(
        runMaintenanceCommand(
          '/missing/never-execute',
          [],
          input: List.filled(65537, 1),
        ),
        throwsArgumentError,
      );
    },
  );

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
