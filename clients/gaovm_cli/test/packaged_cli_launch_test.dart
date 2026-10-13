import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/macos_dart_signing_policy.dart';
import 'package:test/test.dart';

import '../../../daemon/gaovmd/test/helpers/owned_test_process.dart';

void main() {
  late Directory root;
  late File executable;
  final children = <OwnedTestProcess>[];

  Future<ProcessResult> run(
    String command,
    List<String> args, {
    bool isolated = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (children.any((child) => !child.exitConfirmed)) {
      throw StateError('an earlier fixture process has not exited');
    }
    final child = OwnedTestProcess(
      await Process.start(
        command,
        args,
        workingDirectory: isolated ? root.path : null,
        includeParentEnvironment: !isolated,
        environment: isolated ? const {} : null,
      ),
    );
    children.add(child);
    return child.result(timeout: timeout);
  }

  setUpAll(() async {
    final temporary = Platform.isMacOS
        ? Directory('/private/tmp')
        : Directory.systemTemp;
    root = await temporary.createTemp('gvm-pkg-cli-');
    imageFileMode(root.path, 0x1c0);
    final macos = await Directory(
      '${root.path}/Renamed GaoVM.app/Contents/MacOS',
    ).create(recursive: true);
    executable = File('${macos.path}/gaovm');
    final compiled = await run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/gaovm_cli.dart',
      '-o',
      executable.path,
    ], timeout: const Duration(minutes: 2));
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
    if (Platform.isMacOS) {
      final entitlements = await File(
        '${root.path}/dart-runtime-entitlements.plist',
      ).writeAsString(macOsDartRuntimeEntitlements);
      final signed = await run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '--options',
        'runtime',
        '--timestamp=none',
        '--entitlements',
        entitlements.path,
        executable.path,
      ]);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
    }
  });

  tearDownAll(() async {
    for (final child in children.where((child) => !child.exitConfirmed)) {
      await child.terminate();
    }
    if (children.any((child) => !child.exitConfirmed)) {
      throw StateError('retaining live executable fixture: ${root.path}');
    }
    await root.delete(recursive: true);
  });

  Future<ProcessResult> invoke(List<String> args) =>
      run(executable.path, args, isolated: true);

  test('packaged CLI does not fall back to cwd when HOME is absent', () async {
    final result = await invoke(['vm', 'list', '--json']);
    expect(result.exitCode, 2, reason: '${result.stderr}');
    expect(result.stdout, isEmpty);
    final error = jsonDecode(result.stderr as String) as Map<String, dynamic>;
    expect(error['code'], 'CLI_USAGE');
    expect(error['detail'], contains('absolute HOME or --socket-path'));
    expect(await Directory('${root.path}/state').exists(), isFalse);
  });

  test('packaged CLI help and empty invocation do not require HOME', () async {
    final help = await invoke(['--help', '--json']);
    expect(help.exitCode, 0, reason: '${help.stderr}');
    expect(help.stderr, isEmpty);
    expect(jsonDecode(help.stdout as String)['commands'], contains('vm list'));

    final empty = await invoke(['--json']);
    expect(empty.exitCode, 2, reason: '${empty.stderr}');
    final error = jsonDecode(empty.stderr as String) as Map<String, dynamic>;
    expect(error['code'], 'CLI_USAGE');
    expect(error['detail'], isNot(contains('HOME')));
  });

  test('an explicit socket reaches the public API without HOME', () async {
    var calls = 0;
    final router = PublicApiRouter()
      ..add('GET', '/v1/vms', (_) async {
        calls++;
        return PublicApiResponse.json(
          status: 200,
          body: {'items': [], 'next_cursor': null},
        );
      });
    final server = PublicApiServer(
      socketPath: '${root.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    try {
      await server.start();
      final result = await invoke([
        '--socket-path',
        server.socketPath,
        'vm',
        'list',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, isEmpty);
      expect(jsonDecode(result.stdout as String)['items'], isEmpty);
      expect(calls, 1);
    } finally {
      await server.close();
    }
  });

  test('a CLI symlink still detects its resolved app bundle', () async {
    final link = await Link(
      '${root.path}/linked-gaovm',
    ).create(executable.path);
    final result = await run(link.path, [
      'vm',
      'list',
      '--json',
    ], isolated: true);
    expect(result.exitCode, 2, reason: '${result.stderr}');
    expect(
      jsonDecode(result.stderr as String)['detail'],
      contains('absolute HOME'),
    );
  });
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
