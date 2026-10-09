part of 'client_test.dart';

void _artifactTests() {
  test('an empty artifact is a complete verified payload', () async {
    const hex =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    await _serve(
      (request) async {
        _artifactHeaders(request.response, size: 0, hex: hex);
        await request.response.close();
      },
      (client) async {
        final result = await client.readArtifact(
          _readArtifactMetadata(size: 0, hex: hex),
        );
        expect(result.bytes, isEmpty);
        expect(result.requestId, RequestId('req_01J00000000000000000000008'));
      },
    );
  });

  for (final bodyStarted in [false, true]) {
    for (final cancel in [false, true]) {
      test(
        'artifact ${bodyStarted ? 'body' : 'headers'} ${cancel ? 'cancel' : 'deadline'} releases the actual socket',
        () async {
          final arrived = Completer<void>();
          final disconnected = Completer<void>();
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
                client.readArtifact(
                  _readArtifactMetadata(),
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
                // Observe peer EOF before any fixture cleanup can produce it.
                await disconnected.future.timeout(const Duration(seconds: 3));
              } finally {
                peer?.destroy();
              }
            },
          );
        },
      );
    }
  }

  test('artifact truncation never returns partial verified bytes', () async {
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
            client.readArtifact(_readArtifactMetadata()),
            throwsA(
              anyOf(isA<ApiTransportException>(), isA<ApiProtocolException>()),
            ),
          );
        } finally {
          peer?.destroy();
        }
      },
    );
  });

  for (final invalid in [
    'status',
    'type',
    'missing length',
    'missing request ID',
    'invalid request ID',
    'repeated request ID',
    'missing digest',
    'digest',
  ]) {
    test('artifact reads reject $invalid before accepting a payload', () async {
      await _serve(
        (request) async {
          await _artifactReply(
            request,
            alter: (response) {
              switch (invalid) {
                case 'status':
                  response.statusCode = 206;
                case 'type':
                  response.headers.contentType = ContentType.json;
                case 'missing length':
                  response.contentLength = -1;
                case 'missing request ID':
                  response.headers.removeAll('X-Request-ID');
                case 'invalid request ID':
                  response.headers.set('X-Request-ID', 'untyped');
                case 'repeated request ID':
                  response.headers.add(
                    'X-Request-ID',
                    'req_01J00000000000000000000009',
                  );
                case 'missing digest':
                  response.headers.removeAll('Digest');
                case 'digest':
                  response.headers.set('Digest', 'sha-256=incorrect');
              }
            },
          );
        },
        (client) async {
          await expectLater(
            client.readArtifact(_readArtifactMetadata()),
            throwsA(isA<ApiProtocolException>()),
          );
        },
      );
    });
  }

  test(
    'artifact reads reject length disagreement with catalog metadata',
    () async {
      await _serve(_artifactReply, (client) async {
        await expectLater(
          client.readArtifact(_readArtifactMetadata(size: 21)),
          throwsA(isA<ApiProtocolException>()),
        );
      });
    },
  );

  for (final invalid in ['size', 'URL', 'deadline', 'budget', 'cancelled']) {
    test(
      'artifact $invalid admission does not open a public request',
      () async {
        var calls = 0;
        await _serve(
          (request) async {
            calls++;
            await _artifactReply(request);
          },
          (client) async {
            final cancellation = ApiRequestCancellation();
            if (invalid == 'cancelled') cancellation.cancel();
            final read = client.readArtifact(
              _readArtifactMetadata(
                size: invalid == 'size' ? 65537 : 22,
                url: invalid == 'URL'
                    ? '/v1/artifacts/art_01J00000000000000000000001'
                    : null,
              ),
              cancellation: cancellation,
              maxBytes: invalid == 'budget' ? 0 : 65536,
              timeout: invalid == 'deadline'
                  ? Duration.zero
                  : const Duration(seconds: 30),
            );
            await expectLater(
              read,
              throwsA(switch (invalid) {
                'size' => isA<ApiArtifactSizeLimitException>(),
                'URL' => isA<ApiProtocolException>(),
                'cancelled' => isA<ApiRequestCancelledException>(),
                _ => isA<ArgumentError>(),
              }),
            );
            expect(calls, 0);
          },
        );
      },
    );
  }

  test('artifact redirects do not fetch another route', () async {
    var calls = 0;
    await _serve(
      (request) async {
        calls++;
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/driver.exec');
        await request.response.close();
      },
      (client) async {
        await expectLater(
          client.readArtifact(_readArtifactMetadata()),
          throwsA(isA<ApiProtocolException>()),
        );
        expect(calls, 1);
      },
    );
  });

  for (final status in [404, 500]) {
    test('artifact $status retains the structured public problem', () async {
      final problem = Problem(
        type: Uri.parse('https://gaovm.dev/problems/artifact-unavailable'),
        title: 'Artifact unavailable',
        status: status,
        code: status == 404
            ? ErrorCode.artifactNotFound
            : ErrorCode.internalError,
        detail: 'No verified artifact is available.',
        requestId: RequestId('req_01J00000000000000000000009'),
        operationId: OperationId('op_01J00000000000000000000005'),
        retryable: false,
        details: JsonObjectValue.empty,
      );
      await _serve(
        (request) async {
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType(
            'application',
            'problem+json',
          );
          request.response.write(jsonEncode(problem.toJson()));
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.readArtifact(_readArtifactMetadata()),
            throwsA(
              isA<ApiProblemException>().having(
                (error) => error.problem,
                'problem',
                problem,
              ),
            ),
          );
        },
      );
    });
  }

  test(
    'artifact bytes are rejected when only their contents have changed',
    () async {
      await _serve(
        (request) async {
          await _artifactReply(
            request,
            payload: utf8.encode('XaoOS artifact output\n'),
          );
        },
        (client) async {
          await expectLater(
            client.readArtifact(_readArtifactMetadata()),
            throwsA(
              isA<ApiProtocolException>().having(
                (error) => error.message,
                'message',
                contains('SHA-256'),
              ),
            ),
          );
        },
      );
    },
  );

  test(
    'artifact reads reject an encoded representation of raw bytes',
    () async {
      await _serve(
        (request) async {
          request.response.headers.set('Content-Encoding', 'gzip');
          await _artifactReply(request);
        },
        (client) async {
          await expectLater(
            client.readArtifact(_readArtifactMetadata()),
            throwsA(isA<ApiProtocolException>()),
          );
        },
      );
    },
  );

  test(
    'artifact read verifies public bytes, length, digest and request ID',
    () async {
      final artifact = _readArtifactMetadata();
      await _serve(
        (request) async {
          expect(request.method, 'GET');
          expect(request.uri.path, artifact.downloadUrl);
          expect(
            request.headers.value('Accept'),
            contains('application/octet-stream'),
          );
          await _artifactReply(request);
        },
        (client) async {
          final result = await client.readArtifact(artifact);
          expect(result.artifact, artifact);
          expect(utf8.decode(result.bytes), _artifactText);
          expect(result.requestId, RequestId('req_01J00000000000000000000008'));
          expect(() => result.bytes[0] = 0, throwsUnsupportedError);
          expect(
            () => result.bytes.buffer.asUint8List()[0] = 0,
            throwsUnsupportedError,
          );
        },
      );
    },
  );
}

const _artifactText = 'GaoOS artifact output\n';
const _artifactHex =
    'e9727bb930785755a576b86607683d312501e2dee6d360136f52b4ab71ecef51';

Artifact _readArtifactMetadata({
  int size = 22,
  String? url,
  String hex = _artifactHex,
}) => Artifact(
  id: ArtifactId('art_01J00000000000000000000000'),
  testRunId: TestRunId('tr_01J00000000000000000000006'),
  kind: ArtifactKind.stdout,
  contentType: 'text/plain; charset=utf-8',
  sizeBytes: size,
  digest: 'sha256:$hex',
  downloadUrl: url ?? '/v1/artifacts/art_01J00000000000000000000000',
  createdAt: DateTime.utc(2026, 9, 4),
);

Future<void> _artifactReply(
  HttpRequest request, {
  List<int>? payload,
  void Function(HttpResponse)? alter,
}) async {
  _artifactHeaders(request.response);
  alter?.call(request.response);
  request.response.add(payload ?? utf8.encode(_artifactText));
  await request.response.close();
}

void _artifactHeaders(
  HttpResponse response, {
  int size = 22,
  String hex = _artifactHex,
}) {
  response.headers.contentType = ContentType('application', 'octet-stream');
  response.headers.contentLength = size;
  response.headers.set('X-Request-ID', 'req_01J00000000000000000000008');
  final digest = List<int>.generate(
    32,
    (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
  );
  response.headers.set('Digest', 'sha-256=${base64.encode(digest)}');
}
