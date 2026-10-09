part of 'catalog_test.dart';

void _operationHistoryTests() {
  testWidgets(
    'refreshing external detail exposes persisted request, deadline, and result',
    (tester) async {
      await _desktop(tester);
      final input = {'path': '/fixtures/rootfs.img', 'architecture': 'arm64'};
      final result = {'image_id': 'img_01J00000000000000000000000'};
      final snapshot = {
        ..._operation(type: 'image.import', key: 'cli-import'),
        'resource_type': 'image',
        'resource_id': 'img_01J00000000000000000000000',
        'request': input,
        'deadline_at': '2026-10-09T08:03:00Z',
        'cancellable': true,
      };
      var reads = 0;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [snapshot],
                'next_cursor': null,
              });
              return;
            }
            reads++;
            await _reply(request, {
              ...snapshot,
              'state': reads == 1 ? 'running' : 'succeeded',
              'cancellable': false,
              'progress': {
                'percent': reads == 1 ? 70 : 100,
                'step': reads == 1 ? 'Publishing files' : 'Import completed',
              },
              'result': reads == 1 ? null : result,
              'completed_at': reads == 1 ? null : '2026-10-09T08:01:00Z',
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('Publishing files'));
      expect(find.text('70%'), findsOneWidget);
      expect(find.text('Not cancellable'), findsOneWidget);
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh detail')),
      );
      await _until(tester, find.text('Import completed'));
      expect(find.text('100%'), findsOneWidget);
      final detailScroll = find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Deadline'),
        200,
        scrollable: detailScroll,
      );
      expect(find.text('2026-10-09T08:03:00.000Z'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Result'),
        200,
        scrollable: detailScroll,
      );
      await tester.tap(find.text('Result'));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(
          tester
              .widget<SelectableText>(
                find.ancestor(
                  of: find.textContaining('"image_id"'),
                  matching: find.byType(SelectableText),
                ),
              )
              .data!,
        ),
        result,
      );
      await tester.scrollUntilVisible(
        find.text('Original request'),
        200,
        scrollable: detailScroll,
      );
      await tester.tap(find.text('Original request'));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(
          tester
              .widget<SelectableText>(
                find.ancestor(
                  of: find.textContaining('"architecture"'),
                  matching: find.byType(SelectableText),
                ),
              )
              .data!,
        ),
        input,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'GET /v1/operations/op_01J00000000000000000000000',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop history and failed external detail render with bundled typography',
    (tester) async {
      await _desktop(tester);
      final failed = {
        ..._operation(
          id: 'op_01J00000000000000000000001',
          type: 'test.run',
          state: 'failed',
          key: 'cli-nightly',
          error: {
            'code': 'DRIVER_START_FAILED',
            'message': 'The VM driver did not start.',
            'retryable': false,
            'details': {'step': 'start', 'attempts': 5},
          },
        ),
        'resource_type': 'test_run',
        'resource_id': 'tr_01J00000000000000000000000',
        'request_id': 'req_01J00000000000000000000001',
      };
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/operations'
                ? {
                    'items': [
                      _operation(),
                      failed,
                      {
                        ..._operation(
                          id: 'op_01J00000000000000000000002',
                          type: 'image.import',
                          state: 'succeeded',
                          key: 'mcp-import',
                        ),
                        'resource_type': 'image',
                        'resource_id': 'img_01J00000000000000000000000',
                      },
                    ],
                    'next_cursor': null,
                  }
                : failed,
          ),
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('operation-preview');
      await tester.pumpWidget(
        const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Operations'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('op_01J00000000000000000000001'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000001')),
      );
      await _until(tester, find.text('DRIVER_START_FAILED'));
      expect(find.text('Operation · failed'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/ui-operations-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000001',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final target in [
    ('image', 'img_01J00000000000000000000000', 'image.import'),
    ('test_run', 'tr_01J00000000000000000000000', 'test.run'),
    ('artifact', 'art_01J00000000000000000000000', 'artifact.collect'),
    ('operation', 'op_01J00000000000000000000001', 'operation.cancel'),
  ]) {
    testWidgets(
      'history reads a ${target.$1} Operation without assuming a VM',
      (tester) async {
        await _desktop(tester);
        final operation = {
          ..._operation(type: target.$3, key: 'external-client'),
          'resource_type': target.$1,
          'resource_id': target.$2,
        };
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) => _reply(
              request,
              request.uri.path == '/v1/operations'
                  ? {
                      'items': [operation],
                      'next_cursor': null,
                    }
                  : {
                      ...operation,
                      'progress': {'step': 'Non-VM detail'},
                    },
            ),
          ),
        ))!;
        addTearDown(api.close);
        await _openOperations(tester, api);
        await _until(tester, find.text('op_01J00000000000000000000000'));
        await tester.runAsync(
          () async => tester.tap(find.text('op_01J00000000000000000000000')),
        );
        await _until(tester, find.text('Non-VM detail'));
        expect(find.text(target.$3), findsNWidgets(2));
        expect(find.text('Select a VM'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'empty Operation history is distinct from a disconnected console',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) =>
              _reply(request, {'items': [], 'next_cursor': null}),
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.tap(find.widgetWithText(TextButton, 'Operations'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to read Operation history'), findsOneWidget);
      expect(api.requests, isEmpty);
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('No Operations'));
      expect(find.text('Connect to read Operation history'), findsNothing);
      expect(find.text('Select an Operation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, ['GET /v1/operations']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    'extra key',
    'missing cursor',
    'empty cursor',
    'oversized cursor',
    'items type',
    'status',
  ]) {
    testWidgets(
      'history rejects an invalid $invalid response without displaying resources',
      (tester) async {
        await _desktop(tester);
        final page = <String, Object?>{
          'items': <Object>[_operation()],
          'next_cursor': null,
        };
        switch (invalid) {
          case 'extra key':
            page['unexpected'] = true;
          case 'missing cursor':
            page.remove('next_cursor');
          case 'empty cursor':
            page['next_cursor'] = '';
          case 'oversized cursor':
            page['next_cursor'] = List.filled(513, 'x').join();
          case 'items type':
            page['items'] = null;
        }
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (invalid == 'status') request.response.statusCode = 201;
              await _reply(request, page);
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openOperations(tester, api);
        await _until(tester, find.text('Invalid Operation history response.'));
        expect(find.text('vm.start'), findsNothing);
        expect(find.text('No Operations'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, ['GET /v1/operations']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a late external Operation detail cannot replace a newer selection',
    (tester) async {
      await _desktop(tester);
      final latches = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>(), Completer<void>()),
      ))!;
      final arrived = latches.$1;
      final release = latches.$2;
      final replied = latches.$3;
      final second = {
        ..._operation(
          id: 'op_01J00000000000000000000001',
          type: 'vm.stop',
          key: 'cli-second',
        ),
        'request_id': 'req_01J00000000000000000000001',
      };
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [_operation(), second],
                'next_cursor': null,
              });
            } else if (request.uri.path ==
                '/v1/operations/op_01J00000000000000000000000') {
              arrived.complete();
              await release.future;
              await _reply(request, {
                ..._operation(),
                'progress': {'step': 'Stale first intent'},
              });
              replied.complete();
            } else {
              await _reply(request, {
                ...second,
                'state': 'succeeded',
                'completed_at': '2026-10-09T08:01:00Z',
                'progress': {'step': 'Newest selected intent'},
              });
            }
          },
        ),
      ))!;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        return api.close();
      });
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(() async {
        await tester.tap(find.text('op_01J00000000000000000000000'));
        await arrived.future.timeout(const Duration(seconds: 3));
      });
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000001')),
      );
      await _until(tester, find.text('Newest selected intent'));
      await tester.runAsync(() async {
        release.complete();
        await replied.future.timeout(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();
      expect(find.text('Stale first intent'), findsNothing);
      expect(find.text('Operation · succeeded'), findsOneWidget);
      expect(find.text('op_01J00000000000000000000001'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'GET /v1/operations/op_01J00000000000000000000001',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final closeWindow in [true, false]) {
    testWidgets(
      closeWindow
          ? 'closing history releases a stalled detail read without commands'
          : 'leaving history releases a stalled detail read without commands',
      (tester) async {
        await _desktop(tester);
        final latches = (await tester.runAsync(
          () async => (Completer<void>(), Completer<void>()),
        ))!;
        final arrived = latches.$1;
        final disconnected = latches.$2;
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path == '/v1/operations' ||
                  request.uri.path == '/v1/vms') {
                await _reply(request, {
                  'items': request.uri.path == '/v1/vms'
                      ? [_vm()]
                      : [_operation()],
                  'next_cursor': null,
                });
                return;
              }
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              api.detached.add(socket);
              socket.listen(
                (_) {},
                onDone: () {
                  if (!disconnected.isCompleted) disconnected.complete();
                },
                onError: (Object _) {
                  if (!disconnected.isCompleted) disconnected.complete();
                },
              );
              arrived.complete();
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openOperations(tester, api);
        await _until(tester, find.text('op_01J00000000000000000000000'));
        await tester.runAsync(() async {
          await tester.tap(find.text('op_01J00000000000000000000000'));
          await arrived.future.timeout(const Duration(seconds: 3));
        });
        await tester.pump();
        if (closeWindow) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(
            () async =>
                tester.tap(find.widgetWithText(TextButton, 'Virtual machines')),
          );
          await _until(tester, find.text('gaoos-nightly-network'));
        }
        await tester.runAsync(
          () => disconnected.future.timeout(const Duration(seconds: 3)),
        );
        if (!closeWindow) await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
          if (!closeWindow) 'GET /v1/vms',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('closing a stalled history catalog releases its local socket', (
    tester,
  ) async {
    await _desktop(tester);
    final latches = (await tester.runAsync(
      () async => (Completer<void>(), Completer<void>()),
    ))!;
    final arrived = latches.$1;
    final disconnected = latches.$2;
    late _ApiFixture api;
    api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          api.detached.add(socket);
          socket.listen(
            (_) {},
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
            },
            onError: (Object _) {
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
          arrived.complete();
        },
      ),
    ))!;
    addTearDown(api.close);
    await _openOperations(tester, api);
    await tester.pump();
    await _untilSignal(tester, arrived);
    await tester.pumpWidget(const SizedBox.shrink());
    await _untilSignal(tester, disconnected);
    expect(api.requests, ['GET /v1/operations']);
    expect(tester.takeException(), isNull);
  });

  for (final field in [
    'id',
    'type',
    'resource_id',
    'resource_type',
    'request_id',
    'idempotency_key',
  ]) {
    testWidgets('external Operation detail rejects a mismatched $field', (
      tester,
    ) async {
      await _desktop(tester);
      final mismatch = switch (field) {
        'id' => {'id': 'op_01J00000000000000000000001'},
        'type' => {'type': 'vm.stop'},
        'resource_id' => {'resource_id': 'vm_01J00000000000000000000001'},
        'resource_type' => {
          'resource_type': 'image',
          'resource_id': 'img_01J00000000000000000000000',
        },
        'request_id' => {'request_id': 'req_01J00000000000000000000001'},
        _ => {'idempotency_key': 'different-client-intent'},
      };
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/operations'
                ? {
                    'items': [_operation(key: 'cli-intent')],
                    'next_cursor': null,
                  }
                : {
                    ..._operation(key: 'cli-intent', state: 'succeeded'),
                    ...mismatch,
                  },
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(
        tester,
        find.text('Operation detail identity disagrees with selection.'),
      );
      expect(find.text('Operation · succeeded'), findsNothing);
      expect(find.text('running'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
      ]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final invalid in ['cursor loop', 'duplicate ID']) {
    testWidgets('Operation paging rejects a $invalid without appending it', (
      tester,
    ) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              request.uri.queryParameters.containsKey('cursor') &&
                      invalid == 'cursor loop'
                  ? _operation(id: 'op_01J00000000000000000000001')
                  : _operation(),
            ],
            'next_cursor':
                request.uri.queryParameters.containsKey('cursor') &&
                    invalid == 'duplicate ID'
                ? null
                : 'cursor-one',
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(() async => tester.tap(find.text('Load more')));
      await _until(
        tester,
        find.text(
          invalid == 'cursor loop'
              ? 'Operation history repeated its cursor.'
              : 'Operation history repeated a resource ID.',
        ),
      );
      expect(find.text('op_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('op_01J00000000000000000000001'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, ['GET /v1/operations', 'GET /v1/operations']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'switching to Operations releases a stalled VM read without losing the connection',
    (tester) async {
      await _desktop(tester);
      final latches = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>()),
      ))!;
      final arrived = latches.$1;
      final disconnected = latches.$2;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path != '/v1/vms') {
              await _reply(request, {
                'items': [_operation()],
                'next_cursor': null,
              });
              return;
            }
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            api.detached.add(socket);
            socket.listen(
              (_) {},
              onDone: () {
                if (!disconnected.isCompleted) disconnected.complete();
              },
              onError: (Object _) {
                if (!disconnected.isCompleted) disconnected.complete();
              },
            );
            arrived.complete();
          },
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async {
        await tester.tap(find.text('Connect'));
        await arrived.future.timeout(const Duration(seconds: 3));
      });
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Operations')),
      );
      await tester.pump();
      await tester.runAsync(
        () => disconnected.future.timeout(const Duration(seconds: 3)),
      );
      await _until(tester, find.text('op_01J00000000000000000000000'));
      expect(find.text('Select an Operation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, ['GET /v1/vms', 'GET /v1/operations']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning from Operations loads VMs on the configured connection',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/vms'
                ? {
                    'items': [_vm()],
                    'next_cursor': null,
                  }
                : {
                    'items': [_operation()],
                    'next_cursor': null,
                  },
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(
        () async =>
            tester.tap(find.widgetWithText(TextButton, 'Virtual machines')),
      );
      await _until(tester, find.text('gaoos-nightly-network'));
      expect(find.text('Select a VM'), findsOneWidget);
      expect(find.text('op_01J00000000000000000000000'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, ['GET /v1/operations', 'GET /v1/vms']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed history read is not an empty successful history', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType(
            'application',
            'problem+json',
          );
          request.response.write(
            jsonEncode({
              'type': 'https://gaovm.dev/problems/internal-error',
              'title': 'History unavailable',
              'status': 503,
              'code': 'INTERNAL_ERROR',
              'detail': 'The shared history cannot be read.',
              'request_id': 'req_01J00000000000000000000001',
              'retryable': true,
              'operation_id': null,
              'details': {},
            }),
          );
          await request.response.close();
        },
      ),
    ))!;
    addTearDown(api.close);
    await _openOperations(tester, api);
    await _until(tester, find.text('INTERNAL_ERROR'));
    expect(find.text('History unavailable'), findsOneWidget);
    expect(find.text('req_01J00000000000000000000001'), findsOneWidget);
    expect(find.text('Retryable'), findsOneWidget);
    expect(find.text('No Operations'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(api.requests, ['GET /v1/operations']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an external Operation read problem retains structured metadata',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [_operation(key: 'cli-intent')],
                'next_cursor': null,
              });
              return;
            }
            request.response.statusCode = 404;
            request.response.headers.contentType = ContentType(
              'application',
              'problem+json',
            );
            request.response.write(
              jsonEncode({
                'type': 'https://gaovm.dev/problems/operation-not-found',
                'title': 'Operation unavailable',
                'status': 404,
                'code': 'OPERATION_NOT_FOUND',
                'detail': 'History detail is no longer available.',
                'request_id': 'req_01J00000000000000000000001',
                'retryable': false,
                'operation_id': 'op_01J00000000000000000000000',
                'details': {},
              }),
            );
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('OPERATION_NOT_FOUND'));
      expect(find.text('Operation unavailable'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000001'), findsOneWidget);
      expect(find.text('Not retryable'), findsOneWidget);
      expect(find.text('Operation · failed'), findsNothing);
      expect(find.text('No Operations'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Operation paging preserves the opaque cursor, connection, and selection',
    (tester) async {
      await _desktop(tester);
      const cursor = 'opaque+/==?after=42%raw';
      final cursors = <String?>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.uri.path != '/v1/operations') {
              await _reply(request, {
                ..._operation(),
                'progress': {'step': 'Selected snapshot'},
              });
              return;
            }
            final received = request.uri.queryParameters['cursor'];
            cursors.add(received);
            await _reply(request, {
              'items': [
                received == null
                    ? _operation()
                    : {
                        ..._operation(
                          id: 'op_01J00000000000000000000001',
                          type: 'vm.stop',
                        ),
                        'request_id': 'req_01J00000000000000000000001',
                      },
              ],
              'next_cursor': received == null ? cursor : null,
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openOperations(tester, api);
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('Selected snapshot'));
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(() async => tester.tap(find.text('Load more')));
      await _until(tester, find.text('op_01J00000000000000000000001'));
      expect(find.text('op_01J00000000000000000000000'), findsNWidgets(2));
      expect(find.text('Selected snapshot'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      expect(cursors, [null, cursor]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'GET /v1/operations',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connecting from Operations reads history without a VM catalog request',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              {
                ..._operation(type: 'image.import', key: 'cli-import'),
                'resource_type': 'image',
                'resource_id': 'img_01J00000000000000000000000',
              },
            ],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.tap(find.widgetWithText(TextButton, 'Operations'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('image.import'));
      expect(find.text('img_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('Select an Operation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, ['GET /v1/operations']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Operation history lists other-client intents without implicit selection',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/vms'
                ? {
                    'items': [_vm()],
                    'next_cursor': null,
                  }
                : {
                    'items': [_operation(key: 'cli-history')],
                    'next_cursor': null,
                  },
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _connect(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Operations')),
      );
      await _until(tester, find.text('op_01J00000000000000000000000'));
      expect(find.text('vm.start'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('vm_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('Select an Operation'), findsOneWidget);
      expect(api.requests, ['GET /v1/vms', 'GET /v1/operations']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('selecting another client Operation fetches fresh detail', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _reply(
          request,
          request.uri.path == '/v1/vms'
              ? {
                  'items': [_vm()],
                  'next_cursor': null,
                }
              : request.uri.path == '/v1/operations'
              ? {
                  'items': [_operation()],
                  'next_cursor': null,
                }
              : {
                  ..._operation(state: 'succeeded'),
                  'progress': {
                    'percent': 100,
                    'step': 'External intent completed',
                  },
                  'result': {'driver_generation': 9},
                },
        ),
      ),
    ))!;
    addTearDown(api.close);
    await _connect(tester, api);
    await tester.runAsync(
      () async => tester.tap(find.widgetWithText(TextButton, 'Operations')),
    );
    await _until(tester, find.text('op_01J00000000000000000000000'));
    await tester.runAsync(
      () async => tester.tap(find.text('op_01J00000000000000000000000')),
    );
    await _until(tester, find.text('Operation · succeeded'));
    expect(find.text('External intent completed'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('req_01J00000000000000000000000'), findsOneWidget);
    expect(find.text('Not cancellable'), findsOneWidget);
    expect(
      find.text('running'),
      findsOneWidget,
    ); // Older history snapshot only.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(api.requests, [
      'GET /v1/vms',
      'GET /v1/operations',
      'GET /v1/operations/op_01J00000000000000000000000',
    ]);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openOperations(WidgetTester tester, _ApiFixture api) async {
  await tester.pumpWidget(const GaoVmApp());
  await tester.tap(find.widgetWithText(TextButton, 'Operations'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), api.socketPath);
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
}

Future<void> _untilSignal(WidgetTester tester, Completer<void> signal) async {
  final elapsed = Stopwatch()..start();
  // initState starts reads in the widget zone. Drain its microtasks between
  // real-I/O turns; a single runAsync wait cannot drive that zone.
  while (!signal.isCompleted && elapsed.elapsed < const Duration(seconds: 3)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(signal.isCompleted, isTrue);
  await tester.runAsync(() => signal.future);
}
