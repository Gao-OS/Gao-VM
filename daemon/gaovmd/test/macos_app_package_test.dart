import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/public_openapi_document.dart';
import 'package:test/test.dart';

void main() {
  group('macOS app packaging', () {
    late Directory inputs;
    late Directory output;
    late File armExecutable;
    late File intelExecutable;

    setUpAll(() async {
      inputs = await Directory.systemTemp.createTemp('gvm-package-input-');
      imageFileMode(inputs.path, 0x1c0);
      for (final architecture in ['arm64', 'x86_64']) {
        final result = await Process.run('/usr/bin/xcrun', [
          'clang',
          '-target',
          '$architecture-apple-macos14.0',
          'test/fixtures/package_fixture.c',
          '-o',
          '${inputs.path}/$architecture',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      armExecutable = File('${inputs.path}/arm64');
      intelExecutable = File('${inputs.path}/x86_64');
    });

    tearDownAll(() async {
      await inputs.delete(recursive: true);
    });

    setUp(() async {
      output = await Directory.systemTemp.createTemp('gvm-package-output-');
      imageFileMode(output.path, 0x1c0);
    });

    tearDown(() async {
      await output.delete(recursive: true);
    });

    Future<ProcessResult> package({
      File? daemon,
      String version = '0.1.0',
      String identifier = 'org.gaovm.tests.Package',
      String identity = '-',
      File? entitlements,
      Directory? schemaDirectory,
      Directory? outputDirectory,
    }) => Process.run(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      'tool/package_macos.dart',
      '--daemon',
      (daemon ?? armExecutable).path,
      '--cli',
      armExecutable.path,
      '--driver',
      armExecutable.path,
      '--schemas',
      (schemaDirectory ?? Directory('../../schemas')).path,
      '--driver-entitlements',
      (entitlements ??
              File('../../drivers/vz_macos/Resources/entitlements.plist'))
          .path,
      '--output-dir',
      (outputDirectory ?? output).path,
      '--bundle-id',
      identifier,
      '--version',
      version,
      '--sign',
      identity,
    ]);

    test('rejects Intel inputs without publishing a target app', () async {
      final result = await package(daemon: intelExecutable);
      expect(result.exitCode, 2, reason: '${result.stderr}');
      expect(result.stderr, contains('arm64 Mach-O executable'));
      expect(
        await FileSystemEntity.type(
          '${output.path}/GaoVM.app',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    });

    test(
      'publishes a signed self-contained app without changing inputs',
      () async {
        final original = sha256.convert(await armExecutable.readAsBytes());
        final result = await package();
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final bundle = Directory((result.stdout as String).trim());
        expect(bundle.path, '${await output.resolveSymbolicLinks()}/GaoVM.app');
        final plist = await Process.run('/usr/bin/plutil', [
          '-convert',
          'json',
          '-o',
          '-',
          '${bundle.path}/Contents/Info.plist',
        ]);
        expect(plist.exitCode, 0, reason: '${plist.stderr}');
        final info = jsonDecode(plist.stdout as String) as Map<String, dynamic>;
        expect(info['CFBundleIdentifier'], 'org.gaovm.tests.Package');
        expect(info['CFBundleExecutable'], 'gaovmd');
        expect(info['CFBundleShortVersionString'], '0.1.0');
        expect(info['CFBundleVersion'], '0.1.0');
        expect(info['LSMinimumSystemVersion'], '14.0');
        expect(info['LSBackgroundOnly'], isTrue);
        for (final path in [
          'MacOS/gaovmd',
          'MacOS/gaovm',
          'Helpers/gaovm-driver-vz',
        ]) {
          final verification = await Process.run('/usr/bin/codesign', [
            '--verify',
            '--strict',
            '${bundle.path}/Contents/$path',
          ]);
          expect(verification.exitCode, 0, reason: '${verification.stderr}');
        }
        final verification = await Process.run('/usr/bin/codesign', [
          '--verify',
          '--deep',
          '--strict',
          bundle.path,
        ]);
        expect(verification.exitCode, 0, reason: '${verification.stderr}');
        final entitlements = await Process.run('/usr/bin/codesign', [
          '--display',
          '--entitlements',
          ':-',
          '${bundle.path}/Contents/Helpers/gaovm-driver-vz',
        ]);
        expect(entitlements.exitCode, 0, reason: '${entitlements.stderr}');
        expect(
          entitlements.stdout,
          matches(
            RegExp(
              r'<key>com\.apple\.security\.virtualization</key>\s*<true\s*/>',
            ),
          ),
        );
        final document = await loadPublicOpenApiDocument(
          File(
            '${bundle.path}/Contents/Resources/schemas/openapi/gaovm-v1.yaml',
          ),
        );
        expect(document['openapi'], '3.1.0');
        expect(sha256.convert(await armExecutable.readAsBytes()), original);
      },
    );

    test('rejects invalid bundle metadata before creating staging', () async {
      for (final result in [
        await package(version: '0.1.0-beta'),
        await package(version: '01.2.3'),
        await package(identifier: 'org/gaovm/Package'),
        await package(identifier: 'org..Package'),
      ]) {
        expect(result.exitCode, 2, reason: '${result.stderr}');
      }
      expect(await output.list().toList(), isEmpty);
    });

    test(
      'does not overwrite an existing app or create staging beside it',
      () async {
        final existing = await Directory('${output.path}/GaoVM.app').create();
        final marker = await File(
          '${existing.path}/owner',
        ).writeAsString('preserve');
        final result = await package();
        expect(result.exitCode, 1, reason: '${result.stderr}');
        expect(result.stderr, contains('output app already exists'));
        expect(await marker.readAsString(), 'preserve');
        expect(
          (await output.list().toList()).where(
            (entry) => entry.path.contains('.gaovm-package-'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'signing failure retains private staging but publishes no app',
      () async {
        final original = sha256.convert(await armExecutable.readAsBytes());
        final result = await package(
          identity: 'GaoVM fixture missing certificate',
        );
        expect(result.exitCode, 1, reason: '${result.stderr}');
        expect(result.stderr, contains('codesign'));
        expect(await Directory('${output.path}/GaoVM.app').exists(), isFalse);
        final retained = (await output.list().toList())
            .whereType<Directory>()
            .where((entry) => entry.path.contains('.gaovm-package-'));
        expect(retained, hasLength(1));
        expect((await retained.single.stat()).mode & 0x3f, 0);
        expect(sha256.convert(await armExecutable.readAsBytes()), original);
      },
    );

    test('requires an actual enabled virtualization entitlement', () async {
      final entitlements = await File(
        '${output.path}/invalid-entitlements.plist',
      ).writeAsString('{"com.apple.security.virtualization":false}');
      final result = await package(entitlements: entitlements);
      expect(result.exitCode, 2, reason: '${result.stderr}');
      expect(result.stderr, contains('driver entitlement must enable'));
      expect(await Directory('${output.path}/GaoVM.app').exists(), isFalse);
    });

    test(
      'rejects linked schema entries instead of copying outside content',
      () async {
        final schemaDirectory = await Directory(
          '${output.path}/linked-schemas',
        ).create();
        await Link(
          '${schemaDirectory.path}/outside',
        ).create(armExecutable.path);
        final result = await package(schemaDirectory: schemaDirectory);
        expect(result.exitCode, 2, reason: '${result.stderr}');
        expect(result.stderr, contains('link or special file'));
        expect(await Directory('${output.path}/GaoVM.app').exists(), isFalse);
      },
    );

    test(
      'rejects a linked output root without writing to its target',
      () async {
        final linked = Link('${output.path}/linked-output');
        await linked.create(inputs.path);
        final before = (await inputs.list().toList())
            .map((entry) => entry.path)
            .toSet();
        final result = await package(outputDirectory: Directory(linked.path));
        expect(result.exitCode, 2, reason: '${result.stderr}');
        expect(result.stderr, contains('output must be a regular directory'));
        expect(
          (await inputs.list().toList()).map((entry) => entry.path).toSet(),
          before,
        );
      },
    );
  }, skip: !Platform.isMacOS);
}
