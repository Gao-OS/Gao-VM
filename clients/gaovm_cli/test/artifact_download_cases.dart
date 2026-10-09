part of 'public_api_cli_test.dart';

const _downloadOwner = 'tr_01J00000000000000000000006';
const _downloadId = 'art_01J00000000000000000000000';
const _downloadHex =
    'e9727bb930785755a576b86607683d312501e2dee6d360136f52b4ab71ecef51';

Artifact _downloadMetadata() => Artifact(
  id: ArtifactId(_downloadId),
  testRunId: TestRunId(_downloadOwner),
  kind: ArtifactKind.stdout,
  contentType: 'text/plain; charset=utf-8',
  sizeBytes: 22,
  digest: 'sha256:$_downloadHex',
  downloadUrl: '/v1/artifacts/$_downloadId',
  createdAt: DateTime.utc(2026, 10, 10),
);

Map<String, String> _downloadHeaders() => {
  'Content-Length': '22',
  'Digest':
      'sha-256=${base64.encode(List.generate(32, (index) => int.parse(_downloadHex.substring(index * 2, index * 2 + 2), radix: 16)))}',
};

List<String> _downloadArgs(Directory output) => [
  'test',
  'download',
  _downloadOwner,
  _downloadId,
  '--output-dir',
  output.path,
];

void _artifactDownloadCliTests() {
  test(
    'artifact download shares one deadline across metadata and streamed bytes',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      final cancelled = Completer<void>();
      var stalling = false;
      var started = false;
      var byteRequests = 0;
      late StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onListen: () {
          started = true;
          body.add(utf8.encode('GaoOS'));
        },
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      addTearDown(() async {
        // A failure before byte streaming must not leave an unconsumed
        // single-subscription controller whose close future cannot finish.
        if (!started) {
          final subscription = body.stream.listen((_) {});
          await body.close();
          await subscription.cancel();
        } else {
          await body.close();
        }
      });
      final router = PublicApiRouter()
        ..add('GET', '/v1/test-runs/{test_run_id}/artifacts', (_) async {
          if (stalling)
            await Future<void>.delayed(const Duration(milliseconds: 600));
          return PublicApiResponse.json(
            status: 200,
            body: {
              'items': [_downloadMetadata().toJson()],
              'next_cursor': null,
            },
          );
        })
        ..add('GET', '/v1/artifacts/{artifact_id}', (_) async {
          if (stalling) byteRequests++;
          return PublicApiResponse.stream(
            body: stalling
                ? body.stream
                : Stream.value(utf8.encode('GaoOS artifact output\n')),
            contentType: ContentType('application', 'octet-stream'),
            headers: _downloadHeaders(),
          );
        });
      await _withServer(router, (server) async {
        // Warm the real JIT/HTTP/file path before measuring a deliberately
        // short budget. The timed run must still enter the byte phase and EOF.
        final warmup = await _invoke(server, _downloadArgs(output));
        expect(warmup.code, 0, reason: warmup.error);
        final completed = File(
          jsonDecode(warmup.output)['output_path'] as String,
        );
        expect(
          completed.parent.parent.path,
          await output.resolveSymbolicLinks(),
        );
        await completed.parent.delete(recursive: true);
        stalling = true;
        final elapsed = Stopwatch()..start();
        final result = await _invoke(server, [
          ..._downloadArgs(output),
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 124, reason: result.error);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
        expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 1400)));
        expect(
          byteRequests,
          1,
          reason:
              'The measured deadline must include byte transfer, not only metadata.',
        );
        expect(
          started,
          isTrue,
          reason:
              'The byte source must be consumed before requiring cancellation.',
        );
        expect(await output.list().toList(), isEmpty);
        await cancelled.future.timeout(const Duration(seconds: 3));
      });
    },
  );

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
  ]) {
    test(
      'artifact download source CLI handles $signal and cleans its partial file',
      () async {
        final output = await Directory.systemTemp.createTemp('cli-artifact-');
        addTearDown(() => output.delete(recursive: true));
        final arrived = Completer<void>(), cancelled = Completer<void>();
        late StreamController<List<int>> body;
        body = StreamController<List<int>>(
          onListen: () {
            body.add(utf8.encode('GaoOS'));
            arrived.complete();
          },
          onCancel: () {
            if (!cancelled.isCompleted) cancelled.complete();
          },
        );
        addTearDown(body.close);
        final router = PublicApiRouter()
          ..add(
            'GET',
            '/v1/test-runs/{test_run_id}/artifacts',
            (_) async => PublicApiResponse.json(
              status: 200,
              body: {
                'items': [_downloadMetadata().toJson()],
                'next_cursor': null,
              },
            ),
          )
          ..add(
            'GET',
            '/v1/artifacts/{artifact_id}',
            (_) async => PublicApiResponse.stream(
              body: body.stream,
              contentType: ContentType('application', 'octet-stream'),
              headers: _downloadHeaders(),
            ),
          );
        await _withServer(router, (server) async {
          final process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovm_cli.dart',
            '--socket-path',
            server.socketPath,
            ..._downloadArgs(output),
            '--json',
          ]);
          final exited = process.exitCode;
          var exitConfirmed = false;
          final stdout = utf8.decoder.bind(process.stdout).join();
          final stderr = utf8.decoder.bind(process.stderr).join();
          try {
            await arrived.future.timeout(const Duration(seconds: 15));
            expect(process.kill(signal), isTrue);
            final actual = await exited.timeout(const Duration(seconds: 5));
            exitConfirmed = true;
            expect(actual, code, reason: await stderr);
            expect(await stdout, isEmpty);
            expect(jsonDecode(await stderr)['code'], 'CLI_INTERRUPTED');
            expect(await output.list().toList(), isEmpty);
            await cancelled.future.timeout(const Duration(seconds: 3));
          } finally {
            if (!exitConfirmed) {
              process.kill(ProcessSignal.sigkill);
              await exited.timeout(const Duration(seconds: 5));
            }
          }
        });
      },
    );
  }

  test(
    'artifact download walks validated pages and consumes the exact public URL',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      final calls = <String>[];
      final router = PublicApiRouter()
        ..add('GET', '/v1/test-runs/{test_run_id}/artifacts', (request) async {
          calls.add(request.uri.toString());
          expect(request.headers['idempotency-key'], isNull);
          expect(request.pathParameters['test_run_id'], _downloadOwner);
          expect(request.uri.queryParameters['limit'], '200');
          return PublicApiResponse.json(
            status: 200,
            body: {
              'items': request.uri.queryParameters['cursor'] == null
                  ? []
                  : [_downloadMetadata().toJson()],
              'next_cursor': request.uri.queryParameters['cursor'] == null
                  ? 'opaque & cursor'
                  : null,
            },
          );
        })
        ..add('GET', '/v1/artifacts/{artifact_id}', (request) async {
          calls.add(request.uri.toString());
          expect(request.pathParameters['artifact_id'], _downloadId);
          expect(request.headers['idempotency-key'], isNull);
          return PublicApiResponse.stream(
            body: Stream.value(utf8.encode('GaoOS artifact output\n')),
            contentType: ContentType('application', 'octet-stream'),
            headers: _downloadHeaders(),
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, _downloadArgs(output));
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        final receipt = jsonDecode(result.output) as Map;
        expect(
          await File(receipt['output_path'] as String).readAsString(),
          'GaoOS artifact output\n',
        );
        expect(calls, hasLength(3));
        expect(
          Uri.parse(calls[1]).queryParameters['cursor'],
          'opaque & cursor',
        );
        expect(calls.last, '/v1/artifacts/$_downloadId');
      });
    },
  );

  for (final invalid in [
    'owner',
    'URL',
    'duplicate',
    'extra',
    'cursor',
    'later record',
  ]) {
    test(
      'artifact download rejects $invalid metadata before writing or fetching bytes',
      () async {
        final output = await Directory.systemTemp.createTemp('cli-artifact-');
        addTearDown(() => output.delete(recursive: true));
        var byteReads = 0;
        final row = _downloadMetadata().toJson();
        if (invalid == 'owner')
          row['test_run_id'] = 'tr_01J00000000000000000000007';
        if (invalid == 'URL')
          row['download_url'] = '/v1/artifacts/art_01J00000000000000000000001';
        final page = <String, Object?>{
          'items': [
            row,
            if (invalid == 'duplicate') row,
            if (invalid == 'later record') {'id': 'broken'},
          ],
          'next_cursor': invalid == 'cursor' ? '' : null,
          if (invalid == 'extra') 'extra': true,
        };
        final router = PublicApiRouter()
          ..add(
            'GET',
            '/v1/test-runs/{test_run_id}/artifacts',
            (_) async => PublicApiResponse.json(status: 200, body: page),
          )
          ..add('GET', '/v1/artifacts/{artifact_id}', (_) async {
            byteReads++;
            return PublicApiResponse.json(status: 200, body: const {});
          });
        await _withServer(router, (server) async {
          final result = await _invoke(server, _downloadArgs(output));
          expect(result.code, 4, reason: result.error);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
          expect(byteReads, 0);
          expect(await output.list().toList(), isEmpty);
        });
      },
    );
  }

  test(
    'artifact download detects repeated cursors rather than walking forever',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      var calls = 0;
      final router = PublicApiRouter()
        ..add('GET', '/v1/test-runs/{test_run_id}/artifacts', (_) async {
          calls++;
          return PublicApiResponse.json(
            status: 200,
            body: {'items': [], 'next_cursor': 'same'},
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, _downloadArgs(output));
        expect(result.code, 4);
        expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        expect(calls, 2);
        expect(await output.list().toList(), isEmpty);
      });
    },
  );

  test(
    'artifact download missing ID has a stable failure without local files',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/test-runs/{test_run_id}/artifacts',
          (_) async => PublicApiResponse.json(
            status: 200,
            body: {'items': [], 'next_cursor': null},
          ),
        );
      await _withServer(router, (server) async {
        final result = await _invoke(server, _downloadArgs(output));
        expect(result.code, 1);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'ARTIFACT_NOT_FOUND');
        expect(await output.list().toList(), isEmpty);
      });
    },
  );

  test(
    'artifact download refuses oversized metadata with a local admission exit',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      final row = _downloadMetadata().toJson()
        ..['size_bytes'] = 256 * 1024 * 1024 + 1;
      var byteReads = 0;
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/test-runs/{test_run_id}/artifacts',
          (_) async => PublicApiResponse.json(
            status: 200,
            body: {
              'items': [row],
              'next_cursor': null,
            },
          ),
        )
        ..add('GET', '/v1/artifacts/{artifact_id}', (_) async {
          byteReads++;
          return PublicApiResponse.json(status: 200, body: const {});
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, _downloadArgs(output));
        expect(result.code, 1, reason: result.error);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_ARTIFACT_LIMIT');
        expect(byteReads, 0);
        expect(await output.list().toList(), isEmpty);
      });
    },
  );

  for (final corrupt in [false, true]) {
    test(
      'artifact download ${corrupt ? 'corrupt payload' : 'typed server problem'} preserves diagnostics and removes staging',
      () async {
        final output = await Directory.systemTemp.createTemp('cli-artifact-');
        addTearDown(() => output.delete(recursive: true));
        final router = PublicApiRouter()
          ..add(
            'GET',
            '/v1/test-runs/{test_run_id}/artifacts',
            (_) async => PublicApiResponse.json(
              status: 200,
              body: {
                'items': [_downloadMetadata().toJson()],
                'next_cursor': null,
              },
            ),
          )
          ..add(
            'GET',
            '/v1/artifacts/{artifact_id}',
            (_) async => corrupt
                ? PublicApiResponse.stream(
                    body: Stream.value(utf8.encode('XaoOS artifact output\n')),
                    contentType: ContentType('application', 'octet-stream'),
                    headers: _downloadHeaders(),
                  )
                : PublicApiResponse.problem(
                    status: 500,
                    code: ErrorCode.internalError,
                    type: 'artifact-unavailable',
                    title: 'Artifact unavailable',
                    detail: 'Stored bytes unavailable.',
                    retryable: false,
                  ),
          );
        await _withServer(router, (server) async {
          final result = await _invoke(server, _downloadArgs(output));
          expect(result.code, corrupt ? 4 : 1, reason: result.error);
          expect(result.output, isEmpty);
          if (corrupt) {
            expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
          } else {
            final problem = Problem.fromJson(jsonDecode(result.error));
            expect(problem.code, ErrorCode.internalError);
            expect(problem.requestId, isA<RequestId>());
            expect(problem.retryable, isFalse);
          }
          expect(await output.list().toList(), isEmpty);
        });
      },
    );
  }

  test(
    'artifact download rejects invalid options and local directories before HTTP',
    () async {
      final output = await Directory.systemTemp.createTemp('cli-artifact-');
      addTearDown(() => output.delete(recursive: true));
      var calls = 0;
      final router = PublicApiRouter()
        ..add('GET', '/v1/test-runs/{test_run_id}/artifacts', (_) async {
          calls++;
          return PublicApiResponse.json(status: 200, body: const {});
        });
      await _withServer(router, (server) async {
        for (final args in [
          ['test', 'download', _downloadOwner, _downloadId],
          [
            'test',
            'download',
            'default',
            _downloadId,
            '--output-dir',
            output.path,
          ],
          [
            'test',
            'download',
            _downloadOwner,
            _downloadOwner,
            '--output-dir',
            output.path,
          ],
          [..._downloadArgs(output), '--idempotency-key', 'not-a-mutation'],
          [..._downloadArgs(output), '--cursor', 'unsupported'],
          [..._downloadArgs(output), '--body-json', '{}'],
          [..._downloadArgs(output), '--output-dir', output.path],
          ['test', 'artifacts', _downloadOwner, '--output-dir', output.path],
        ]) {
          final result = await _invoke(server, args);
          expect(result.code, 2, reason: result.error);
          expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
        }
        final result = await _invoke(
          server,
          _downloadArgs(Directory('${output.path}/missing')),
        );
        expect(result.code, 1);
        expect(jsonDecode(result.error)['code'], 'CLI_LOCAL_IO');
        expect(calls, 0);
        expect(await output.list().toList(), isEmpty);
      });
    },
  );
}
