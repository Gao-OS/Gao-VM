part of 'catalog_test.dart';

void _testRunDownloadTests() {
  testWidgets(
    'TestRun downloads large verified bytes into a selected directory',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      final picker = _downloadPicker(() async => output.path);
      const id = 'art_01J00000000000000000000000';
      final marker = File('${output.path}/$id');
      await tester.runAsync(() => marker.writeAsString('Existing caller file'));
      final artifact = _testArtifactJson()
        ..['size_bytes'] = 2 * 1024 * 1024
        ..['content_type'] = 'application/octet-stream'
        ..['digest'] =
            'sha256:5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee';
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path.startsWith('/v1/artifacts/')) {
              _testPayloadHeaders(
                request.response,
                size: artifact['size_bytes']! as int,
                artifact: artifact,
              );
              final chunk = List<int>.filled(8192, 0);
              for (var i = 0; i < 256; i++) {
                request.response.add(chunk);
                await request.response.flush();
              }
              await request.response.close();
            } else {
              await _testPayloadRoutes(request, artifact: artifact);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      expect(picker.calls, isEmpty);
      expect(api.requests, hasLength(2));
      expect(
        find.text('Payload exceeds the 64 KiB preview limit.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('test-run-id')),
        'tr_01J00000000000000000000007',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Daemon socket'),
        '/missing/draft.sock',
      );
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Verified download · 2097152 bytes'));
      expect(
        find.text(
          'Metadata snapshot · verification belongs to an explicit read or download.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Download request · req_01J00000000000000000000009'),
        findsOneWidget,
      );
      final path = _downloadPath(tester);
      await tester.runAsync(() async {
        final file = File(path);
        expect(file.parent.parent.path, await output.resolveSymbolicLinks());
        expect(file.uri.pathSegments.last, id);
        expect(await file.length(), 2 * 1024 * 1024);
        final reader = await file.open();
        try {
          expect(await reader.read(8192), everyElement(0));
          await reader.setPosition(2 * 1024 * 1024 - 8192);
          expect(await reader.read(8192), everyElement(0));
        } finally {
          await reader.close();
        }
        expect(await marker.readAsString(), 'Existing caller file');
        expect(await output.list().length, 2);
      });
      expect(picker.calls, hasLength(1));
      expect(picker.calls.single.confirmButtonText, 'Download here');
      expect(picker.calls.single.canCreateDirectories, isFalse);
      expect(api.requests, [
        'GET /v1/test-runs/$_testRunId',
        'GET /v1/test-runs/$_testRunId/artifacts',
        'GET /v1/artifacts/$id',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
      expect(await tester.runAsync(() => File(path).exists()), isTrue);
    },
  );
  testWidgets(
    'TestRun download cancellation removes partial output before retry',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      _downloadPicker(() async => output.path);
      final stall = (await tester.runAsync(
        () async => _TestPayloadStall(bodyStarted: true),
      ))!;
      var downloads = 0;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path.startsWith('/v1/artifacts/') &&
                ++downloads == 1) {
              await stall.read(request, api);
            } else {
              await _testPayloadRoutes(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _untilSignal(tester, stall.arrived);
      await _downloadDirectoryUntil(tester, output, (entries) async {
        if (entries.length != 1 || entries.single is! Directory) return false;
        final partial = File('${entries.single.path}/payload.part');
        return await partial.exists() && await partial.length() == 5;
      });
      expect(find.textContaining('Verified download · '), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Download artifact'),
            )
            .onPressed,
        isNull,
      );
      final cancel = find.widgetWithText(TextButton, 'Cancel download');
      await tester.ensureVisible(cancel);
      await tester.pump();
      await tester.tap(cancel);
      await _untilSignal(tester, stall.disconnected);
      await _hostUntil(
        tester,
        find.text('Download cancelled · partial output removed.'),
      );
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Verified download · 22 bytes'));
      expect(
        find.text('Download cancelled · partial output removed.'),
        findsNothing,
      );
      expect(api.requests, hasLength(4));
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final bodyStarted in [false, true]) {
    for (final exit in [
      'close',
      'navigation',
      'Connect',
      'lookup',
      'catalog reload',
      'selection',
    ]) {
      testWidgets(
        'TestRun download ${bodyStarted ? 'body' : 'headers'} $exit releases its socket and staging',
        (tester) async {
          await _deletionDesktop(tester);
          final output = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('gvm-ui-download-'),
          ))!;
          addTearDown(() => output.delete(recursive: true));
          final marker = File('${output.path}/keep.txt');
          await tester.runAsync(() => marker.writeAsString('Caller-owned'));
          _downloadPicker(() async => output.path);
          final stall = (await tester.runAsync(
            () async => _TestPayloadStall(bodyStarted: bodyStarted),
          ))!;
          late _ApiFixture api;
          api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                if (request.uri.path.startsWith('/v1/artifacts/')) {
                  await stall.read(request, api);
                } else if (request.uri.path.endsWith('/artifacts')) {
                  await _testRunReply(request, {
                    'items': [
                      _testArtifactJson(),
                      _testArtifactJson(id: _secondDownloadArtifact),
                    ],
                    'next_cursor': null,
                  });
                } else {
                  await _testRunReply(
                    request,
                    _testRunJson(id: request.uri.path.split('/').last),
                  );
                }
              },
            ),
          ))!;
          addTearDown(api.close);
          await _openTestArtifact(tester, api);
          await _downloadTestArtifact(tester);
          await _untilSignal(tester, stall.arrived);
          await _downloadDirectoryUntil(tester, output, (entries) async {
            return entries.whereType<Directory>().length == 1;
          });
          expect(find.textContaining('Verified download · '), findsNothing);
          await _leaveDownload(tester, exit);
          await _untilSignal(tester, stall.disconnected);
          await _downloadDirectoryUntil(tester, output, (entries) async {
            return entries.length == 1 && entries.single.path == marker.path;
          });
          expect(await tester.runAsync(marker.readAsString), 'Caller-owned');
          expect(find.textContaining('Verified download · '), findsNothing);
          expect(
            api.requests.where((request) => request.contains('/v1/artifacts/')),
            hasLength(1),
          );
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

  for (final exit in [
    'close',
    'navigation',
    'Connect',
    'lookup',
    'catalog reload',
    'selection',
  ]) {
    testWidgets('TestRun download $exit ignores a late directory choice', (
      tester,
    ) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      final choice = (await tester.runAsync(() async => Completer<String?>()))!;
      final picker = _downloadPicker(() => choice.future);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(handler: _downloadCatalogRoutes),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Choosing a download directory…'));
      await _leaveDownload(tester, exit);
      final elapsed = Stopwatch()..start();
      while (find
              .text('Choosing a download directory…')
              .evaluate()
              .isNotEmpty &&
          elapsed.elapsed < const Duration(seconds: 3)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Choosing a download directory…'), findsNothing);
      await tester.runAsync(() async {
        choice.complete(output.path);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(picker.calls, hasLength(1));
      expect(
        api.requests.where((request) => request.contains('/v1/artifacts/')),
        isEmpty,
      );
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      expect(find.textContaining('Verified download · '), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'TestRun download cancelled directory choice starts no HTTP or file',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      var choices = 0;
      final picker = _downloadPicker(
        () async => ++choices == 1 ? null : output.path,
      );
      final api = (await tester.runAsync(
        () => _ApiFixture.open(handler: _testPayloadRoutes),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(2));
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      expect(find.textContaining('Verified download · '), findsNothing);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Verified download · 22 bytes'));
      expect(picker.calls, hasLength(2));
      expect(api.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TestRun download directory-dialog error permits an explicit retry',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      var choices = 0;
      _downloadPicker(() async {
        if (++choices == 1) {
          throw PlatformException(
            code: 'chooser_failed',
            message: 'Dialog unavailable',
          );
        }
        return output.path;
      });
      final api = (await tester.runAsync(
        () => _ApiFixture.open(handler: _testPayloadRoutes),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.textContaining('chooser_failed'));
      expect(api.requests, hasLength(2));
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Verified download · 22 bytes'));
      expect(find.textContaining('chooser_failed'), findsNothing);
      expect(api.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in ['relative', 'missing directory']) {
    testWidgets('TestRun download rejects $invalid before byte HTTP', (
      tester,
    ) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      _downloadPicker(
        () async => invalid == 'relative'
            ? 'relative-output'
            : '${output.path}/missing',
      );
      final api = (await tester.runAsync(
        () => _ApiFixture.open(handler: _testPayloadRoutes),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _hostUntil(
        tester,
        find.textContaining(
          invalid == 'relative'
              ? 'Choose an existing absolute directory.'
              : 'Cannot resolve symbolic links',
        ),
      );
      expect(api.requests, hasLength(2));
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      expect(find.textContaining('Verified download · '), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'TestRun download oversized metadata opens no chooser or byte HTTP',
    (tester) async {
      await _deletionDesktop(tester);
      final picker = _downloadPicker(
        () async => throw StateError('Not expected'),
      );
      final artifact = _testArtifactJson()
        ..['size_bytes'] = 256 * 1024 * 1024 + 1;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _testPayloadRoutes(request, artifact: artifact),
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      expect(
        find.text('Payload exceeds the 256 MiB download limit.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Download artifact'),
            )
            .onPressed,
        isNull,
      );
      expect(picker.calls, isEmpty);
      expect(api.requests, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final hadVerifiedDownload in [false, true]) {
    testWidgets(
      'TestRun download corrupt bytes ${hadVerifiedDownload ? 'retain the verified file' : 'never become a receipt'}',
      (tester) async {
        await _deletionDesktop(tester);
        final output = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('gvm-ui-download-'),
        ))!;
        addTearDown(() => output.delete(recursive: true));
        _downloadPicker(() async => output.path);
        var reads = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              final payload = utf8.encode('GaoOS artifact output\n');
              if (request.uri.path.startsWith('/v1/artifacts/') &&
                  ++reads == (hadVerifiedDownload ? 2 : 1)) {
                payload[0] = 88;
              }
              await _testPayloadRoutes(request, payload: payload);
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openTestArtifact(tester, api);
        String? previous;
        if (hadVerifiedDownload) {
          await _downloadTestArtifact(tester);
          await _hostUntil(tester, find.text('Verified download · 22 bytes'));
          previous = _downloadPath(tester);
        }
        await _downloadTestArtifact(tester);
        await _hostUntil(
          tester,
          find.textContaining('failed length or SHA-256'),
        );
        expect(
          await tester.runAsync(() => output.list().length),
          hadVerifiedDownload ? 1 : 0,
        );
        if (previous != null) {
          expect(_downloadPath(tester), previous);
          expect(
            find.text('Download failed · last verified file retained.'),
            findsOneWidget,
          );
          expect(
            await tester.runAsync(() => File(previous!).readAsString()),
            'GaoOS artifact output\n',
          );
        } else {
          expect(find.textContaining('Verified download · '), findsNothing);
        }
        await _downloadTestArtifact(tester);
        await _hostUntil(
          tester,
          previous == null
              ? find.text('Verified download · 22 bytes')
              : find.byWidgetPredicate(
                  (widget) =>
                      widget is SelectableText &&
                      widget.data?.contains('/gaovm-artifact-') == true &&
                      widget.data != previous,
                ),
        );
        expect(find.textContaining('failed length or SHA-256'), findsNothing);
        if (previous != null) expect(_downloadPath(tester), isNot(previous));
        expect(
          await tester.runAsync(() => output.list().length),
          hadVerifiedDownload ? 2 : 1,
        );
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
    'TestRun download stays pending during an independent verified preview',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      _downloadPicker(() async => output.path);
      final stall = (await tester.runAsync(
        () async => _TestPayloadStall(bodyStarted: true),
      ))!;
      var reads = 0;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path.startsWith('/v1/artifacts/') && ++reads == 1) {
              await stall.read(request, api);
            } else {
              await _testPayloadRoutes(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _untilSignal(tester, stall.arrived);
      await _readTestPayload(tester);
      await _hostUntil(tester, find.text('Verified payload · 22 bytes'));
      expect(stall.disconnected.isCompleted, isFalse);
      expect(find.textContaining('Verified download · '), findsNothing);
      final cancel = find.widgetWithText(TextButton, 'Cancel download');
      await tester.ensureVisible(cancel);
      await tester.pump();
      await tester.tap(cancel);
      await _untilSignal(tester, stall.disconnected);
      await _hostUntil(
        tester,
        find.text('Download cancelled · partial output removed.'),
      );
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      expect(find.text('GaoOS artifact output\n'), findsOneWidget);
      expect(api.requests, hasLength(4));
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'TestRun download preserves structured public problems with no file',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      _downloadPicker(() async => output.path);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (!request.uri.path.startsWith('/v1/artifacts/')) {
              await _testPayloadRoutes(request);
              return;
            }
            request.response.statusCode = 404;
            request.response.headers.contentType = ContentType(
              'application',
              'problem+json',
            );
            request.response.headers.set(
              'X-Request-ID',
              'req_01J00000000000000000000009',
            );
            request.response.write(
              jsonEncode({
                'type': 'https://gaovm.dev/problems/artifact-not-found',
                'title': 'Artifact unavailable',
                'status': 404,
                'code': 'ARTIFACT_NOT_FOUND',
                'detail': 'The selected artifact has been removed.',
                'request_id': 'req_01J00000000000000000000009',
                'retryable': false,
                'operation_id': null,
                'details': {},
              }),
            );
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openTestArtifact(tester, api);
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('ARTIFACT_NOT_FOUND'));
      expect(find.text('Artifact unavailable'), findsOneWidget);
      expect(
        find.text('The selected artifact has been removed.'),
        findsOneWidget,
      );
      expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
      expect(find.textContaining('Verified download · '), findsNothing);
      expect(await tester.runAsync(() => output.list().isEmpty), isTrue);
      expect(api.requests, hasLength(3));
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TestRun download receipt clears on selection without deleting the file',
    (tester) async {
      await _deletionDesktop(tester);
      final output = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gvm-ui-download-'),
      ))!;
      addTearDown(() => output.delete(recursive: true));
      _downloadPicker(() async => output.path);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => request.uri.path.startsWith('/v1/artifacts/')
              ? _testPayloadReply(request)
              : _downloadCatalogRoutes(request),
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('test-download-preview');
      await _openTestArtifact(
        tester,
        api,
        app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await _downloadTestArtifact(tester);
      await _hostUntil(tester, find.text('Verified download · 22 bytes'));
      final saved = _downloadPath(tester);
      await tester.ensureVisible(find.text('Verified download · 22 bytes'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final preview = File('build/ui-test-run-download-preview.png');
          await preview.parent.create(recursive: true);
          await preview.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await _leaveDownload(tester, 'selection');
      expect(find.textContaining('Verified download · '), findsNothing);
      expect(find.text(saved), findsNothing);
      expect(
        await tester.runAsync(() => File(saved).readAsString()),
        'GaoOS artifact output\n',
      );
      expect(api.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await tester.runAsync(() => File(saved).exists()), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

String _downloadPath(WidgetTester tester) => tester
    .widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('/gaovm-artifact-') == true,
      ),
    )
    .data!;

Future<void> _downloadCatalogRoutes(HttpRequest request) => _testRunReply(
  request,
  request.uri.path.endsWith('/artifacts')
      ? {
          'items': [
            _testArtifactJson(),
            _testArtifactJson(id: _secondDownloadArtifact),
          ],
          'next_cursor': null,
        }
      : _testRunJson(id: request.uri.path.split('/').last),
);

const _secondDownloadArtifact = 'art_01J00000000000000000000001';

Future<void> _leaveDownload(WidgetTester tester, String exit) async {
  switch (exit) {
    case 'close':
      await tester.pumpWidget(const SizedBox.shrink());
    case 'navigation':
      await tester.tap(find.widgetWithText(TextButton, 'Events'));
    case 'Connect':
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
    case 'lookup':
      await tester.enterText(
        find.byKey(const Key('test-run-id')),
        'tr_01J00000000000000000000007',
      );
      await tester.runAsync(
        () async => tester.tap(find.text('Observe TestRun')),
      );
    case 'catalog reload':
      await tester.ensureVisible(find.text('Load TestRun artifacts'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Load TestRun artifacts')),
      );
    case 'selection':
      final row = find.byKey(const Key('artifact-$_secondDownloadArtifact'));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
    default:
      fail('Unknown download exit: $exit');
  }
  await tester.pump();
}

Future<void> _downloadDirectoryUntil(
  WidgetTester tester,
  Directory output,
  Future<bool> Function(List<FileSystemEntity>) condition,
) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 3)) {
    if ((await tester.runAsync(
      () async => condition(await output.list().toList()),
    ))!) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Download output did not reach the required state.');
}

Future<void> _downloadTestArtifact(WidgetTester tester) async {
  final button = find.widgetWithText(TextButton, 'Download artifact');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.runAsync(() async => tester.tap(button));
}

// Replace only the operating-system dialog, not the UI, SDK, or filesystem.
class _DownloadDirectoryPicker extends FileSelectorPlatform {
  _DownloadDirectoryPicker(this.pick);
  final Future<String?> Function() pick;
  final calls = <FileDialogOptions>[];

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) {
    calls.add(options);
    return pick();
  }
}

_DownloadDirectoryPicker _downloadPicker(Future<String?> Function() pick) {
  final previous = FileSelectorPlatform.instance;
  final picker = _DownloadDirectoryPicker(pick);
  FileSelectorPlatform.instance = picker;
  addTearDown(() => FileSelectorPlatform.instance = previous);
  return picker;
}
