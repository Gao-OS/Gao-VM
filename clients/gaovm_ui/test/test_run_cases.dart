part of 'catalog_test.dart';

void _testRunTests() {
  testWidgets('TestRun artifacts load and inspect only their public metadata', (
    tester,
  ) async {
    await _deletionDesktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          request.response.headers.set(
            'X-Request-ID',
            'req_01J00000000000000000000008',
          );
          await _reply(
            request,
            request.uri.path.endsWith('/artifacts')
                ? {
                    'items': [_testArtifactJson()],
                    'next_cursor': null,
                  }
                : _testRunJson(),
          );
        },
      ),
    ))!;
    addTearDown(api.close);
    const previewKey = Key('test-run-preview');
    await _openTestRun(
      tester,
      api,
      app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
    );
    await tester.runAsync(
      () async => tester.tap(find.text('Load TestRun artifacts')),
    );
    await _hostUntil(
      tester,
      find.byKey(const Key('artifact-art_01J00000000000000000000000')),
    );
    await tester.tap(
      find.byKey(const Key('artifact-art_01J00000000000000000000000')),
    );
    await tester.pump();
    expect(find.text('ARTIFACT SNAPSHOT'), findsOneWidget);
    expect(find.text('text/plain; charset=utf-8'), findsOneWidget);
    expect(
      find.text('/v1/artifacts/art_01J00000000000000000000000'),
      findsOneWidget,
    );
    expect(api.requests, [
      'GET /v1/test-runs/$_testRunId',
      'GET /v1/test-runs/$_testRunId/artifacts',
    ]);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(previewKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/ui-test-run-preview.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TestRun lookup reads another-client failure without a VM selection',
    (tester) async {
      await _deletionDesktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            request.response.headers.set(
              'X-Request-ID',
              'req_01J00000000000000000000008',
            );
            await _reply(request, _testRunJson());
          },
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.tap(find.widgetWithText(TextButton, 'TestRuns'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Daemon socket'),
        api.socketPath,
      );
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _hostUntil(tester, find.text('Enter a TestRun ID'));
      expect(api.requests, isEmpty);
      await tester.enterText(find.byKey(const Key('test-run-id')), _testRunId);
      await tester.runAsync(
        () async => tester.tap(find.text('Observe TestRun')),
      );
      await _hostUntil(tester, find.text('TestRun · failed'));
      expect(find.text('Cleanup decision · retain'), findsOneWidget);
      expect(find.text('GUEST_EXEC_FAILED'), findsWidgets);
      expect(find.textContaining('"exit_code": 23'), findsWidgets);
      expect(api.requests, ['GET /v1/test-runs/$_testRunId']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in ['id', 'spec', 'request ID', 'status']) {
    testWidgets(
      'TestRun refresh rejects changed $invalid and retains evidence',
      (tester) async {
        await _deletionDesktop(tester);
        var reads = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              final body = _testRunJson();
              final refreshed = ++reads > 1;
              if (refreshed && invalid == 'id') {
                body['id'] = 'tr_01J00000000000000000000007';
              }
              if (refreshed && invalid == 'spec') {
                (body['spec'] as Map<String, Object?>)['timeout_seconds'] =
                    1201;
              }
              if (refreshed && invalid == 'status') {
                request.response.statusCode = 201;
              }
              await _testRunReply(
                request,
                body,
                requestId: refreshed && invalid == 'request ID'
                    ? null
                    : 'req_01J00000000000000000000008',
              );
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openTestRun(tester, api);
        await tester.ensureVisible(find.text('Refresh TestRun'));
        await tester.pump();
        await tester.runAsync(
          () async => tester.tap(find.text('Refresh TestRun')),
        );
        await _hostUntil(
          tester,
          find.text('TestRun read failed · last validated snapshot retained.'),
        );
        expect(find.text('TestRun · failed'), findsOneWidget);
        expect(
          find.text('Read request · req_01J00000000000000000000008'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('test-run-detail-scroll')),
            matching: find.text(_testRunId),
          ),
          findsOneWidget,
        );
        expect(api.requests, List.filled(2, 'GET /v1/test-runs/$_testRunId'));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('invalid TestRun draft cannot retarget a validated read', (
    tester,
  ) async {
    await _deletionDesktop(tester);
    var reads = 0;
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _testRunReply(
          request,
          _testRunJson(),
          requestId: ++reads == 1
              ? 'req_01J00000000000000000000008'
              : 'req_01J00000000000000000000009',
        ),
      ),
    ))!;
    addTearDown(api.close);
    await _openTestRun(tester, api);
    await tester.enterText(find.byKey(const Key('test-run-id')), 'default');
    await tester.tap(find.text('Observe TestRun'));
    await tester.pump();
    expect(api.requests, ['GET /v1/test-runs/$_testRunId']);
    expect(find.text('TestRun · failed'), findsOneWidget);
    await tester.ensureVisible(find.text('Refresh TestRun'));
    await tester.pump();
    await tester.runAsync(() async => tester.tap(find.text('Refresh TestRun')));
    await _hostUntil(
      tester,
      find.text('Read request · req_01J00000000000000000000009'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(api.requests, List.filled(2, 'GET /v1/test-runs/$_testRunId'));
    expect(tester.takeException(), isNull);
  });

  for (final invalid in [
    'association',
    'download URL',
    'duplicate ID',
    'cursor loop',
    'record',
  ]) {
    testWidgets(
      'TestRun artifact $invalid rejects the whole page and retries',
      (tester) async {
        await _deletionDesktop(tester);
        const cursor = 'opaque+/cursor==';
        const nextId = 'art_01J00000000000000000000001';
        var pages = 0;
        final cursors = <String?>[];
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (!request.uri.path.endsWith('/artifacts')) {
                await _testRunReply(request, _testRunJson());
                return;
              }
              cursors.add(request.uri.queryParameters['cursor']);
              pages++;
              if (pages == 1) {
                await _testRunReply(request, {
                  'items': [_testArtifactJson()],
                  'next_cursor': cursor,
                });
                return;
              }
              final valid = _testArtifactJson(id: nextId);
              final bad = _testArtifactJson(
                id: 'art_01J00000000000000000000002',
              );
              if (invalid == 'association') {
                bad['test_run_id'] = 'tr_01J00000000000000000000007';
              }
              if (invalid == 'download URL') {
                bad['download_url'] = '/v1/artifacts/$nextId';
              }
              if (invalid == 'duplicate ID') {
                bad.addAll(_testArtifactJson());
              }
              if (invalid == 'record') {
                bad['digest'] = 'not-a-digest';
              }
              await _testRunReply(request, {
                'items': pages == 2 ? [valid, bad] : [valid],
                'next_cursor': pages == 2 && invalid == 'cursor loop'
                    ? cursor
                    : null,
              });
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openTestRun(tester, api);
        await tester.runAsync(
          () async => tester.tap(find.text('Load TestRun artifacts')),
        );
        final first = find.byKey(
          const Key('artifact-art_01J00000000000000000000000'),
        );
        await _hostUntil(tester, first);
        await tester.tap(first);
        await tester.pump();
        // Neither input draft changes an already accepted connection/identity.
        await tester.enterText(
          find.widgetWithText(TextField, 'Daemon socket'),
          '/missing/draft.sock',
        );
        await tester.enterText(
          find.byKey(const Key('test-run-id')),
          'tr_01J00000000000000000000007',
        );
        await tester.ensureVisible(find.text('Load more artifacts'));
        await tester.pump();
        await tester.runAsync(
          () async => tester.tap(find.text('Load more artifacts')),
        );
        await _hostUntil(
          tester,
          find.text('Artifact read failed · last validated page retained.'),
        );
        expect(find.byKey(const Key('artifact-$nextId')), findsNothing);
        expect(find.text('ARTIFACT SNAPSHOT'), findsOneWidget);
        await tester.ensureVisible(find.text('Load more artifacts'));
        await tester.pump();
        await tester.runAsync(
          () async => tester.tap(find.text('Load more artifacts')),
        );
        await _hostUntil(tester, find.byKey(const Key('artifact-$nextId')));
        expect(find.text('ARTIFACT SNAPSHOT'), findsOneWidget);
        expect(cursors, [null, cursor, cursor]);
        expect(api.requests, [
          'GET /v1/test-runs/$_testRunId',
          ...List.filled(3, 'GET /v1/test-runs/$_testRunId/artifacts'),
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final artifacts in [false, true]) {
    for (final exit in ['close', 'navigation', 'Connect']) {
      testWidgets(
        'TestRun ${artifacts ? 'artifact' : 'detail'} $exit releases its actual read socket',
        (tester) async {
          await _deletionDesktop(tester);
          final path =
              '/v1/test-runs/$_testRunId${artifacts ? '/artifacts' : ''}';
          final stall = (await tester.runAsync(
            () async => _HostStall(expected: [path]),
          ))!;
          late _ApiFixture api;
          api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                if (request.uri.path == path) {
                  await stall.read(request, api);
                } else {
                  await _testRunReply(request, _testRunJson());
                }
              },
            ),
          ))!;
          addTearDown(api.close);
          if (artifacts) {
            await _openTestRun(tester, api);
            await tester.runAsync(
              () async => tester.tap(find.text('Load TestRun artifacts')),
            );
          } else {
            await _connectTestRuns(tester, api);
            await tester.enterText(
              find.byKey(const Key('test-run-id')),
              _testRunId,
            );
            await tester.runAsync(
              () async => tester.tap(find.text('Observe TestRun')),
            );
          }
          await _untilSignal(tester, stall.arrived);
          if (exit == 'close') {
            await tester.pumpWidget(const SizedBox.shrink());
          } else if (exit == 'navigation') {
            await tester.tap(find.widgetWithText(TextButton, 'Events'));
          } else {
            await tester.runAsync(() async => tester.tap(find.text('Connect')));
          }
          await _untilSignal(tester, stall.disconnected);
          expect(api.requests, [
            if (artifacts) 'GET /v1/test-runs/$_testRunId',
            'GET $path',
          ]);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

const _testRunId = 'tr_01J00000000000000000000006';

Future<void> _openTestRun(
  WidgetTester tester,
  _ApiFixture api, {
  String id = _testRunId,
  Widget app = const GaoVmApp(),
}) async {
  await _connectTestRuns(tester, api, app: app);
  await tester.enterText(find.byKey(const Key('test-run-id')), id);
  await tester.runAsync(() async => tester.tap(find.text('Observe TestRun')));
  await _hostUntil(tester, find.textContaining('TestRun · '));
}

Future<void> _connectTestRuns(
  WidgetTester tester,
  _ApiFixture api, {
  Widget app = const GaoVmApp(),
}) async {
  await tester.pumpWidget(app);
  await tester.tap(find.widgetWithText(TextButton, 'TestRuns'));
  await tester.pump();
  await tester.enterText(
    find.widgetWithText(TextField, 'Daemon socket'),
    api.socketPath,
  );
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
  await _hostUntil(tester, find.text('Enter a TestRun ID'));
}

Future<void> _testRunReply(
  HttpRequest request,
  Object body, {
  String? requestId = 'req_01J00000000000000000000008',
}) async {
  if (requestId != null) {
    request.response.headers.set('X-Request-ID', requestId);
  }
  await _reply(request, body);
}

Map<String, Object?> _testArtifactJson({
  String id = 'art_01J00000000000000000000000',
  String runId = _testRunId,
}) => {
  'id': id,
  'vm_id': null,
  'operation_id': 'op_01J00000000000000000000005',
  'test_run_id': runId,
  'kind': 'stdout',
  'content_type': 'text/plain; charset=utf-8',
  'size_bytes': 22,
  'digest':
      'sha256:e9727bb930785755a576b86607683d312501e2dee6d360136f52b4ab71ecef51',
  'download_url': '/v1/artifacts/$id',
  'retention_until': '2026-10-04T08:00:00Z',
  'created_at': '2026-09-04T08:02:00Z',
};

Map<String, Object?> _testRunJson({
  String id = _testRunId,
  String state = 'failed',
}) {
  final request = <String, Object?>{
    'type': 'guest.exec',
    'name': 'Network smoke',
    'argv': ['gaoos-test', 'network'],
    'cwd': '/',
    'env': <String, String>{},
    'timeout_seconds': 600,
  };
  final error = <String, Object?>{
    'code': 'GUEST_EXEC_FAILED',
    'message': 'Network smoke exited with code 23.',
    'retryable': false,
    'details': {'exit_code': 23},
  };
  return {
    'id': id,
    'state': state,
    'spec': {
      'source': {'image_id': 'img_01J00000000000000000000004'},
      'wait': {'condition': 'guest_agent_ready', 'timeout_seconds': 120},
      'steps': [request],
      'cleanup': 'delete_on_success',
      'retain_on_failure': true,
      'timeout_seconds': 1200,
    },
    'vm_id': 'vm_01J00000000000000000000001',
    'operation_id': 'op_01J00000000000000000000005',
    'steps': [
      {
        'index': 0,
        'state': 'failed',
        'request': request,
        'result': {'exit_code': 23},
        'error': error,
        'started_at': '2026-09-04T08:01:00Z',
        'completed_at': '2026-09-04T08:02:00Z',
      },
    ],
    'cleanup_decision': 'retain',
    'result': {'exit_code': 23},
    'error': error,
    'artifact_ids': <String>[],
    'created_at': '2026-09-04T08:00:00Z',
    'completed_at': '2026-09-04T08:03:00Z',
  };
}
