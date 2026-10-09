part of 'catalog_test.dart';

void _testRunPayloadTests() {
  testWidgets('TestRun payload reads ignore unsubmitted ID and socket drafts', (
    tester,
  ) async {
    await _deletionDesktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(handler: _testPayloadRoutes),
    ))!;
    addTearDown(api.close);
    await _openTestArtifact(tester, api);
    await tester.enterText(
      find.byKey(const Key('test-run-id')),
      'tr_01J00000000000000000000007',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Daemon socket'),
      '/missing/draft.sock',
    );
    await _readTestPayload(tester);
    await _hostUntil(tester, find.text('Verified payload · 22 bytes'));
    expect(api.requests, [
      'GET /v1/test-runs/$_testRunId',
      'GET /v1/test-runs/$_testRunId/artifacts',
      'GET /v1/artifacts/art_01J00000000000000000000000',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final change in ['lookup', 'catalog reload']) {
    testWidgets(
      'TestRun $change releases a pending payload and clears its selection',
      (tester) async {
        await _deletionDesktop(tester);
        final stall = (await tester.runAsync(
          () async => _TestPayloadStall(bodyStarted: true),
        ))!;
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path.startsWith('/v1/artifacts/')) {
                await stall.read(request, api);
              } else if (request.uri.path ==
                  '/v1/test-runs/tr_01J00000000000000000000007') {
                await _testRunReply(
                  request,
                  _testRunJson(id: 'tr_01J00000000000000000000007'),
                );
              } else {
                await _testPayloadRoutes(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openTestArtifact(tester, api);
        await _readTestPayload(tester);
        await _untilSignal(tester, stall.arrived);
        if (change == 'lookup') {
          await tester.enterText(
            find.byKey(const Key('test-run-id')),
            'tr_01J00000000000000000000007',
          );
          await tester.runAsync(
            () async => tester.tap(find.text('Observe TestRun')),
          );
        } else {
          await tester.ensureVisible(find.text('Load TestRun artifacts'));
          await tester.pump();
          await tester.runAsync(
            () async => tester.tap(find.text('Load TestRun artifacts')),
          );
        }
        await _untilSignal(tester, stall.disconnected);
        expect(find.text('ARTIFACT SNAPSHOT'), findsNothing);
        expect(find.textContaining('Verified payload · '), findsNothing);
        expect(api.requests, hasLength(4));
        expect(
          api.requests.every((request) => request.startsWith('GET ')),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final example in [
    (
      bytes: <int>[255, 254, 253],
      hex: '8ca9f8c269c0a4b1d8bf0efc67d97df8ad5e0ea93630fd9099860d36c0fe75ea',
      mime: 'text/plain; charset=utf-8',
      label: 'Binary preview · 3 of 3 verified bytes',
    ),
    (
      bytes: <int>[],
      hex: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      mime: 'text/plain',
      label: 'Empty artifact',
    ),
    (
      bytes: utf8.encode('<script>alert(1)</script>'),
      hex: '5c140d35dcb46a622e2cedf5ef5cc3638cdffd1c118c9331f8c84669f0b74783',
      mime: 'text/html',
      label: '<script>alert(1)</script>',
    ),
    (
      bytes: List<int>.filled(512, 0),
      hex: '076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560',
      mime: 'application/octet-stream',
      label: 'Binary preview · 256 of 512 verified bytes',
    ),
  ]) {
    testWidgets('TestRun payload safely renders ${example.label}', (
      tester,
    ) async {
      await _deletionDesktop(tester);
      final artifact = _testArtifactJson()
        ..['size_bytes'] = example.bytes.length
        ..['digest'] = 'sha256:${example.hex}'
        ..['content_type'] = example.mime;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _testPayloadRoutes(
            request,
            artifact: artifact,
            payload: example.bytes,
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _readTestPayload(tester);
      await _hostUntil(
        tester,
        find.text('Verified payload · ${example.bytes.length} bytes'),
      );
      expect(find.text(example.label), findsOneWidget);
      expect(api.requests, hasLength(3));
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final bodyStarted in [false, true]) {
    for (final exit in ['close', 'navigation', 'Connect']) {
      testWidgets(
        'TestRun payload ${bodyStarted ? 'body' : 'headers'} $exit releases its actual socket',
        (tester) async {
          await _deletionDesktop(tester);
          final stall = (await tester.runAsync(
            () async => _TestPayloadStall(bodyStarted: bodyStarted),
          ))!;
          late _ApiFixture api;
          api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) =>
                  request.uri.path.startsWith('/v1/artifacts/')
                  ? stall.read(request, api)
                  : _testPayloadRoutes(request),
            ),
          ))!;
          addTearDown(api.close);
          await _openTestArtifact(tester, api);
          await _readTestPayload(tester);
          await _untilSignal(tester, stall.arrived);
          expect(find.textContaining('Verified payload · '), findsNothing);
          if (exit == 'close') {
            await tester.pumpWidget(const SizedBox.shrink());
          } else if (exit == 'navigation') {
            await tester.tap(find.widgetWithText(TextButton, 'Events'));
          } else {
            await tester.runAsync(() async => tester.tap(find.text('Connect')));
          }
          await _untilSignal(tester, stall.disconnected);
          expect(api.requests, hasLength(3));
          expect(
            api.requests.every((request) => request.startsWith('GET ')),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'another artifact selection releases old bytes and owns only its payload',
    (tester) async {
      await _deletionDesktop(tester);
      final stall = (await tester.runAsync(
        () async => _TestPayloadStall(bodyStarted: true),
      ))!;
      final second = _testArtifactJson(id: 'art_01J00000000000000000000001')
        ..['digest'] =
            'sha256:78c4b12675111e1cced1e98b3d3fc6474baf7591593138bb720fe384fc32d460';
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path ==
                '/v1/artifacts/art_01J00000000000000000000000') {
              await stall.read(request, api);
            } else if (request.uri.path ==
                '/v1/artifacts/art_01J00000000000000000000001') {
              await _testPayloadReply(
                request,
                artifact: second,
                payload: utf8.encode('Other artifact output\n'),
              );
            } else if (request.uri.path.endsWith('/artifacts')) {
              await _testRunReply(request, {
                'items': [_testArtifactJson(), second],
                'next_cursor': null,
              });
            } else {
              await _testRunReply(request, _testRunJson());
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _readTestPayload(tester);
      await _untilSignal(tester, stall.arrived);
      final row = find.byKey(
        const Key('artifact-art_01J00000000000000000000001'),
      );
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await _untilSignal(tester, stall.disconnected);
      expect(find.textContaining('Verified payload · '), findsNothing);
      await _readTestPayload(tester);
      await _hostUntil(tester, find.text('Other artifact output\n'));
      expect(find.text('GaoOS artifact output\n'), findsNothing);
      expect(api.requests, hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TestRun payload preview rejects large metadata before HTTP', (
    tester,
  ) async {
    await _deletionDesktop(tester);
    final artifact = _testArtifactJson()..['size_bytes'] = 65537;
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _testPayloadRoutes(request, artifact: artifact),
      ),
    ))!;
    addTearDown(api.close);
    await _openTestArtifact(tester, api);
    expect(
      find.text('Payload exceeds the 64 KiB preview limit.'),
      findsOneWidget,
    );
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Read artifact bytes'),
    );
    expect(button.onPressed, isNull);
    expect(api.requests, hasLength(2));
    expect(find.textContaining('Verified payload · '), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final hadVerifiedRead in [false, true]) {
    testWidgets(
      'TestRun corrupt bytes ${hadVerifiedRead ? 'retain the verified snapshot' : 'cannot become a payload'}',
      (tester) async {
        await _deletionDesktop(tester);
        var reads = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path.startsWith('/v1/artifacts/')) {
                await _testPayloadReply(
                  request,
                  payload: ++reads == 1 && hadVerifiedRead
                      ? null
                      : utf8.encode('XaoOS artifact output\n'),
                );
              } else {
                await _testPayloadRoutes(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openTestArtifact(tester, api);
        if (hadVerifiedRead) {
          await _readTestPayload(tester);
          await _hostUntil(tester, find.text('Verified payload · 22 bytes'));
        }
        await _readTestPayload(tester);
        await _hostUntil(
          tester,
          find.textContaining('failed length or SHA-256'),
        );
        if (hadVerifiedRead) {
          expect(
            find.text('Payload read failed · last verified bytes retained.'),
            findsOneWidget,
          );
          expect(find.text('GaoOS artifact output\n'), findsOneWidget);
        } else {
          expect(find.textContaining('Verified payload · '), findsNothing);
        }
        expect(api.requests, hasLength(hadVerifiedRead ? 4 : 3));
        expect(
          api.requests.every((request) => request.startsWith('GET ')),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'TestRun binary artifact bytes are verified without guessing text',
    (tester) async {
      await _deletionDesktop(tester);
      final artifact = _testArtifactJson()
        ..['content_type'] = 'application/octet-stream';
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _testPayloadRoutes(request, artifact: artifact),
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('test-payload-preview');
      await _openTestArtifact(
        tester,
        api,
        app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.ensureVisible(find.text('Read artifact bytes'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Read artifact bytes')),
      );
      await _hostUntil(tester, find.text('Verified payload · 22 bytes'));
      expect(find.text('GaoOS artifact output\n'), findsNothing);
      expect(
        find.text('Binary preview · 22 of 22 verified bytes'),
        findsOneWidget,
      );
      expect(find.textContaining('47 61 6f 4f 53'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TestRun artifact contents require an explicit verified public read',
    (tester) async {
      await _deletionDesktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(handler: _testPayloadRoutes),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('test-payload-preview');
      await _openTestArtifact(
        tester,
        api,
        app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      expect(api.requests, hasLength(2));
      expect(find.text('Read artifact bytes'), findsOneWidget);
      await tester.ensureVisible(find.text('Read artifact bytes'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Read artifact bytes')),
      );
      await _hostUntil(tester, find.text('Verified payload · 22 bytes'));
      expect(find.text('GaoOS artifact output\n'), findsOneWidget);
      expect(
        find.text('Payload request · req_01J00000000000000000000009'),
        findsOneWidget,
      );
      expect(api.requests, [
        'GET /v1/test-runs/$_testRunId',
        'GET /v1/test-runs/$_testRunId/artifacts',
        'GET /v1/artifacts/art_01J00000000000000000000000',
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
          final output = File('build/ui-test-run-payload-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _readTestPayload(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Read artifact bytes'));
  await tester.pump();
  await tester.runAsync(
    () async => tester.tap(find.text('Read artifact bytes')),
  );
}

Future<void> _openTestArtifact(
  WidgetTester tester,
  _ApiFixture api, {
  Widget app = const GaoVmApp(),
}) async {
  await _openTestRun(tester, api, app: app);
  await tester.runAsync(
    () async => tester.tap(find.text('Load TestRun artifacts')),
  );
  final row = find.byKey(const Key('artifact-art_01J00000000000000000000000'));
  await _hostUntil(tester, row);
  await tester.tap(row);
  await tester.pump();
}

Future<void> _testPayloadRoutes(
  HttpRequest request, {
  Map<String, Object?>? artifact,
  List<int>? payload,
}) async {
  if (request.uri.path.startsWith('/v1/artifacts/')) {
    await _testPayloadReply(request, artifact: artifact, payload: payload);
  } else {
    await _testRunReply(
      request,
      request.uri.path.endsWith('/artifacts')
          ? {
              'items': [artifact ?? _testArtifactJson()],
              'next_cursor': null,
            }
          : _testRunJson(),
    );
  }
}

Future<void> _testPayloadReply(
  HttpRequest request, {
  List<int>? payload,
  Map<String, Object?>? artifact,
}) async {
  final bytes = payload ?? utf8.encode('GaoOS artifact output\n');
  _testPayloadHeaders(request.response, size: bytes.length, artifact: artifact);
  request.response.add(bytes);
  await request.response.close();
}

void _testPayloadHeaders(
  HttpResponse response, {
  int size = 22,
  Map<String, Object?>? artifact,
}) {
  final hex = ((artifact ?? _testArtifactJson())['digest']! as String)
      .substring(7);
  final digest = List<int>.generate(
    32,
    (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
  );
  response.headers.contentType = ContentType('application', 'octet-stream');
  response.contentLength = size;
  response.headers.set('Digest', 'sha-256=${base64.encode(digest)}');
  response.headers.set('X-Request-ID', 'req_01J00000000000000000000009');
}

class _TestPayloadStall {
  _TestPayloadStall({required this.bodyStarted});
  final bool bodyStarted;
  final arrived = Completer<void>();
  final disconnected = Completer<void>();

  Future<void> read(HttpRequest request, _ApiFixture api) async {
    _testPayloadHeaders(request.response);
    final socket = await request.response.detachSocket(
      writeHeaders: bodyStarted,
    );
    api.detached.add(socket);
    void closed() {
      if (!disconnected.isCompleted) disconnected.complete();
    }

    socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
    if (bodyStarted) {
      socket.add(utf8.encode('GaoOS'));
      await socket.flush();
    }
    arrived.complete();
  }
}
