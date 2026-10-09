part of 'catalog_test.dart';

void _hostStatusTests() {
  testWidgets('host status reads public diagnostics without a VM request', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(handler: _hostReply),
    ))!;
    addTearDown(api.close);
    await _connectHost(tester, api);
    await _hostUntil(tester, find.text('guest_profile · warning'));
    expect(find.text('Live · true'), findsOneWidget);
    expect(find.text('Ready · true'), findsOneWidget);
    expect(find.text('Doctor reported healthy'), findsOneWidget);
    expect(find.text('Backends · vz'), findsOneWidget);
    expect(find.text('Guest APIs · health · exec'), findsOneWidget);
    expect(find.text('Maximum defined VMs · 128'), findsOneWidget);
    expect(find.text('GaoOS guest readiness is not verified.'), findsOneWidget);
    expect(find.text('req_01J00000000000000000000003'), findsOneWidget);
    expect(api.requests.toSet(), {for (final path in _hostPaths) 'GET $path'});
    expect(api.requests, hasLength(4));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final probe in ['live', 'ready']) {
    testWidgets('host $probe 503 is a snapshot, not a failed read', (
      tester,
    ) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/$probe') {
              request.response.statusCode = 503;
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000009',
              );
              await _reply(request, {
                probe: false,
                'checks': {'database': false},
              });
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _hostUntil(tester, find.text('HTTP 503'));
      await _hostUntil(tester, find.text('Doctor reported healthy'));
      expect(
        find.text('${probe == 'live' ? 'Live' : 'Ready'} · false'),
        findsOneWidget,
      );
      expect(find.text('Doctor reported healthy'), findsOneWidget);
      expect(find.textContaining('"database": false'), findsOneWidget);
      expect(find.text('No validated report'), findsNothing);
      expect(api.requests, hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'host refresh stays on the configured socket and replaces only its report',
    (tester) async {
      await _desktop(tester);
      var readyReads = 0;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/ready' && ++readyReads == 2) {
              request.response.statusCode = 503;
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000009',
              );
              await _reply(request, {
                'ready': false,
                'checks': {'database': false},
              });
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _hostUntil(tester, find.text('Ready · true'));
      await _hostUntil(tester, find.text('Doctor reported healthy'));
      await tester.enterText(find.byType(TextField), '/unsubmitted/host.sock');
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh dependency readiness')),
      );
      await _hostUntil(tester, find.text('req_01J00000000000000000000009'));
      expect(find.text('Ready · false'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000001'), findsNothing);
      expect(find.text('Live · true'), findsOneWidget);
      expect(find.text('Maximum running VMs · 8'), findsOneWidget);
      expect(find.text('Doctor reported healthy'), findsOneWidget);
      expect(
        api.requests.where((path) => path == 'GET /v1/system/ready'),
        hasLength(2),
      );
      expect(api.requests, hasLength(5));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'host refresh failure retains the last validated value and correlation',
    (tester) async {
      await _desktop(tester);
      var readyReads = 0;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/ready' && ++readyReads == 2) {
              request.response.statusCode = 201;
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000009',
              );
              await _reply(request, {
                'ready': false,
                'checks': {'database': false},
              });
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _hostUntil(tester, find.text('Ready · true'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh dependency readiness')),
      );
      await _hostUntil(
        tester,
        find.text('Refresh failed · last validated snapshot retained.'),
      );
      expect(find.text('Ready · true'), findsOneWidget);
      expect(find.text('Ready · false'), findsNothing);
      expect(find.text('req_01J00000000000000000000001'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000009'), findsNothing);
      expect(find.text('Invalid host report HTTP status.'), findsOneWidget);
      expect(api.requests, hasLength(5));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a missing capabilities route is unavailable without hiding other host reports',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/capabilities') {
              await _hostProblem(request);
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _hostUntil(tester, find.text('INVALID_REQUEST'));
      await _hostUntil(tester, find.text('Doctor reported healthy'));
      expect(find.text('Live · true'), findsOneWidget);
      expect(find.text('Ready · true'), findsOneWidget);
      expect(find.text('Doctor reported healthy'), findsOneWidget);
      expect(find.text('API · v1'), findsNothing);
      expect(find.text('No validated report'), findsOneWidget);
      expect(find.text('Not retryable'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
      expect(api.requests, hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    'readiness checks',
    'readiness flag',
    'readiness extra',
    'status',
    'missing request ID',
    'request ID',
    'capability limits',
    'capability version',
    'guest duplicates',
    'doctor status',
  ]) {
    testWidgets(
      'host status rejects $invalid without publishing a partial report',
      (tester) async {
        await _desktop(tester);
        final path =
            invalid.startsWith('capability') || invalid == 'guest duplicates'
            ? '/v1/system/capabilities'
            : invalid == 'doctor status'
            ? '/v1/system/doctor'
            : '/v1/system/ready';
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path != path) {
                await _hostReply(request);
                return;
              }
              final body = path.endsWith('capabilities')
                  ? _hostCapabilities()
                  : path.endsWith('doctor')
                  ? _hostDoctor()
                  : <String, Object?>{'ready': true, 'checks': {}};
              if (invalid != 'missing request ID') {
                request.response.headers.set(
                  'X-Request-ID',
                  invalid == 'request ID'
                      ? 'req_not_an_id'
                      : 'req_01J00000000000000000000009',
                );
              }
              switch (invalid) {
                case 'readiness checks':
                  body.remove('checks');
                case 'readiness flag':
                  body['ready'] = 'yes';
                case 'readiness extra':
                  body['phase'] = 'running';
                case 'status':
                  request.response.statusCode = 201;
                case 'capability limits':
                  (body['limits']! as Map<String, Object?>)['max_running_vms'] =
                      0;
                case 'capability version':
                  body['api_version'] = 'v2';
                case 'guest duplicates':
                  body['guest'] = ['exec', 'exec'];
                case 'doctor status':
                  body['checks'] = [
                    {
                      'name': 'runtime',
                      'status': 'ready',
                      'message': 'not a public status',
                    },
                  ];
              }
              await _reply(request, body);
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectHost(tester, api);
        await _hostUntil(tester, find.text('No validated report'));
        await _hostUntil(tester, find.text('Live · true'));
        expect(find.text('req_01J00000000000000000000009'), findsNothing);
        expect(find.text('Live · true'), findsOneWidget);
        if (path.endsWith('ready')) {
          expect(find.text('Ready · true'), findsNothing);
        }
        if (path.endsWith('capabilities')) {
          expect(find.text('API · v1'), findsNothing);
        }
        if (path.endsWith('doctor')) {
          expect(find.text('Doctor reported healthy'), findsNothing);
        }
        expect(api.requests, hasLength(4));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final exit in ['window close', 'Operations', 'Connect']) {
    testWidgets('host $exit releases all four outstanding read sockets', (
      tester,
    ) async {
      await _desktop(tester);
      final stall = (await tester.runAsync(() async => _HostStall()))!;
      var reconnected = false;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/operations') {
              await _reply(request, {'items': [], 'next_cursor': null});
            } else if (reconnected) {
              await _hostReply(request);
            } else {
              await stall.read(request, api);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _untilSignal(tester, stall.arrived);
      switch (exit) {
        case 'window close':
          await tester.pumpWidget(const SizedBox.shrink());
        case 'Operations':
          await tester.runAsync(
            () async =>
                tester.tap(find.widgetWithText(TextButton, 'Operations')),
          );
        case 'Connect':
          reconnected = true;
          await tester.runAsync(() async => tester.tap(find.text('Connect')));
      }
      await _untilSignal(tester, stall.disconnected);
      if (exit == 'Operations') {
        await _until(tester, find.text('No Operations'));
      }
      if (exit == 'Connect') {
        await _hostUntil(tester, find.text('Doctor reported healthy'));
        expect(
          api.requests.where((request) => request == 'GET /v1/system/doctor'),
          hasLength(2),
        );
      }
      expect(stall.closed, _hostPaths.toSet());
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      expect(
        api.requests,
        hasLength(
          exit == 'Connect'
              ? 8
              : exit == 'Operations'
              ? 5
              : 4,
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final closeWindow in [true, false]) {
    testWidgets(
      'host ${closeWindow ? 'close' : 'navigation'} releases a stalled doctor refresh',
      (tester) async {
        await _desktop(tester);
        final stall = (await tester.runAsync(
          () async => _HostStall(expected: ['/v1/system/doctor']),
        ))!;
        var doctorReads = 0;
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path == '/v1/system/doctor' &&
                  ++doctorReads == 2) {
                await stall.read(request, api);
              } else if (request.uri.path == '/v1/operations') {
                await _reply(request, {'items': [], 'next_cursor': null});
              } else {
                await _hostReply(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectHost(tester, api);
        await _hostUntil(tester, find.text('Doctor reported healthy'));
        await tester.ensureVisible(find.text('Refresh host doctor'));
        await tester.runAsync(
          () async => tester.tap(find.text('Refresh host doctor')),
        );
        await _untilSignal(tester, stall.arrived);
        expect(find.text('Doctor reported healthy'), findsOneWidget);
        if (closeWindow) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(
            () async =>
                tester.tap(find.widgetWithText(TextButton, 'Operations')),
          );
        }
        await _untilSignal(tester, stall.disconnected);
        if (!closeWindow) await _until(tester, find.text('No Operations'));
        expect(api.requests, hasLength(closeWindow ? 5 : 6));
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
    'host reconnect releases old reads and uses only the new socket',
    (tester) async {
      await _desktop(tester);
      final stall = (await tester.runAsync(() async => _HostStall()))!;
      late _ApiFixture original;
      original = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => stall.read(request, original),
        ),
      ))!;
      final replacement = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/capabilities') {
              final body = _hostCapabilities();
              (body['limits']! as Map<String, Object?>)['max_defined_vms'] = 64;
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000009',
              );
              await _reply(request, body);
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(original.close);
      addTearDown(replacement.close);
      await _connectHost(tester, original);
      await _untilSignal(tester, stall.arrived);
      await tester.enterText(find.byType(TextField), replacement.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _untilSignal(tester, stall.disconnected);
      await _hostUntil(tester, find.text('Maximum defined VMs · 64'));
      expect(find.text('Maximum defined VMs · 128'), findsNothing);
      expect(original.requests, hasLength(4));
      expect(replacement.requests.toSet(), {
        for (final path in _hostPaths) 'GET $path',
      });
      expect(replacement.requests, hasLength(4));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'host navigation releases Events and ignores draft socket edits',
    (tester) async {
      await _desktop(tester);
      late _ApiFixture api;
      late _EventPeer peer;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/events') {
              peer = await _EventPeer.open(request, api);
              await peer.send(_eventRecord());
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectEvents(tester, api);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Resume cursor · 42'));
      await tester.enterText(
        find.byType(TextField).first,
        '/unsubmitted/host.sock',
      );
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Host status')),
      );
      await _untilSignal(tester, peer.disconnected);
      await _hostUntil(tester, find.text('Doctor reported healthy'));
      expect(api.requests.first, 'GET /v1/events');
      expect(api.requests.skip(1).toSet(), {
        for (final path in _hostPaths) 'GET $path',
      });
      expect(api.requests, hasLength(5));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'host cards remain readable and refreshable while doctor is stalled',
    (tester) async {
      await _desktop(tester);
      final stall = (await tester.runAsync(
        () async => _HostStall(expected: ['/v1/system/doctor']),
      ))!;
      var liveReads = 0;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/system/doctor') {
              await stall.read(request, api);
            } else if (request.uri.path == '/v1/system/live' &&
                ++liveReads == 2) {
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000009',
              );
              await _reply(request, {'live': false});
            } else {
              await _hostReply(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectHost(tester, api);
      await _untilSignal(tester, stall.arrived);
      await _hostUntil(tester, find.text('Live · true'));
      await _hostUntil(tester, find.text('Ready · true'));
      await _hostUntil(tester, find.text('API · v1'));
      expect(find.text('Doctor reported healthy'), findsNothing);
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh daemon liveness')),
      );
      await _hostUntil(tester, find.text('Live · false'));
      expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
      expect(liveReads, 2);
      expect(api.requests, hasLength(5));
      await tester.pumpWidget(const SizedBox.shrink());
      await _untilSignal(tester, stall.disconnected);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('host snapshots render on desktop with bundled typography', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(handler: _hostReply),
    ))!;
    addTearDown(api.close);
    const previewKey = Key('host-preview');
    await _connectHost(
      tester,
      api,
      app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
    );
    await _hostUntil(tester, find.text('Doctor reported healthy'));
    await _hostUntil(tester, find.text('API · v1'));
    await _hostUntil(tester, find.text('Ready · true'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(previewKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/ui-host-preview.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    expect(api.requests, hasLength(4));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

const _hostPaths = [
  '/v1/system/live',
  '/v1/system/ready',
  '/v1/system/capabilities',
  '/v1/system/doctor',
];

Future<void> _hostReply(HttpRequest request) async {
  expect(request.method, 'GET');
  expect(request.uri.query, isEmpty);
  expect(request.headers.value('Idempotency-Key'), isNull);
  final index = _hostPaths.indexOf(request.uri.path);
  expect(index, isNonNegative);
  request.response.headers.set(
    'X-Request-ID',
    'req_01J0000000000000000000000$index',
  );
  await _reply(request, switch (request.uri.path) {
    '/v1/system/live' => {'live': true},
    '/v1/system/ready' => {
      'ready': true,
      'checks': {'database': true},
    },
    '/v1/system/capabilities' => _hostCapabilities(),
    '/v1/system/doctor' => _hostDoctor(),
    _ => throw StateError('Unexpected host request'),
  });
}

Future<void> _hostProblem(HttpRequest request) async {
  request.response.statusCode = 404;
  request.response.headers.contentType = ContentType(
    'application',
    'problem+json',
  );
  request.response.write(
    jsonEncode({
      'type': 'https://gaovm.dev/problems/invalid-request',
      'title': 'Unknown public route',
      'status': 404,
      'code': 'INVALID_REQUEST',
      'detail': 'The configured daemon has no capabilities route.',
      'request_id': 'req_01J00000000000000000000009',
      'retryable': false,
      'operation_id': null,
      'details': {},
    }),
  );
  await request.response.close();
}

Map<String, Object?> _hostCapabilities() => {
  'api_version': 'v1',
  'backends': ['vz'],
  'guest': ['health', 'exec'],
  'limits': {
    'max_defined_vms': 128,
    'max_running_vms': 8,
    'max_concurrent_boots': 2,
  },
};

Map<String, Object?> _hostDoctor() => {
  'healthy': true,
  'checks': [
    {
      'name': 'runtime',
      'status': 'ok',
      'message': 'Driver inventory available.',
    },
    {
      'name': 'guest_profile',
      'status': 'warning',
      'message': 'GaoOS guest readiness is not verified.',
    },
  ],
};

Future<void> _connectHost(
  WidgetTester tester,
  _ApiFixture api, {
  Widget app = const GaoVmApp(),
}) async {
  await tester.pumpWidget(app);
  await tester.tap(find.widgetWithText(TextButton, 'Host status'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), api.socketPath);
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
}

Future<void> _hostUntil(WidgetTester tester, Finder visible) async {
  final elapsed = Stopwatch()..start();
  while (visible.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 3)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(visible, findsWidgets);
  // Other independent cards may still be reading; do not advance their deadline
  // by settling an indeterminate progress animation in the virtual-clock zone.
  await tester.pump();
}

class _HostStall {
  _HostStall({Iterable<String> expected = _hostPaths})
    : _expected = Set.unmodifiable(expected);
  final Set<String> _expected;
  final _received = <String>{};
  final closed = <String>{};
  final arrived = Completer<void>();
  final disconnected = Completer<void>();

  Future<void> read(HttpRequest request, _ApiFixture api) async {
    final path = request.uri.path;
    expect(_expected, contains(path));
    final socket = await request.response.detachSocket(writeHeaders: false);
    api.detached.add(socket);
    void markClosed() {
      closed.add(path);
      if (closed.containsAll(_expected) && !disconnected.isCompleted) {
        disconnected.complete();
      }
    }

    socket.listen(
      (_) {},
      onDone: markClosed,
      onError: (Object _) => markClosed(),
    );
    _received.add(path);
    if (_received.containsAll(_expected) && !arrived.isCompleted) {
      arrived.complete();
    }
  }
}
