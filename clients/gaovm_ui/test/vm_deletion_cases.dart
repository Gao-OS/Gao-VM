part of 'catalog_test.dart';

void _vmDeletionTests() {
  for (final exit in ['close', 'Connect']) {
    testWidgets(
      'VM deletion $exit releases a stalled submission without a daemon command',
      (tester) async {
        await _deletionDesktop(tester);
        final stall = (await tester.runAsync(
          () async => _HostStall(expected: ['/v1/vms/$_deletionVmId']),
        ))!;
        final keys = <String>[];
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'DELETE') {
                keys.add(request.headers.value('Idempotency-Key')!);
                if (keys.length == 1) {
                  await stall.read(request, api);
                } else {
                  await _deleteAccepted(request);
                }
              } else {
                await _deletionCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        await _untilSignal(tester, stall.arrived);
        if (exit == 'close') {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(() async => tester.tap(find.text('Connect')));
        }
        await _untilSignal(tester, stall.disconnected);
        expect(keys, hasLength(1));
        if (exit == 'Connect') {
          await _hostUntil(tester, find.text('revision 7'));
          await _hostUntil(tester, find.text('Deletion outcome unknown'));
          await tester.ensureVisible(find.text('Replay deletion'));
          await tester.pump();
          await tester.runAsync(
            () async => tester.tap(find.text('Replay deletion')),
          );
          await _hostUntil(tester, find.text('Deletion accepted · pending'));
          expect(keys, hasLength(2));
          expect(keys.toSet(), hasLength(1));
        }
        expect(
          api.requests.any((request) => request.startsWith('POST ')),
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final exit in ['close', 'Operations', 'Connect']) {
    testWidgets(
      'VM deletion $exit releases a stalled Operation read without cancelling deletion',
      (tester) async {
        await _deletionDesktop(tester);
        final stall = (await tester.runAsync(
          () async =>
              _HostStall(expected: ['/v1/operations/$_deletionOperationId']),
        ))!;
        String? key;
        var reads = 0;
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'DELETE') {
                key = request.headers.value('Idempotency-Key');
                await _deleteAccepted(request);
              } else if (request.uri.path.startsWith('/v1/operations/')) {
                reads++;
                if (reads == 1) {
                  await stall.read(request, api);
                } else {
                  request.response.headers.set(
                    'X-Request-ID',
                    'req_01J00000000000000000000008',
                  );
                  await _reply(request, _deleteOperation(key: key!));
                }
              } else if (request.uri.path == '/v1/operations') {
                await _reply(request, {'items': [], 'next_cursor': null});
              } else {
                await _deletionCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        await _hostUntil(tester, find.text('Deletion accepted · pending'));
        await _refreshDeletion(tester);
        await _untilSignal(tester, stall.arrived);
        if (exit == 'close') {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(
            () async => tester.tap(
              find.widgetWithText(
                exit == 'Connect' ? FilledButton : TextButton,
                exit,
              ),
            ),
          );
        }
        await _untilSignal(tester, stall.disconnected);
        if (exit == 'Operations') {
          await _hostUntil(tester, find.text('No Operations'));
          await tester.runAsync(
            () async =>
                tester.tap(find.widgetWithText(TextButton, 'Virtual machines')),
          );
        }
        if (exit != 'close') {
          await _hostUntil(tester, find.text('revision 7'));
          expect(find.text('Deletion accepted · pending'), findsOneWidget);
          expect(find.text('Deletion outcome unknown'), findsNothing);
          await _refreshDeletion(tester);
          await _hostUntil(tester, find.text('Deletion Operation · running'));
          expect(reads, 2);
        }
        expect(
          api.requests.where((request) => request.startsWith('DELETE ')),
          hasLength(1),
        );
        expect(
          api.requests.any(
            (request) =>
                request.contains('/cancel') || request.contains('/actions/'),
          ),
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'VM deletion receipts are scoped by socket even for the same public VM ID',
    (tester) async {
      await _deletionDesktop(tester);
      final keys = <String>[];
      Future<void> handler(HttpRequest request) async {
        if (request.method == 'DELETE') {
          keys.add(request.headers.value('Idempotency-Key')!);
          await _deleteAccepted(request);
        } else {
          await _deletionCatalog(request);
        }
      }

      final first = (await tester.runAsync(
        () => _ApiFixture.open(handler: handler),
      ))!;
      final second = (await tester.runAsync(
        () => _ApiFixture.open(handler: handler),
      ))!;
      addTearDown(first.close);
      addTearDown(second.close);
      await _connectDeletion(tester, first);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await tester.enterText(find.byType(TextField), second.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await tester.pump();
      await _hostUntil(tester, find.text('revision 7'));
      expect(find.text('DELETION INTENT'), findsNothing);
      await _selectDeletionVm(tester, 'gaoos-nightly-network');
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(2));
      await tester.enterText(find.byType(TextField), first.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _hostUntil(tester, find.text('revision 7'));
      expect(find.text('Deletion accepted · pending'), findsOneWidget);
      expect(
        first.requests.where((request) => request.startsWith('DELETE ')),
        hasLength(1),
      );
      expect(
        second.requests.where((request) => request.startsWith('DELETE ')),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion after a verified failure requires a new confirmed intent and key',
    (tester) async {
      await _deletionDesktop(tester);
      final keys = <String>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              keys.add(request.headers.value('Idempotency-Key')!);
              await _deleteAccepted(
                request,
                operationId: keys.length == 1
                    ? _deletionOperationId
                    : 'op_01J00000000000000000000008',
              );
            } else if (request.uri.path.startsWith('/v1/operations/')) {
              final body = _deleteOperation(key: keys.single, state: 'failed');
              body['error'] = {
                'code': 'INTERNAL_ERROR',
                'message': 'Cleanup failed before publication.',
                'retryable': true,
                'details': {},
              };
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000008',
              );
              await _reply(request, body);
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await _refreshDeletion(tester);
      await _hostUntil(tester, find.text('Deletion Operation · failed'));
      expect(find.text('Cleanup failed before publication.'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this VM?'), findsOneWidget);
      expect(keys, hasLength(1));
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(FilledButton, 'Delete VM')),
      );
      await _hostUntil(tester, find.text('op_01J00000000000000000000008'));
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(2));
      expect(find.text('Deletion Operation · failed'), findsNothing);
      expect(find.text('running'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final state in ['running', 'succeeded']) {
    testWidgets(
      'VM deletion accepts $state acknowledgement without deriving completion or another intent',
      (tester) async {
        await _deletionDesktop(tester);
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'DELETE') {
                await _deleteAccepted(request, state: state);
              } else {
                await _deletionCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        await _hostUntil(tester, find.text('Deletion accepted · $state'));
        expect(find.textContaining('Deletion Operation ·'), findsNothing);
        expect(find.text('Reload VM catalog'), findsNothing);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Delete'),
              )
              .onPressed,
          isNull,
        );
        expect(find.text('running'), findsWidgets);
        expect(api.requests, hasLength(3));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'VM deletion keeps two VM intents independent on one configured socket',
    (tester) async {
      await _deletionDesktop(tester);
      const secondId = 'vm_01J00000000000000000000001';
      final keys = <String>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              keys.add(request.headers.value('Idempotency-Key')!);
              final second = request.uri.path.endsWith(secondId);
              await _deleteAccepted(
                request,
                vmId: second ? secondId : _deletionVmId,
                operationId: second
                    ? 'op_01J00000000000000000000008'
                    : _deletionOperationId,
              );
            } else if (request.uri.path == '/v1/vms') {
              await _reply(request, {
                'items': [_vm(), _vm(id: secondId, name: 'VM B')],
                'next_cursor': null,
              });
            } else {
              await _reply(
                request,
                request.uri.path.endsWith(secondId)
                    ? _vm(id: secondId, name: 'VM B')
                    : _vm(),
              );
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await tester.ensureVisible(find.text('VM B'));
      await tester.pump();
      await _selectDeletionVm(tester, 'VM B');
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('op_01J00000000000000000000008'));
      expect(find.text('DELETION INTENT'), findsNWidgets(2));
      expect(find.text(_deletionOperationId), findsOneWidget);
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(2));
      expect(
        api.requests.where((request) => request.startsWith('DELETE ')).toSet(),
        {'DELETE /v1/vms/$_deletionVmId', 'DELETE /v1/vms/$secondId'},
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion late completion cannot switch a different VM selection or snapshot',
    (tester) async {
      await _deletionDesktop(tester);
      const secondId = 'vm_01J00000000000000000000001';
      final arrived = (await tester.runAsync(() async => Completer<void>()))!;
      late HttpRequest delayed;
      String? key;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              key = request.headers.value('Idempotency-Key');
              await _deleteAccepted(request);
            } else if (request.uri.path.startsWith('/v1/operations/')) {
              delayed = request;
              arrived.complete();
            } else if (request.uri.path == '/v1/vms') {
              await _reply(request, {
                'items': [
                  _vm(),
                  _vm(
                    id: secondId,
                    name: 'VM B',
                    phase: 'stopped',
                    desiredState: 'stopped',
                  ),
                ],
                'next_cursor': null,
              });
            } else {
              await _reply(
                request,
                request.uri.path.endsWith(secondId)
                    ? _vm(
                        id: secondId,
                        name: 'VM B',
                        phase: 'stopped',
                        desiredState: 'stopped',
                      )
                    : _vm(),
              );
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await _refreshDeletion(tester);
      await _untilSignal(tester, arrived);
      await tester.ensureVisible(find.text('VM B'));
      await tester.pump();
      await _selectDeletionVm(tester, 'VM B');
      await tester.runAsync(() async {
        delayed.response.headers.set(
          'X-Request-ID',
          'req_01J00000000000000000000008',
        );
        await _reply(delayed, _deleteOperation(key: key!, state: 'succeeded'));
      });
      await _hostUntil(tester, find.text('Deletion Operation · succeeded'));
      expect(find.text('VM B'), findsNWidgets(2));
      expect(find.text('stopped'), findsWidgets);
      expect(
        api.requests.where(
          (request) => request == 'GET /v1/vms/$_deletionVmId',
        ),
        hasLength(1),
      );
      expect(
        api.requests.where((request) => request == 'GET /v1/vms'),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion receipt and catalog render on desktop with bundled typography',
    (tester) async {
      await _deletionDesktop(tester);
      String? key;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              key = request.headers.value('Idempotency-Key');
              await _deleteAccepted(request);
            } else if (request.uri.path.startsWith('/v1/operations/')) {
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000008',
              );
              await _reply(request, _deleteOperation(key: key!));
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('vm-deletion-preview');
      await tester.pumpWidget(
        const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _hostUntil(tester, find.text('gaoos-nightly-network'));
      await tester.runAsync(
        () async => tester.tap(find.text('gaoos-nightly-network')),
      );
      await _hostUntil(tester, find.text('Desired state'));
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await _refreshDeletion(tester);
      await _hostUntil(tester, find.text('Deletion Operation · running'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/ui-vm-deletion-preview.png');
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

  testWidgets('VM deletion Keep VM sends no mutation', (tester) async {
    await _deletionDesktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(handler: _deletionCatalog),
    ))!;
    addTearDown(api.close);
    await _connectDeletion(tester, api);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep VM'));
    await tester.pumpAndSettle();
    expect(find.text('DELETION INTENT'), findsNothing);
    expect(api.requests, ['GET /v1/vms', 'GET /v1/vms/$_deletionVmId']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final invalid in [
    'status',
    'extra',
    'missing',
    'resource type',
    'resource ID',
    'state',
    'operation ID',
    'operation type',
    'missing request ID',
    'request ID',
  ]) {
    testWidgets(
      'VM deletion rejects an invalid $invalid acceptance as an unknown outcome',
      (tester) async {
        await _deletionDesktop(tester);
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method != 'DELETE') {
                await _deletionCatalog(request);
                return;
              }
              request.response.statusCode = invalid == 'status' ? 200 : 202;
              if (invalid != 'missing request ID') {
                request.response.headers.set(
                  'X-Request-ID',
                  invalid == 'request ID'
                      ? 'req_bad'
                      : 'req_01J00000000000000000000009',
                );
              }
              final body = _deleteAcceptance();
              switch (invalid) {
                case 'extra':
                  body['phase'] = 'deleted';
                case 'missing':
                  body.remove('state');
                case 'resource type':
                  body['resource_type'] = 'image';
                case 'resource ID':
                  body['resource_id'] = 'vm_01J00000000000000000000001';
                case 'state':
                  body['state'] = 'failed';
                case 'operation ID':
                  body['operation_id'] = 'op_bad';
                case 'operation type':
                  body['operation_id'] = 42;
              }
              await _reply(request, body);
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        await _hostUntil(tester, find.text('Deletion outcome unknown'));
        expect(find.textContaining('Deletion accepted ·'), findsNothing);
        expect(find.text(_deletionOperationId), findsNothing);
        expect(find.text('running'), findsWidgets);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Delete'),
              )
              .onPressed,
          isNull,
        );
        expect(
          api.requests.where((request) => request.startsWith('DELETE ')),
          hasLength(1),
        );
        expect(
          api.requests.where(
            (request) => request.startsWith('GET /v1/operations'),
          ),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final invalid in [
    'id',
    'type',
    'resource',
    'target',
    'key',
    'original request',
    'extra',
    'status',
    'read request',
  ]) {
    testWidgets(
      'VM deletion rejects $invalid Operation data and retains its validated receipt',
      (tester) async {
        await _deletionDesktop(tester);
        String? key;
        var reads = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'DELETE') {
                key = request.headers.value('Idempotency-Key');
                await _deleteAccepted(request);
              } else if (request.uri.path.startsWith('/v1/operations/')) {
                reads++;
                request.response.headers.set(
                  'X-Request-ID',
                  reads == 2 && invalid == 'read request'
                      ? 'req_bad'
                      : 'req_01J00000000000000000000008',
                );
                final body = _deleteOperation(
                  key: key!,
                  state: reads == 1 ? 'running' : 'succeeded',
                );
                if (reads == 2) {
                  switch (invalid) {
                    case 'id':
                      body['id'] = 'op_01J00000000000000000000007';
                    case 'type':
                      body['type'] = 'vm.stop';
                    case 'resource':
                      body['resource_type'] = 'image';
                      body['resource_id'] = 'img_01J00000000000000000000000';
                    case 'target':
                      body['resource_id'] = 'vm_01J00000000000000000000001';
                    case 'key':
                      body['idempotency_key'] = 'another-client-key';
                    case 'original request':
                      body['request_id'] = 'req_01J00000000000000000000007';
                    case 'extra':
                      body['phase'] = 'deleted';
                    case 'status':
                      request.response.statusCode = 201;
                  }
                }
                await _reply(request, body);
              } else {
                await _deletionCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        await _hostUntil(tester, find.text('Deletion accepted · pending'));
        await _refreshDeletion(tester);
        await _hostUntil(tester, find.text('Deletion Operation · running'));
        await _refreshDeletion(tester);
        await _hostUntil(
          tester,
          find.text(
            'Deletion read failed · last validated Operation retained.',
          ),
        );
        expect(find.text('Deletion Operation · running'), findsOneWidget);
        expect(find.text('Deletion Operation · succeeded'), findsNothing);
        expect(find.text('Deletion outcome unknown'), findsNothing);
        expect(find.text('Reload VM catalog'), findsNothing);
        expect(
          api.requests.where((request) => request.startsWith('DELETE ')),
          hasLength(1),
        );
        expect(
          api.requests.where((request) => request == 'GET /v1/vms'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final readProblem in [false, true]) {
    testWidgets(
      'VM deletion ${readProblem ? 'read' : 'submission'} problems preserve structured diagnostics',
      (tester) async {
        await _deletionDesktop(tester);
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == 'DELETE' && readProblem) {
                await _deleteAccepted(request);
              } else if (request.method == 'DELETE' ||
                  request.uri.path.startsWith('/v1/operations/')) {
                await _deleteProblem(request);
              } else {
                await _deletionCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _submitDelete(tester);
        if (readProblem) {
          await _hostUntil(tester, find.text('Deletion accepted · pending'));
          await _refreshDeletion(tester);
        }
        await _hostUntil(tester, find.text('VM_OPERATION_CONFLICT'));
        expect(
          find.text('VM is owned by another pending intent.'),
          findsOneWidget,
        );
        expect(find.text('Not retryable'), findsOneWidget);
        expect(find.text('req_01J00000000000000000000007'), findsOneWidget);
        expect(find.text('op_01J00000000000000000000007'), findsOneWidget);
        expect(find.text('Deletion outcome unknown'), findsNothing);
        expect(find.text('running'), findsWidgets);
        if (readProblem) {
          expect(find.text('Deletion accepted · pending'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'VM deletion navigation releases a stalled submission and preserves its replay intent',
    (tester) async {
      await _deletionDesktop(tester);
      final stall = (await tester.runAsync(
        () async => _HostStall(expected: ['/v1/vms/$_deletionVmId']),
      ))!;
      final keys = <String>[];
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              keys.add(request.headers.value('Idempotency-Key')!);
              if (keys.length == 1) {
                await stall.read(request, api);
              } else {
                await _deleteAccepted(request);
              }
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {'items': [], 'next_cursor': null});
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _untilSignal(tester, stall.arrived);
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Operations')),
      );
      await _untilSignal(tester, stall.disconnected);
      await _hostUntil(tester, find.text('No Operations'));
      await tester.runAsync(
        () async =>
            tester.tap(find.widgetWithText(TextButton, 'Virtual machines')),
      );
      await _hostUntil(tester, find.text('Deletion outcome unknown'));
      await tester.ensureVisible(find.text('Replay deletion'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Replay deletion')),
      );
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1));
      expect(
        api.requests.any(
          (request) =>
              request.contains('/cancel') || request.contains('/actions/'),
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion tracks completion without deriving catalog state from its Operation',
    (tester) async {
      await _deletionDesktop(tester);
      String? key;
      var state = 'running';
      var removed = false;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              key = request.headers.value('Idempotency-Key');
              await _deleteAccepted(request);
            } else if (request.uri.path.startsWith('/v1/operations/')) {
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000008',
              );
              await _reply(request, _deleteOperation(key: key!, state: state));
            } else if (removed && request.uri.path == '/v1/vms') {
              await _reply(request, {'items': [], 'next_cursor': null});
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      await _refreshDeletion(tester);
      await _hostUntil(tester, find.text('Deletion Operation · running'));
      expect(find.text('Deleting managed files'), findsOneWidget);
      expect(
        find.text('Original request · req_01J00000000000000000000000'),
        findsOneWidget,
      );
      state = 'succeeded';
      removed = true;
      await _refreshDeletion(tester);
      await _hostUntil(tester, find.text('Deletion Operation · succeeded'));
      expect(find.text('running'), findsWidgets);
      expect(
        api.requests.where((request) => request == 'GET /v1/vms'),
        hasLength(1),
      );
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/deletion.sock',
      );
      await tester.ensureVisible(find.text('Reload VM catalog'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Reload VM catalog')),
      );
      await _hostUntil(tester, find.text('No virtual machines'));
      expect(find.text('Deletion Operation · succeeded'), findsOneWidget);
      expect(find.text('Select a VM'), findsOneWidget);
      expect(
        api.requests.where((request) => request.startsWith('DELETE ')),
        hasLength(1),
      );
      expect(
        api.requests.where((request) => request == 'GET /v1/vms'),
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion replays a lost response with the same confirmed key and socket',
    (tester) async {
      await _deletionDesktop(tester);
      final keys = <String>[];
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              expect(request.uri.path, '/v1/vms/$_deletionVmId');
              keys.add(request.headers.value('Idempotency-Key')!);
              expect(
                await request.fold<List<int>>([], (a, b) => a..addAll(b)),
                isEmpty,
              );
              if (keys.length == 1) {
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                api.detached.add(socket);
                socket.destroy();
              } else {
                await _deleteAccepted(request);
              }
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _submitDelete(tester);
      await _hostUntil(tester, find.text('Deletion outcome unknown'));
      expect(keys, hasLength(1));
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/deletion.sock',
      );
      await tester.ensureVisible(find.text('Replay deletion'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Replay deletion')),
      );
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1));
      expect(find.text('Delete this VM?'), findsNothing);
      expect(find.text('running'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM deletion confirms the exact target and accepts without removing the catalog',
    (tester) async {
      await _deletionDesktop(tester);
      String? key;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'DELETE') {
              expect(request.uri.path, '/v1/vms/$_deletionVmId');
              expect(request.uri.query, isEmpty);
              expect(
                await request.fold<List<int>>([], (a, b) => a..addAll(b)),
                isEmpty,
              );
              expect(request.headers.value('If-Match'), isNull);
              key = request.headers.value('Idempotency-Key');
              expect(key, isNotEmpty);
              await _deleteAccepted(request);
            } else {
              await _deletionCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this VM?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(_deletionVmId),
        ),
        findsOneWidget,
      );
      expect(find.text('External disks are preserved.'), findsOneWidget);
      expect(
        api.requests.every((request) => request.startsWith('GET ')),
        isTrue,
      );
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(FilledButton, 'Delete VM')),
      );
      await _hostUntil(tester, find.text('Deletion accepted · pending'));
      expect(find.text(_deletionOperationId), findsOneWidget);
      expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
      expect(find.text('running'), findsWidgets);
      expect(find.text('gaoos-nightly-network'), findsWidgets);
      expect(key, isNotNull);
      expect(api.requests, [
        'GET /v1/vms',
        'GET /v1/vms/$_deletionVmId',
        'DELETE /v1/vms/$_deletionVmId',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

const _deletionVmId = 'vm_01J00000000000000000000000';
const _deletionOperationId = 'op_01J00000000000000000000009';

Future<void> _deletionCatalog(HttpRequest request) => _reply(
  request,
  request.uri.path == '/v1/vms'
      ? {
          'items': [_vm()],
          'next_cursor': null,
        }
      : _vm(),
);

Future<void> _deleteAccepted(
  HttpRequest request, {
  String vmId = _deletionVmId,
  String operationId = _deletionOperationId,
  String state = 'pending',
}) async {
  request.response.statusCode = 202;
  request.response.headers.set(
    'X-Request-ID',
    'req_01J00000000000000000000009',
  );
  await _reply(
    request,
    _deleteAcceptance(vmId: vmId, operationId: operationId, state: state),
  );
}

Map<String, Object?> _deleteAcceptance({
  String vmId = _deletionVmId,
  String operationId = _deletionOperationId,
  String state = 'pending',
}) => {
  'operation_id': operationId,
  'state': state,
  'resource_type': 'virtual_machine',
  'resource_id': vmId,
};

Future<void> _deleteProblem(HttpRequest request) async {
  request.response.statusCode = 409;
  request.response.headers.contentType = ContentType(
    'application',
    'problem+json',
  );
  request.response.write(
    jsonEncode({
      'type': 'https://gaovm.dev/problems/vm-operation-conflict',
      'title': 'VM conflict',
      'status': 409,
      'code': 'VM_OPERATION_CONFLICT',
      'detail': 'VM is owned by another pending intent.',
      'request_id': 'req_01J00000000000000000000007',
      'retryable': false,
      'operation_id': 'op_01J00000000000000000000007',
      'details': {},
    }),
  );
  await request.response.close();
}

Future<void> _deletionDesktop(WidgetTester tester) async {
  await _desktop(tester);
  final oldHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  WidgetController.hitTestWarningShouldBeFatal = true;
  addTearDown(
    () => WidgetController.hitTestWarningShouldBeFatal = oldHitTestPolicy,
  );
}

Future<void> _connectDeletion(WidgetTester tester, _ApiFixture api) async {
  await _connect(tester, api);
  await _selectDeletionVm(tester, 'gaoos-nightly-network');
}

Future<void> _selectDeletionVm(WidgetTester tester, String name) async {
  final rowName = find.descendant(
    of: find.byType(InkWell),
    matching: find.text(name),
  );
  await tester.runAsync(() async => tester.tap(rowName));
  // Flush the previous detail before waiting for this selection's public read.
  await tester.pump();
  await _hostUntil(tester, find.text('Desired state'));
}

Future<void> _submitDelete(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
  await tester.pumpAndSettle();
  await tester.runAsync(
    () async => tester.tap(find.widgetWithText(FilledButton, 'Delete VM')),
  );
  // This is a finite dialog-exit animation, not a pending-read progress ticker.
  await tester.pumpAndSettle();
  expect(find.text('Delete this VM?'), findsNothing);
}

Future<void> _refreshDeletion(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Refresh deletion Operation'));
  await tester.pump();
  await tester.runAsync(
    () async => tester.tap(find.text('Refresh deletion Operation')),
  );
}

Map<String, Object?> _deleteOperation({
  required String key,
  String state = 'running',
}) {
  final body = _operation(
    id: _deletionOperationId,
    key: key,
    type: 'vm.delete',
    state: state,
  );
  body['progress'] = {'percent': 40, 'step': 'Deleting managed files'};
  return body;
}
