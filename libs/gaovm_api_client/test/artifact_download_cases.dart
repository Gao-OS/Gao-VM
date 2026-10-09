part of 'client_test.dart';

void _artifactDownloadTests() {
  for (final invalid in [
    'size',
    'URL',
    'deadline',
    'budget',
    'cancelled',
    'directory',
  ]) {
    test(
      'disk artifact download rejects $invalid before HTTP or staging',
      () async {
        final output = await Directory.systemTemp.createTemp(
          'artifact-download-',
        );
        addTearDown(() => output.delete(recursive: true));
        var calls = 0;
        await _serve(
          (request) async {
            calls++;
            await _artifactReply(request);
          },
          (client) async {
            final cancellation = ApiRequestCancellation();
            if (invalid == 'cancelled') cancellation.cancel();
            await expectLater(
              client.downloadArtifact(
                _readArtifactMetadata(
                  size: invalid == 'size' ? 1025 : 22,
                  url: invalid == 'URL'
                      ? '/v1/artifacts/art_01J00000000000000000000001'
                      : null,
                ),
                directory: invalid == 'directory'
                    ? Directory('${output.path}/missing')
                    : output,
                maxBytes: invalid == 'budget' ? 0 : 1024,
                timeout: invalid == 'deadline'
                    ? Duration.zero
                    : const Duration(seconds: 30),
                cancellation: cancellation,
              ),
              throwsA(switch (invalid) {
                'size' => isA<ApiArtifactSizeLimitException>(),
                'URL' => isA<ApiProtocolException>(),
                'cancelled' => isA<ApiRequestCancelledException>(),
                'directory' => isA<FileSystemException>(),
                _ => isA<ArgumentError>(),
              }),
            );
            expect(calls, 0);
            expect(await output.list().toList(), isEmpty);
          },
        );
      },
    );
  }

  for (final invalid in [
    'length',
    'request ID',
    'digest',
    'encoding',
    'redirect',
    'malformed type',
  ]) {
    test(
      'disk artifact download cleans staging after invalid $invalid',
      () async {
        final output = await Directory.systemTemp.createTemp(
          'artifact-download-',
        );
        addTearDown(() => output.delete(recursive: true));
        var calls = 0;
        await _serve(
          (request) async {
            calls++;
            await _artifactReply(
              request,
              alter: (response) {
                switch (invalid) {
                  case 'length':
                    response.contentLength = -1;
                  case 'request ID':
                    response.headers.removeAll('X-Request-ID');
                  case 'digest':
                    response.headers.set('Digest', 'sha-256=invalid');
                  case 'encoding':
                    response.headers.set('Content-Encoding', 'gzip');
                  case 'malformed type':
                    response.headers.set('Content-Type', 'broken');
                  case 'redirect':
                    response.statusCode = 302;
                    response.headers.set('Location', '/driver.exec');
                }
              },
            );
          },
          (client) async {
            await expectLater(
              client.downloadArtifact(
                _readArtifactMetadata(),
                directory: output,
              ),
              throwsA(isA<ApiProtocolException>()),
            );
            expect(calls, 1);
            expect(await output.list().toList(), isEmpty);
          },
        );
      },
    );
  }

  test('disk artifact download accepts a verified empty file', () async {
    final output = await Directory.systemTemp.createTemp('artifact-download-');
    addTearDown(() => output.delete(recursive: true));
    const hex =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    await _serve(
      (request) async {
        _artifactHeaders(request.response, size: 0, hex: hex);
        await request.response.close();
      },
      (client) async {
        final result = await client.downloadArtifact(
          _readArtifactMetadata(size: 0, hex: hex),
          directory: output,
        );
        expect(await result.file.length(), 0);
      },
    );
  });

  test(
    'disk artifact download truncation never publishes a complete file',
    () async {
      final output = await Directory.systemTemp.createTemp(
        'artifact-download-',
      );
      addTearDown(() => output.delete(recursive: true));
      Socket? peer;
      await _serve(
        (request) async {
          _artifactHeaders(request.response);
          final socket = peer = await request.response.detachSocket(
            writeHeaders: true,
          );
          socket.add(utf8.encode(_artifactText).take(21).toList());
          await socket.flush();
          socket.destroy();
        },
        (client) async {
          try {
            await expectLater(
              client.downloadArtifact(
                _readArtifactMetadata(),
                directory: output,
              ),
              throwsA(
                anyOf(
                  isA<ApiTransportException>(),
                  isA<ApiProtocolException>(),
                ),
              ),
            );
            expect(await output.list().toList(), isEmpty);
          } finally {
            peer?.destroy();
          }
        },
      );
    },
  );

  for (final bodyStarted in [false, true]) {
    for (final cancel in [false, true]) {
      test(
        'disk artifact download ${bodyStarted ? 'body' : 'headers'} ${cancel ? 'cancel' : 'deadline'} releases its socket and staging',
        () async {
          final output = await Directory.systemTemp.createTemp(
            'artifact-download-',
          );
          addTearDown(() => output.delete(recursive: true));
          final arrived = Completer<void>(), disconnected = Completer<void>();
          final cancellation = ApiRequestCancellation();
          Socket? peer;
          await _serve(
            (request) async {
              _artifactHeaders(request.response);
              final socket = peer = await request.response.detachSocket(
                writeHeaders: bodyStarted,
              );
              void closed() {
                if (!disconnected.isCompleted) disconnected.complete();
              }

              socket.listen(
                (_) {},
                onDone: closed,
                onError: (Object _) => closed(),
              );
              if (bodyStarted) {
                socket.add(utf8.encode(_artifactText).take(5).toList());
                await socket.flush();
              }
              arrived.complete();
            },
            (client) async {
              final checked = expectLater(
                client.downloadArtifact(
                  _readArtifactMetadata(),
                  directory: output,
                  cancellation: cancellation,
                  timeout: const Duration(milliseconds: 500),
                ),
                throwsA(
                  cancel
                      ? isA<ApiRequestCancelledException>()
                      : isA<ApiTimeoutException>(),
                ),
              );
              try {
                await arrived.future.timeout(const Duration(seconds: 3));
                if (cancel) cancellation.cancel();
                await checked;
                expect(await output.list().toList(), isEmpty);
                await disconnected.future.timeout(const Duration(seconds: 3));
              } finally {
                cancellation.cancel();
                peer?.destroy();
              }
            },
          );
        },
      );
    }
  }

  test('disk artifact download progress cannot extend its whole deadline', () async {
    final output = await Directory.systemTemp.createTemp('artifact-download-');
    addTearDown(() => output.delete(recursive: true));
    final arrived = Completer<void>(), disconnected = Completer<void>();
    Timer? tick;
    Socket? peer;
    await _serve(
      (request) async {
        _artifactHeaders(request.response);
        final socket = peer = await request.response.detachSocket(
          writeHeaders: true,
        );
        void closed() {
          tick?.cancel();
          if (!disconnected.isCompleted) disconnected.complete();
        }

        socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
        unawaited(
          socket.done.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              if (error is! SocketException)
                Error.throwWithStackTrace(error, stack);
              // Socket output has its own asynchronous error channel. Handling a
              // peer-close write error must not manufacture the read-side EOF.
              tick?.cancel();
            },
          ),
        );
        tick = Timer.periodic(const Duration(milliseconds: 50), (_) {
          try {
            socket.add([71]);
          } on SocketException {
            // The reader's deadline can close its peer before this queued tick.
            // Still require the independent read-side EOF below.
            tick?.cancel();
          }
        });
        arrived.complete();
      },
      (client) async {
        final checked = expectLater(
          client.downloadArtifact(
            _readArtifactMetadata(),
            directory: output,
            timeout: const Duration(milliseconds: 300),
          ),
          throwsA(isA<ApiTimeoutException>()),
        );
        try {
          await arrived.future.timeout(const Duration(seconds: 3));
          await checked;
          expect(await output.list().toList(), isEmpty);
          await disconnected.future.timeout(const Duration(seconds: 3));
        } finally {
          tick?.cancel();
          peer?.destroy();
        }
      },
    );
  });

  test(
    'disk artifact download removes corrupt staging without touching user files',
    () async {
      final output = await Directory.systemTemp.createTemp(
        'artifact-download-',
      );
      addTearDown(() => output.delete(recursive: true));
      final marker = await File(
        '${output.path}/existing',
      ).writeAsString('keep');
      await _serve(
        (request) => _artifactReply(
          request,
          payload: utf8.encode('XaoOS artifact output\n'),
        ),
        (client) async {
          await expectLater(
            client.downloadArtifact(_readArtifactMetadata(), directory: output),
            throwsA(isA<ApiProtocolException>()),
          );
          expect(await output.list().map((entity) => entity.path).toList(), [
            marker.path,
          ]);
          expect(await marker.readAsString(), 'keep');
        },
      );
    },
  );

  test(
    'disk artifact download writes incrementally and cleans up before cancellation returns',
    () async {
      final output = await Directory.systemTemp.createTemp(
        'artifact-download-',
      );
      addTearDown(() => output.delete(recursive: true));
      final arrived = Completer<void>();
      final disconnected = Completer<void>();
      final cancellation = ApiRequestCancellation();
      Socket? peer;
      await _serve(
        (request) async {
          const hex =
              '5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee';
          _artifactHeaders(request.response, size: 2 * 1024 * 1024, hex: hex);
          final socket = peer = await request.response.detachSocket(
            writeHeaders: true,
          );
          void closed() {
            if (!disconnected.isCompleted) disconnected.complete();
          }

          socket.listen(
            (_) {},
            onDone: closed,
            onError: (Object _) => closed(),
          );
          socket.add(List<int>.filled(65536, 0));
          await socket.flush();
          arrived.complete();
        },
        (client) async {
          const hex =
              '5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee';
          final checked = expectLater(
            client.downloadArtifact(
              _readArtifactMetadata(size: 2 * 1024 * 1024, hex: hex),
              directory: output,
              cancellation: cancellation,
            ),
            throwsA(isA<ApiRequestCancelledException>()),
          );
          try {
            await arrived.future.timeout(const Duration(seconds: 3));
            final elapsed = Stopwatch()..start();
            var written = false;
            while (!written && elapsed.elapsed < const Duration(seconds: 3)) {
              for (final directory
                  in await output
                      .list()
                      .where((entity) => entity is Directory)
                      .cast<Directory>()
                      .toList()) {
                for (final file
                    in await directory
                        .list()
                        .where((entity) => entity is File)
                        .cast<File>()
                        .toList()) {
                  expect(
                    file.uri.pathSegments.last,
                    isNot(_readArtifactMetadata().id.value),
                  );
                  written |= await file.length() >= 65536;
                }
              }
              if (!written)
                await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(
              written,
              isTrue,
              reason: 'Bytes must reach disk while HTTP EOF is still withheld.',
            );
            cancellation.cancel();
            await checked;
            expect(await output.list().toList(), isEmpty);
            await disconnected.future.timeout(const Duration(seconds: 3));
          } finally {
            cancellation.cancel();
            peer?.destroy();
          }
        },
      );
    },
  );

  test(
    'disk artifact download verifies a payload larger than the preview cap',
    () async {
      const size = 2 * 1024 * 1024;
      const hex =
          '5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee';
      final artifact = _readArtifactMetadata(size: size, hex: hex);
      final output = await Directory.systemTemp.createTemp(
        'artifact-download-',
      );
      addTearDown(() => output.delete(recursive: true));
      final existing = File('${output.path}/${artifact.id.value}');
      await existing.writeAsString('existing user file');
      await _serve(
        (request) async {
          expect(request.method, 'GET');
          expect(request.uri.path, artifact.downloadUrl);
          _artifactHeaders(request.response, size: size, hex: hex);
          final chunk = List<int>.filled(8192, 0);
          for (var sent = 0; sent < size; sent += chunk.length) {
            request.response.add(chunk);
            await request.response.flush();
          }
          await request.response.close();
        },
        (client) async {
          final result = await client.downloadArtifact(
            artifact,
            directory: output,
          );
          expect(result.artifact, artifact);
          expect(result.requestId, RequestId('req_01J00000000000000000000008'));
          expect(await result.file.length(), size);
          expect(
            result.file.parent.parent.path,
            await output.resolveSymbolicLinks(),
          );
          expect((await result.file.parent.stat()).mode & 0x1ff, 0x1c0);
          expect(result.file.uri.pathSegments.last, artifact.id.value);
          final file = await result.file.open();
          try {
            expect(await file.read(32), List<int>.filled(32, 0));
            await file.setPosition(size - 32);
            expect(await file.read(32), List<int>.filled(32, 0));
          } finally {
            await file.close();
          }
          expect(await existing.readAsString(), 'existing user file');
        },
      );
    },
  );
}
