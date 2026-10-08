import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'installed daemon serves the VM catalog over HTTP UDS',
    () async {
      final state = await Directory('/private/tmp').createTemp('gvm-app-');
      addTearDown(() => state.delete(recursive: true));
      final daemon = await _Daemon.start(state, '/bin/cat');
      try {
        final response = await daemon.get('/v1/vms');
        expect(response.$1, HttpStatus.ok);
        expect(response.$2['items'], isEmpty);
        final images = await daemon.get('/v1/images');
        expect(images.$1, HttpStatus.ok);
        expect(images.$2['items'], isEmpty);
        final health = await daemon.get('/v1/system/live');
        expect(health.$1, HttpStatus.ok);
      } finally {
        await daemon.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a second daemon cannot mutate an owned state directory',
    () async {
      final temporary = await Directory(
        '/private/tmp',
      ).createTemp('gvm-owner-');
      final state = await OwnedImageDirectory.open(temporary);
      final owner = (await DaemonOwnership.tryAcquire(state))!;
      try {
        await expectLater(
          DaemonApplication.start(
            stateDirectory: temporary,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          ),
          throwsStateError,
        );
        expect(await File('${state.path}/gaovm.db').exists(), isFalse);
        expect(await Directory('${state.path}/run').exists(), isFalse);
        await owner.verify();
      } finally {
        owner.close();
        state.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'linked catalogs are rejected without touching their target',
    () async {
      final temporary = await Directory('/private/tmp').createTemp('gvm-link-');
      final outside = await File(
        '${temporary.path}/outside',
      ).writeAsString('preserve');
      await Link('${temporary.path}/gaovm.db').create(outside.path);
      try {
        await expectLater(
          DaemonApplication.start(
            stateDirectory: temporary,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await outside.readAsString(), 'preserve');
        final state = await OwnedImageDirectory.open(temporary);
        final owner = (await DaemonOwnership.tryAcquire(state))!;
        owner.close();
        state.close();
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'linked artifact stores are rejected without touching their target',
    () async {
      final temporary = await Directory(
        '/private/tmp',
      ).createTemp('gvm-art-link-');
      final state = await Directory('${temporary.path}/state').create();
      imageFileMode(state.path, 0x1c0);
      final outside = await Directory('${temporary.path}/outside').create();
      final proof = await File(
        '${outside.path}/proof',
      ).writeAsString('preserve');
      await Link('${state.path}/artifacts').create(outside.path);
      DaemonApplication? daemon;
      try {
        await expectLater(() async {
          daemon = await DaemonApplication.start(
            stateDirectory: state,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          );
        }(), throwsA(isA<FileSystemException>()));
        expect(await proof.readAsString(), 'preserve');
        final held = await OwnedImageDirectory.open(state);
        final owner = (await DaemonOwnership.tryAcquire(held))!;
        owner.close();
        held.close();
      } finally {
        await daemon?.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}

final class _Daemon {
  _Daemon(this.process, this.client, this.output, this.errors);
  final Process process;
  final HttpClient client;
  final StreamSubscription<String> output;
  final Future<void> errors;

  static Future<_Daemon> start(Directory state, String driver) async {
    final socket = '${state.path}/run/api.sock';
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/bin/gaovmd.dart',
      '--state-dir',
      state.path,
      '--socket-path',
      socket,
      '--driver-bin',
      driver,
    ]);
    final ready = Completer<void>();
    final diagnostics = StringBuffer();
    final errors = process.stderr.transform(utf8.decoder).forEach((chunk) {
      if (diagnostics.length < 8192) diagnostics.write(chunk);
    });
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('gaovmd listening on unix:') &&
                !ready.isCompleted) {
              ready.complete();
            }
          },
          onDone: () {
            errors.then((_) {
              if (!ready.isCompleted)
                ready.completeError(
                  StateError('daemon exited before listening: $diagnostics'),
                );
            });
          },
        );
    final client = HttpClient()
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(socket, type: InternetAddressType.unix),
        0,
      );
    final daemon = _Daemon(process, client, output, errors);
    try {
      await ready.future.timeout(const Duration(seconds: 10));
      return daemon;
    } catch (_) {
      await daemon.close();
      rethrow;
    }
  }

  Future<(int, Map<String, Object?>)> get(String path) async {
    final request = await client.getUrl(Uri.parse('http://localhost$path'));
    final response = await request.close().timeout(const Duration(seconds: 3));
    final decoded = jsonDecode(await response.transform(utf8.decoder).join());
    return (response.statusCode, Map<String, Object?>.from(decoded as Map));
  }

  Future<void> close() async {
    client.close(force: true);
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await output.cancel();
    await errors;
  }
}
