import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/candidate_validation_launch.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  final nonce = 'ab' * 32;
  final executable = File(
    Platform.resolvedExecutable,
  ).resolveSymbolicLinksSync();
  List<String> childArguments(String mode) => [
    '--packages=${Directory.current.path}/.dart_tool/package_config.json',
    '${Directory.current.path}/test/fixtures/candidate_validation_launch_child.dart',
    mode,
  ];

  test(
    'owned child receives only a private stdin grant and confirms its exit',
    () async {
      final launched = await launchOwnedCandidateValidation(
        executable,
        childArguments('success'),
        nonce,
      );
      final result = launched.result;
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, isEmpty);
      final record = jsonDecode(result.stdout as String) as Map;
      expect(record['pid'], result.pid);
      expect(record['grant_digest'], launched.grant.digest);
      expect(record['environment_keys'], contains('PATH'));
      // CoreFoundation may synthesize this key after exec on macOS. It is not
      // evidence of inheriting HOME, credentials or the parent environment.
      expect(
        (record['environment_keys'] as List).every(
          (key) => {'PATH', '__CF_USER_TEXT_ENCODING'}.contains(key),
        ),
        true,
      );
      expect(record['arguments'], ['success']);
      expect(result.stdout, isNot(contains(nonce)));
      expect(launched.grant.process.pid, result.pid);
      expect(launched.grant.process.pidVersion, isNotNull);
      expect(
        await MacOsDriverInventory(
          executablePath: executable,
        ).inspectForMaintenance(result.pid),
        isNull,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'missing native identity closes stdin and waits for the original exit',
    () async {
      int? observedPid;
      await expectLater(
        launchOwnedCandidateValidation(
          executable,
          childArguments('success'),
          nonce,
          inspect: (ownedPid) async {
            observedPid = ownedPid;
            return null;
          },
        ),
        throwsA(
          isA<MaintenanceCommandFailure>()
              .having((failure) => failure.exitConfirmed, 'original exit', true)
              .having((failure) => failure.pid, 'owned PID', isPositive),
        ),
      );
      expect(observedPid, isNotNull);
      expect(
        await MacOsDriverInventory(
          executablePath: executable,
        ).inspectForMaintenance(observedPid!),
        isNull,
      );
    },
    skip: !Platform.isMacOS,
  );

  for (final mode in ['stderr-overflow', 'invalid-utf8']) {
    test(
      'bounded output failure $mode retains a confirmed original exit',
      () async {
        await expectLater(
          launchOwnedCandidateValidation(
            executable,
            childArguments(mode),
            nonce,
          ),
          throwsA(
            isA<MaintenanceCommandFailure>()
                .having(
                  (failure) => failure.exitConfirmed,
                  'original exit',
                  true,
                )
                .having(
                  (failure) => failure.ownedExit,
                  'no abandoned future',
                  isNull,
                ),
          ),
        );
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'invalid launch entropy refuses before attempting to start a child',
    () async {
      await expectLater(
        launchOwnedCandidateValidation('/missing/never-execute', [], 'short'),
        throwsFormatException,
      );
    },
  );

  final grant = ValidationLaunchGrant(
    nonce: nonce,
    process: const DriverProcessIdentity(
      pid: 123,
      uid: 501,
      executablePath: '/private/candidate/gaovmd',
      startedAtMicroseconds: 123456,
      pidVersion: 17,
    ),
  );
  test(
    'private grant parsing preserves every versioned process binding',
    () async {
      final parsed = await readValidationLaunchGrant(
        Stream.fromIterable(
          utf8.encode(jsonEncode(grant.toJson())).map((byte) => [byte]),
        ),
      );
      expect(parsed.digest, grant.digest);
      parsed.verifyProcess(grant.processJson);
      for (final field in grant.processJson.keys) {
        expect(
          () => parsed.verifyProcess({...grant.processJson, field: null}),
          throwsFormatException,
        );
      }
    },
  );
  for (final malformed in [
    '',
    nonce,
    'not-json-$nonce',
    ' ' * 8193,
    jsonEncode({...grant.toJson(), 'extra': true}),
    jsonEncode({
      ...grant.toJson(),
      'process': {...grant.processJson, 'pid_version': -1},
    }),
  ]) {
    test(
      'private grant refuses malformed bounded input without echoing it: ${malformed.length}',
      () async {
        await expectLater(
          readValidationLaunchGrant(Stream.value(utf8.encode(malformed))),
          throwsA(
            isA<FormatException>()
                .having(
                  (error) => error.message,
                  'redacted reason',
                  'invalid private validation launch grant',
                )
                .having((error) => error.source, 'redacted source', isNull),
          ),
        );
      },
    );
  }

  test(
    'sealed recovery is narrowed to this grant, preflight and exact stdout',
    () {
      final publication = <String, Object?>{'candidate': 'original'};
      final record = <String, Object?>{'result': 'original'};
      final intent = <String, Object?>{
        'format': 'gaovm.candidate-validation-intent.v3',
        'launch_grant_digest': grant.digest,
        'preparation_digest': 'original-preparation',
        'publication': {...publication, 'executing_process': grant.processJson},
      };
      final expected = ValidationLaunchExpectation(
        grant: grant,
        preparationDigest: 'original-preparation',
        publication: publication,
        record: record,
      );
      expected.verify(intent, record);
      for (final changed in [
        {...intent, 'format': 'gaovm.candidate-validation-intent.v2'},
        {...intent, 'launch_grant_digest': null},
        {...intent, 'launch_grant_digest': 'other-launch'},
        {...intent, 'preparation_digest': 'other-preparation'},
        {
          ...intent,
          'publication': {
            ...publication,
            'executing_process': {...grant.processJson, 'pid_version': 18},
          },
        },
        {
          ...intent,
          'publication': {
            'candidate': 'substituted',
            'executing_process': grant.processJson,
          },
        },
      ]) {
        expect(() => expected.verify(changed, record), throwsFormatException);
      }
      expect(
        () => expected.verify(intent, {'result': 'substituted'}),
        throwsFormatException,
      );
    },
  );
}
