part of 'catalog_test.dart';

void _operationCancellationTests() {
  testWidgets(
    'cancellation receipts are scoped to the configured socket as well as target ID',
    (tester) async {
      await _desktop(tester);
      String? firstKey;
      String? secondKey;
      final firstTarget = _cancellableImport();
      final secondTarget = {
        ...firstTarget,
        'progress': {'step': 'Importing on another daemon'},
      };
      late _ApiFixture first;
      first = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              firstKey = request.headers.value('Idempotency-Key');
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              first.detached.add(socket);
              socket.destroy();
            } else {
              await _reply(
                request,
                request.uri.path == '/v1/operations'
                    ? {
                        'items': [firstTarget],
                        'next_cursor': null,
                      }
                    : firstTarget,
              );
            }
          },
        ),
      ))!;
      addTearDown(first.close);
      final second = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              secondKey = request.headers.value('Idempotency-Key');
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else {
              await _reply(
                request,
                request.uri.path == '/v1/operations'
                    ? {
                        'items': [secondTarget],
                        'next_cursor': null,
                      }
                    : secondTarget,
              );
            }
          },
        ),
      ))!;
      addTearDown(second.close);
      await _openCancellableImport(tester, first);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation outcome unknown'));
      await tester.enterText(find.byType(TextField), second.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await tester.pump();
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('Importing on another daemon'));
      expect(find.text('Cancellation outcome unknown'), findsNothing);
      expect(find.text('Retry cancellation'), findsNothing);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      expect(firstKey, isNotNull);
      expect(secondKey, isNotNull);
      expect(secondKey, isNot(firstKey));
      await tester.pumpWidget(const SizedBox.shrink());
      for (final api in [first, second]) {
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
          'POST /v1/operations/op_01J00000000000000000000000/cancel',
        ]);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancellation tracking keeps its original request ID after the first read',
    (tester) async {
      await _desktop(tester);
      String? key;
      var reads = 0;
      final target = _cancellableImport();
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              key = request.headers.value('Idempotency-Key');
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target],
                'next_cursor': null,
              });
            } else if (request.uri.path ==
                '/v1/operations/op_01J00000000000000000000001') {
              reads++;
              await _reply(request, {
                ..._cancellationAction(
                  key: key,
                  state: reads == 1 ? 'running' : 'succeeded',
                ),
                if (reads > 1) 'request_id': 'req_01J00000000000000000000003',
              });
            } else {
              await _reply(request, target);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openCancellableImport(tester, api);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Cancellation · running'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(
        tester,
        find.text(
          'Cancellation Operation identity disagrees with its receipt.',
        ),
      );
      expect(find.text('req_01J00000000000000000000002'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000003'), findsNothing);
      expect(find.text('Cancellation · running'), findsOneWidget);
      expect(find.text('Cancellation · succeeded'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        api.requests.where(
          (path) => path == 'GET /v1/operations/op_01J00000000000000000000000',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late cancellation completion cannot refresh a different selected Operation',
    (tester) async {
      await _desktop(tester);
      final latches = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>(), Completer<void>()),
      ))!;
      final arrived = latches.$1;
      final release = latches.$2;
      final replied = latches.$3;
      String? key;
      final target = _cancellableImport();
      final other = {
        ...target,
        'id': 'op_01J00000000000000000000002',
        'resource_id': 'img_01J00000000000000000000001',
        'request_id': 'req_01J00000000000000000000003',
        'progress': {'step': 'Another selected Operation'},
      };
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              key = request.headers.value('Idempotency-Key');
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target, other],
                'next_cursor': null,
              });
            } else if (request.uri.path ==
                '/v1/operations/op_01J00000000000000000000001') {
              arrived.complete();
              await release.future;
              await _reply(
                request,
                _cancellationAction(key: key, state: 'succeeded'),
              );
              replied.complete();
            } else {
              await _reply(
                request,
                request.uri.path ==
                        '/v1/operations/op_01J00000000000000000000002'
                    ? other
                    : target,
              );
            }
          },
        ),
      ))!;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        return api.close();
      });
      await _openCancellableImport(tester, api);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Refresh cancellation'));
        await arrived.future.timeout(const Duration(seconds: 3));
      });
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000002')),
      );
      await _until(tester, find.text('Another selected Operation'));
      await tester.runAsync(() async {
        release.complete();
        await replied.future.timeout(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();
      expect(find.text('Cancellation · succeeded'), findsNothing);
      expect(find.text('Another selected Operation'), findsOneWidget);
      expect(find.text('Cancellation accepted · pending'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
        'GET /v1/operations/op_01J00000000000000000000001',
        'GET /v1/operations/op_01J00000000000000000000002',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop cancellation receipt renders separately from the target snapshot',
    (tester) async {
      await _desktop(tester);
      String? key;
      final target = _cancellableImport();
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              key = request.headers.value('Idempotency-Key');
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target],
                'next_cursor': null,
              });
            } else {
              await _reply(
                request,
                request.uri.path ==
                        '/v1/operations/op_01J00000000000000000000001'
                    ? _cancellationAction(key: key)
                    : target,
              );
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('cancellation-preview');
      await tester.pumpWidget(
        const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Operations'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('Importing image'));
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Cancellation · running'));
      expect(find.text('Operation · running'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/ui-cancellation-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        api.requests.where((path) => path.startsWith('POST')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final phase in [
    'pending',
    'running',
    'succeeded',
    'failed',
    'cancelled',
  ]) {
    testWidgets(
      'a freshly noncancellable $phase target cannot submit cancellation',
      (tester) async {
        await _desktop(tester);
        final snapshot = _cancellableImport();
        final detail = {
          ...snapshot,
          'state': phase,
          'cancellable': false,
          'completed_at': ['succeeded', 'failed', 'cancelled'].contains(phase)
              ? '2026-10-09T08:02:00Z'
              : null,
        };
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) => _reply(
              request,
              request.uri.path == '/v1/operations'
                  ? {
                      'items': [snapshot],
                      'next_cursor': null,
                    }
                  : detail,
            ),
          ),
        ))!;
        addTearDown(api.close);
        await _openCancellableImport(tester, api);
        expect(find.text('Not cancellable'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Request cancellation'),
              )
              .onPressed,
          isNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final stage in ['request', 'read']) {
    testWidgets(
      'cancellation $stage problems retain the receipt boundary and structured metadata',
      (tester) async {
        await _desktop(tester);
        String? key;
        final target = _cancellableImport();
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              final problem =
                  stage == 'request' && request.method == 'POST' ||
                  stage == 'read' &&
                      request.uri.path ==
                          '/v1/operations/op_01J00000000000000000000001';
              if (problem) {
                request.response.statusCode = stage == 'request' ? 409 : 404;
                request.response.headers.contentType = ContentType(
                  'application',
                  'problem+json',
                );
                request.response.write(
                  jsonEncode({
                    'type':
                        'https://gaovm.dev/problems/${stage == 'request' ? 'operation-not-cancellable' : 'operation-not-found'}',
                    'title': stage == 'request'
                        ? 'Cancellation refused'
                        : 'Cancellation receipt unavailable',
                    'status': stage == 'request' ? 409 : 404,
                    'code': stage == 'request'
                        ? 'OPERATION_NOT_CANCELLABLE'
                        : 'OPERATION_NOT_FOUND',
                    'detail':
                        'The daemon decides the current cancellation boundary.',
                    'request_id': 'req_01J00000000000000000000003',
                    'retryable': false,
                    'operation_id': target['id'],
                    'details': {},
                  }),
                );
                await request.response.close();
              } else if (request.method == 'POST') {
                key = request.headers.value('Idempotency-Key');
                request.response.statusCode = 202;
                await _reply(request, _cancellationAcceptance());
              } else {
                await _reply(
                  request,
                  request.uri.path == '/v1/operations'
                      ? {
                          'items': [target],
                          'next_cursor': null,
                        }
                      : target,
                );
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openCancellableImport(tester, api);
        await _confirmCancellation(tester);
        if (stage == 'read') {
          await _until(tester, find.text('Cancellation accepted · pending'));
          expect(key, isNotNull);
          await tester.runAsync(
            () async => tester.tap(find.text('Refresh cancellation')),
          );
        }
        await _until(
          tester,
          find.text(
            stage == 'request'
                ? 'OPERATION_NOT_CANCELLABLE'
                : 'OPERATION_NOT_FOUND',
          ),
        );
        expect(find.text('req_01J00000000000000000000003'), findsOneWidget);
        expect(find.text('Not retryable'), findsOneWidget);
        expect(find.text('Cancellation outcome unknown'), findsNothing);
        expect(find.text('Operation · running'), findsOneWidget);
        expect(find.text('Operation · cancelled'), findsNothing);
        expect(
          find.text('Cancellation accepted · pending'),
          stage == 'read' ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
          'POST /v1/operations/op_01J00000000000000000000000/cancel',
          if (stage == 'read')
            'GET /v1/operations/op_01J00000000000000000000001',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final stage in ['submission', 'observation']) {
    for (final closeWindow in [true, false]) {
      testWidgets(
        '${closeWindow ? 'closing' : 'leaving'} a stalled cancellation $stage releases only the local socket',
        (tester) async {
          await _desktop(tester);
          final latches = (await tester.runAsync(
            () async => (Completer<void>(), Completer<void>()),
          ))!;
          final arrived = latches.$1;
          final disconnected = latches.$2;
          final target = _cancellableImport();
          late _ApiFixture api;
          api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                final stall =
                    stage == 'submission' && request.method == 'POST' ||
                    stage == 'observation' &&
                        request.uri.path ==
                            '/v1/operations/op_01J00000000000000000000001';
                if (stall) {
                  await request.drain<void>();
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
                } else if (request.method == 'POST') {
                  request.response.statusCode = 202;
                  await _reply(request, _cancellationAcceptance());
                } else {
                  await _reply(
                    request,
                    request.uri.path == '/v1/operations'
                        ? {
                            'items': [target],
                            'next_cursor': null,
                          }
                        : request.uri.path == '/v1/vms'
                        ? {'items': [], 'next_cursor': null}
                        : target,
                  );
                }
              },
            ),
          ))!;
          addTearDown(api.close);
          await _openCancellableImport(tester, api);
          await _confirmCancellation(tester);
          if (stage == 'observation') {
            await _until(tester, find.text('Cancellation accepted · pending'));
            await tester.runAsync(
              () async => tester.tap(find.text('Refresh cancellation')),
            );
          }
          await _untilSignal(tester, arrived);
          if (closeWindow) {
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            await tester.runAsync(
              () async => tester.tap(
                find.widgetWithText(TextButton, 'Virtual machines'),
              ),
            );
            await _until(tester, find.text('No virtual machines'));
          }
          await _untilSignal(tester, disconnected);
          if (!closeWindow) await tester.pumpWidget(const SizedBox.shrink());
          expect(api.requests, [
            'GET /v1/operations',
            'GET /v1/operations/op_01J00000000000000000000000',
            'POST /v1/operations/op_01J00000000000000000000000/cancel',
            if (stage == 'observation')
              'GET /v1/operations/op_01J00000000000000000000001',
            if (!closeWindow) 'GET /v1/vms',
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'lost cancellation replay keeps its key after pane changes and target completion',
    (tester) async {
      await _desktop(tester);
      final keys = <String?>[];
      final bodies = <Object?>[];
      final target = _cancellableImport();
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
              if (keys.length == 1) {
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                api.detached.add(socket);
                socket.destroy();
                return;
              }
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else if (request.uri.path == '/v1/vms') {
              await _reply(request, {'items': [], 'next_cursor': null});
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target],
                'next_cursor': null,
              });
            } else {
              await _reply(request, {
                ...target,
                if (keys.isNotEmpty) ...{
                  'state': 'cancelled',
                  'cancellable': false,
                  'completed_at': '2026-10-09T08:02:00Z',
                },
              });
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openCancellableImport(tester, api);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation outcome unknown'));
      await tester.runAsync(
        () async =>
            tester.tap(find.widgetWithText(TextButton, 'Virtual machines')),
      );
      await _until(tester, find.text('No virtual machines'));
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Operations')),
      );
      await _until(tester, find.text('op_01J00000000000000000000000'));
      await tester.runAsync(
        () async => tester.tap(find.text('op_01J00000000000000000000000')),
      );
      await _until(tester, find.text('Operation · cancelled'));
      await tester.runAsync(
        () async => tester.tap(find.text('Retry cancellation')),
      );
      await _until(tester, find.text('Cancellation accepted · pending'));
      expect(keys, hasLength(2));
      expect(keys[0], matches(RegExp(r'^ui-[0-9a-f]{32}$')));
      expect(keys[1], keys[0]);
      expect(bodies, [<String, Object?>{}, <String, Object?>{}]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Operation · cancelled'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests.where((path) => path.startsWith('POST')), [
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    'status',
    'extra key',
    'target',
    'resource type',
    'state',
    'id',
    'same id',
  ]) {
    testWidgets(
      'cancellation rejects an invalid $invalid acceptance without guessing an outcome',
      (tester) async {
        await _desktop(tester);
        final target = _cancellableImport();
        final ack = _cancellationAcceptance();
        switch (invalid) {
          case 'extra key':
            ack['unexpected'] = true;
          case 'target':
            ack['resource_id'] = 'op_01J00000000000000000000002';
          case 'resource type':
            ack['resource_type'] = 'image';
            ack['resource_id'] = target['resource_id'];
          case 'state':
            ack['state'] = 'cancelled';
          case 'id':
            ack['operation_id'] = 'not-an-operation-id';
          case 'same id':
            ack['operation_id'] = target['id'];
        }
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'POST') {
                request.response.statusCode = invalid == 'status' ? 200 : 202;
                await _reply(request, ack);
              } else {
                await _reply(
                  request,
                  request.uri.path == '/v1/operations'
                      ? {
                          'items': [target],
                          'next_cursor': null,
                        }
                      : target,
                );
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openCancellableImport(tester, api);
        await _confirmCancellation(tester);
        await _until(tester, find.text('Cancellation outcome unknown'));
        expect(find.text('Cancellation accepted · pending'), findsNothing);
        expect(find.text('Refresh cancellation'), findsNothing);
        expect(find.text('Operation · running'), findsOneWidget);
        expect(find.text('Operation · cancelled'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
          'POST /v1/operations/op_01J00000000000000000000000/cancel',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final field in [
    'id',
    'type',
    'resource_id',
    'resource_type',
    'idempotency_key',
  ]) {
    testWidgets(
      'cancellation tracking rejects a mismatched $field without refreshing the target',
      (tester) async {
        await _desktop(tester);
        String? key;
        final target = _cancellableImport();
        final mismatch = switch (field) {
          'id' => {'id': 'op_01J00000000000000000000002'},
          'type' => {'type': 'test.cancel'},
          'resource_id' => {'resource_id': 'op_01J00000000000000000000002'},
          'resource_type' => {
            'resource_type': 'image',
            'resource_id': 'img_01J00000000000000000000000',
          },
          _ => {'idempotency_key': 'another-client-intent'},
        };
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'POST') {
                key = request.headers.value('Idempotency-Key');
                request.response.statusCode = 202;
                await _reply(request, _cancellationAcceptance());
              } else if (request.uri.path == '/v1/operations') {
                await _reply(request, {
                  'items': [target],
                  'next_cursor': null,
                });
              } else if (request.uri.path ==
                  '/v1/operations/op_01J00000000000000000000001') {
                await _reply(request, {
                  ..._cancellationAction(key: key, state: 'succeeded'),
                  ...mismatch,
                });
              } else {
                await _reply(request, target);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _openCancellableImport(tester, api);
        await _confirmCancellation(tester);
        await _until(tester, find.text('Cancellation accepted · pending'));
        await tester.runAsync(
          () async => tester.tap(find.text('Refresh cancellation')),
        );
        await _until(
          tester,
          find.text(
            'Cancellation Operation identity disagrees with its receipt.',
          ),
        );
        expect(find.text('Cancellation accepted · pending'), findsOneWidget);
        expect(find.text('Cancellation · succeeded'), findsNothing);
        expect(find.text('Operation · running'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, [
          'GET /v1/operations',
          'GET /v1/operations/op_01J00000000000000000000000',
          'POST /v1/operations/op_01J00000000000000000000000/cancel',
          'GET /v1/operations/op_01J00000000000000000000001',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a new cancellation after terminal failure is a new confirmed intent',
    (tester) async {
      await _desktop(tester);
      final keys = <String?>[];
      final target = _cancellableImport();
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              request.response.statusCode = 202;
              await _reply(request, {
                ..._cancellationAcceptance(),
                if (keys.length > 1)
                  'operation_id': 'op_01J00000000000000000000002',
              });
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target],
                'next_cursor': null,
              });
            } else if (request.uri.path ==
                '/v1/operations/op_01J00000000000000000000001') {
              await _reply(request, {
                ..._cancellationAction(key: keys.single, state: 'failed'),
                'error': {
                  'code': 'INTERNAL_ERROR',
                  'message': 'Cleanup did not finish.',
                  'retryable': true,
                  'details': {},
                },
              });
            } else {
              await _reply(request, target);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openCancellableImport(tester, api);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Cancellation · failed'));
      expect(find.text('INTERNAL_ERROR'), findsOneWidget);
      expect(find.text('Operation · running'), findsOneWidget);
      await tester.tap(find.text('Request cancellation again'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep running'));
      await tester.pumpAndSettle();
      expect(keys, hasLength(1));
      await tester.tap(find.text('Request cancellation again'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => tester.tap(find.text('Cancel Operation')),
      );
      await _until(tester, find.text('op_01J00000000000000000000002'));
      expect(keys, hasLength(2));
      expect(keys[1], isNot(keys[0]));
      expect(keys[1], matches(RegExp(r'^ui-[0-9a-f]{32}$')));
      expect(find.text('Operation · running'), findsOneWidget);
      expect(find.text('Cancellation · failed'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests.where((path) => path.startsWith('POST')), [
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancellation completion reads the target instead of guessing it is cancelled',
    (tester) async {
      await _desktop(tester);
      String? key;
      var targetReads = 0;
      var cancellationReads = 0;
      final target = _cancellableImport();
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              key = request.headers.value('Idempotency-Key');
              request.response.statusCode = 202;
              await _reply(request, _cancellationAcceptance());
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {
                'items': [target],
                'next_cursor': null,
              });
            } else if (request.uri.path ==
                '/v1/operations/op_01J00000000000000000000001') {
              cancellationReads++;
              await _reply(
                request,
                _cancellationAction(
                  key: key,
                  state: cancellationReads == 1 ? 'running' : 'succeeded',
                ),
              );
            } else {
              targetReads++;
              await _reply(request, {
                ...target,
                if (targetReads >= 3) ...{
                  'state': 'cancelled',
                  'cancellable': false,
                  'completed_at': '2026-10-09T08:02:00Z',
                },
              });
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openCancellableImport(tester, api);
      await _confirmCancellation(tester);
      await _until(tester, find.text('Cancellation accepted · pending'));
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Cancellation · running'));
      expect(find.text('Cleaning up image files'), findsOneWidget);
      expect(targetReads, 1);
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Cancellation · succeeded'));
      expect(targetReads, 2);
      expect(find.text('Operation · running'), findsOneWidget);
      expect(find.text('Operation · cancelled'), findsNothing);
      await tester.runAsync(
        () async => tester.tap(find.text('Refresh cancellation')),
      );
      await _until(tester, find.text('Operation · cancelled'));
      expect(targetReads, 3);
      expect(find.text('Not cancellable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
        'GET /v1/operations/op_01J00000000000000000000001',
        'GET /v1/operations/op_01J00000000000000000000001',
        'GET /v1/operations/op_01J00000000000000000000000',
        'GET /v1/operations/op_01J00000000000000000000001',
        'GET /v1/operations/op_01J00000000000000000000000',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Operation cancellation requires confirmation and preserves observed target state',
    (tester) async {
      await _desktop(tester);
      final keys = <String?>[];
      final bodies = <Object?>[];
      final target = _cancellableImport();
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
              request.response.statusCode = 202;
              await _reply(request, {
                'operation_id': 'op_01J00000000000000000000001',
                'state': 'pending',
                'resource_type': 'operation',
                'resource_id': target['id'],
              });
              return;
            }
            await _reply(
              request,
              request.uri.path == '/v1/operations'
                  ? {
                      'items': [target],
                      'next_cursor': null,
                    }
                  : target,
            );
          },
        ),
      ))!;
      addTearDown(api.close);
      await _openCancellableImport(tester, api);
      await tester.tap(find.text('Request cancellation'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this Operation?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(
            SelectableText,
            'op_01J00000000000000000000000',
          ),
        ),
        findsOneWidget,
      );
      expect(keys, isEmpty);
      await tester.tap(find.text('Keep running'));
      await tester.pumpAndSettle();
      expect(keys, isEmpty);
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.tap(find.text('Request cancellation'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => tester.tap(find.text('Cancel Operation')),
      );
      await _until(tester, find.text('Cancellation accepted · pending'));
      expect(keys, [matches(RegExp(r'^ui-[0-9a-f]{32}$'))]);
      expect(bodies, [<String, Object?>{}]);
      expect(find.text('Operation · running'), findsOneWidget);
      expect(find.text('Operation · cancelled'), findsNothing);
      expect(find.text('op_01J00000000000000000000001'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Request cancellation'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/operations',
        'GET /v1/operations/op_01J00000000000000000000000',
        'POST /v1/operations/op_01J00000000000000000000000/cancel',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

Map<String, Object?> _cancellationAcceptance() => {
  'operation_id': 'op_01J00000000000000000000001',
  'state': 'pending',
  'resource_type': 'operation',
  'resource_id': 'op_01J00000000000000000000000',
};

Map<String, Object?> _cancellationAction({
  String? key,
  String state = 'running',
}) => {
  ..._operation(
    id: 'op_01J00000000000000000000001',
    type: 'operation.cancel',
    state: state,
    key: key,
  ),
  'resource_type': 'operation',
  'resource_id': 'op_01J00000000000000000000000',
  'request_id': 'req_01J00000000000000000000002',
  'progress': {
    'percent': state == 'running' ? 60 : 100,
    'step': state == 'running'
        ? 'Cleaning up image files'
        : 'Cleanup completed',
  },
};

Future<void> _confirmCancellation(WidgetTester tester) async {
  await tester.tap(find.text('Request cancellation'));
  await tester.pumpAndSettle();
  await tester.runAsync(() async => tester.tap(find.text('Cancel Operation')));
}

Map<String, Object?> _cancellableImport() => {
  ..._operation(type: 'image.import', key: 'cli-image-import'),
  'resource_type': 'image',
  'resource_id': 'img_01J00000000000000000000000',
  'cancellable': true,
  'progress': {'percent': 30, 'step': 'Importing image'},
};

Future<void> _openCancellableImport(
  WidgetTester tester,
  _ApiFixture api,
) async {
  await _openOperations(tester, api);
  await _until(tester, find.text('op_01J00000000000000000000000'));
  await tester.runAsync(
    () async => tester.tap(find.text('op_01J00000000000000000000000')),
  );
  await _until(tester, find.text('Importing image'));
}
