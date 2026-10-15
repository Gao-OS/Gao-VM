import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  Future<ProcessResult> run(List<String> arguments) async {
    final root = await Directory.systemTemp.createTemp('gvm-cold-tool-');
    OwnedTestProcess? child;
    try {
      child = OwnedTestProcess(
        await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/tool/maintain_macos.dart',
            ...arguments,
          ],
          workingDirectory: root.path,
          includeParentEnvironment: false,
          environment: const {},
        ),
      );
      final result = await child.result();
      expect(await root.list().toList(), isEmpty);
      return result;
    } finally {
      if (child != null && !await child.terminate()) {
        throw StateError('retaining live maintenance fixture: ${root.path}');
      }
      await root.delete(recursive: true);
    }
  }

  test('cold maintenance help needs no HOME or installed service', () async {
    final result = await run(['--help']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('publish-upgrade'));
    expect(result.stdout, contains('resume-publication'));
    expect(result.stdout, contains('uninstall-app'));
    expect(result.stdout, contains('resume-uninstall'));
    expect(result.stdout, contains('does not activate'));
    expect(result.stderr, isEmpty);
  });

  const publish = [
    'publish-upgrade',
    '--app',
    '/missing/GaoVM.app',
    '--state-dir',
    '/missing/state',
    '--candidate-app',
    '/missing/Candidate.app',
    '--work-dir',
    '/missing/work',
    '--inspection-dir',
    '/missing/inspection',
    '--bundle-id',
    'org.gaovm.tests.Release',
    '--old-version',
    '0.1.0',
    '--new-version',
    '0.1.0',
    '--team-id',
    'ABCDEFGHIJ',
  ];
  final resume = [...publish]..removeRange(5, 7);
  resume[0] = 'resume-publication';
  resume.addAll(['--from', 'publication', '--catalog-schema', '21']);
  for (final invalid in [
    <String>[],
    ['upgrade'],
    ['publish-upgrade', '--app'],
    [...publish, '--app', '/other/GaoVM.app'],
    [...publish, '--allow-unsafe', 'true'],
    [...publish]..[publish.indexOf('--new-version') + 1] = '01.0.0',
    [...publish]..[publish.indexOf('--team-id') + 1] = 'not-a-team',
    [...publish]..[publish.indexOf('--bundle-id') + 1] = 'not a bundle',
    [...resume]..[resume.indexOf('--from') + 1] = 'automatic',
    [...resume]..[resume.indexOf('--catalog-schema') + 1] = '021',
    [...resume]..[resume.indexOf('--catalog-schema') + 1] = '2147483648',
    [...resume]..[resume.indexOf('--catalog-schema') + 1] = '-1',
  ]) {
    test(
      'malformed cold command fails before inspecting any path: $invalid',
      () async {
        final result = await run(invalid);
        expect(
          result.exitCode,
          2,
          reason: '${result.stderr}\n${result.stdout}',
        );
        expect(result.stderr, isEmpty);
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['status'], 'refused');
        expect(report['stage'], 'inputs');
        expect(report['activation_authorized'], false);
        expect(report['rollback_authorized'], false);
        expect(report['committed'], false);
      },
    );
  }

  const uninstall = [
    'uninstall-app',
    '--app',
    '/missing/GaoVM.app',
    '--state-dir',
    '/missing/state',
    '--work-dir',
    '/missing/work',
    '--inspection-dir',
    '/missing/inspection',
    '--bundle-id',
    'org.gaovm.tests.Release',
    '--version',
    '0.1.0',
    '--team-id',
    'ABCDEFGHIJ',
  ];
  final resumeUninstall = [...uninstall];
  resumeUninstall[0] = 'resume-uninstall';
  resumeUninstall.addAll(['--from', 'retirement', '--catalog-schema', '21']);
  for (final invalid in [
    ['uninstall-app', '--app'],
    [...uninstall, '--app', '/other/GaoVM.app'],
    [...uninstall, '--candidate-app', '/other/Candidate.app'],
    [...uninstall, '--allow-unsafe', 'true'],
    [...uninstall]..[uninstall.indexOf('--version') + 1] = '01.0.0',
    [...uninstall]..[uninstall.indexOf('--team-id') + 1] = 'not-a-team',
    [...uninstall]..[uninstall.indexOf('--bundle-id') + 1] = 'not a bundle',
    [...resumeUninstall]
      ..[resumeUninstall.indexOf('--from') + 1] = 'publication',
    [...resumeUninstall]
      ..[resumeUninstall.indexOf('--catalog-schema') + 1] = '021',
    [...resumeUninstall]
      ..[resumeUninstall.indexOf('--catalog-schema') + 1] = '2147483648',
    [...resumeUninstall]
      ..[resumeUninstall.indexOf('--catalog-schema') + 1] = '-1',
  ]) {
    test(
      'malformed uninstall fails before any path inspection: $invalid',
      () async {
        final result = await run(invalid);
        expect(
          result.exitCode,
          2,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stderr, isEmpty);
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['format'], 'gaovm.cold-uninstall-command.v1');
        expect(report['status'], 'refused');
        expect(report['stage'], 'inputs');
        expect(report['activation_authorized'], false);
        expect(report['rollback_authorized'], false);
        expect(report['committed'], false);
      },
    );
  }

  for (final action in ['publish-upgrade', 'uninstall-app']) {
    test(
      'real $action operator entry refuses unsigned app before state ownership or candidate execution',
      () async {
        final created = await Directory.systemTemp.createTemp(
          'gvm-cold-unsigned-',
        );
        final fixture = Directory(await created.resolveSymbolicLinks());
        var confirmed = false;
        try {
          final paths = <String, String>{};
          for (final name in [
            'GaoVM.app',
            'Candidate.app',
            'state',
            'work',
            'inspection',
          ]) {
            final directory = await Directory('${fixture.path}/$name').create();
            imageFileMode(directory.path, 0x1c0);
            paths[name] = directory.path;
          }
          for (final path in [
            'Contents/MacOS/gaovmd',
            'Contents/MacOS/gaovm',
            'Contents/MacOS/gaovm-service',
            'Contents/Helpers/gaovm-driver-vz',
            'Contents/Info.plist',
            'Contents/Library/LaunchAgents/gaovmd.plist',
            'Contents/Resources/dart-runtime-entitlements.plist',
            'Contents/Resources/driver-entitlements.plist',
            'Contents/Resources/schemas/openapi/gaovm-v1.yaml',
            'Contents/Resources/schemas/vm-spec/v1alpha1.schema.json',
            'Contents/Resources/schemas/driver-protocol/v2.schema.json',
          ]) {
            final file = File('${paths['GaoVM.app']}/$path');
            await file.parent.create(recursive: true);
            await file.writeAsString('unsigned; must never execute');
            imageFileMode(file.path, 0x180);
          }
          final result = await run([
            action,
            '--app',
            paths['GaoVM.app']!,
            '--state-dir',
            paths['state']!,
            if (action == 'publish-upgrade') ...[
              '--candidate-app',
              paths['Candidate.app']!,
            ],
            '--work-dir',
            paths['work']!,
            '--inspection-dir',
            paths['inspection']!,
            '--bundle-id',
            'org.gaovm.tests.Release',
            action == 'publish-upgrade' ? '--old-version' : '--version',
            '0.1.0',
            if (action == 'publish-upgrade') ...['--new-version', '0.1.1'],
            '--team-id',
            'ABCDEFGHIJ',
          ]);
          confirmed = true;
          expect(
            result.exitCode,
            2,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stderr, isEmpty);
          final report = jsonDecode(result.stdout as String) as Map;
          expect(report['stage'], 'cold');
          expect(report['status'], 'refused');
          expect(report['reason'], contains('codesign'));
          for (final name in ['state', 'inspection', 'Candidate.app']) {
            expect(await Directory(paths[name]!).list().toList(), isEmpty);
          }
          expect(
            await Directory(
              paths['work']!,
            ).list().map((entry) => entry.uri.pathSegments.last).toList(),
            [
              action == 'publish-upgrade'
                  ? '.gaovm-cold-publication.lock'
                  : '.gaovm-cold-uninstall.lock',
            ],
          );
        } finally {
          if (!confirmed)
            throw StateError(
              'retaining unsigned maintenance inputs: ${fixture.path}',
            );
          await fixture.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );
  }
}
