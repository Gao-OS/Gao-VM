part of 'catalog_test.dart';

void _vmWriteTests() {
  for (final invalid in [
    'missing ETag',
    'weak ETag',
    'different ETag',
    'missing request',
    'request',
    'status',
    'target',
  ]) {
    testWidgets(
      'VM edit rejects an invalid $invalid fresh read before any write',
      (tester) async {
        await _deletionDesktop(tester);
        var details = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.uri.path == '/v1/vms') {
                await _writeCatalog(request);
                return;
              }
              details++;
              final bad = details == 2;
              if (!bad || invalid != 'missing ETag') {
                request.response.headers.set(
                  'ETag',
                  bad && invalid == 'weak ETag'
                      ? 'W/"7"'
                      : bad && invalid == 'different ETag'
                      ? '"8"'
                      : '"7"',
                );
              }
              if (!bad || invalid != 'missing request') {
                request.response.headers.set(
                  'X-Request-ID',
                  bad && invalid == 'request'
                      ? 'req_bad'
                      : 'req_01J00000000000000000000008',
                );
              }
              if (bad && invalid == 'status') request.response.statusCode = 201;
              await _reply(
                request,
                _vm(
                  id: bad && invalid == 'target'
                      ? 'vm_01J00000000000000000000001'
                      : _deletionVmId,
                ),
              );
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await tester.runAsync(
          () async => tester.tap(find.widgetWithText(TextButton, 'Edit VM')),
        );
        await _hostUntil(
          tester,
          find.textContaining(
            invalid == 'request'
                ? 'invalid req resource ID: req_bad'
                : 'Editing requires a matching VM revision and strong ETag.',
          ),
        );
        expect(find.byKey(const Key('vm-write-json')), findsNothing);
        expect(
          api.requests.where(
            (value) => value.startsWith('PATCH ') || value.startsWith('POST '),
          ),
          isEmpty,
        );
        expect(details, 2);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final create in [true, false]) {
    for (final invalid in [
      'status',
      'extra',
      'missing',
      'type',
      'VM ID',
      'Operation ID',
      'missing request',
      'request',
      'state',
      if (!create) 'target',
    ]) {
      testWidgets(
        'VM ${create ? 'create' : 'patch'} rejects $invalid acknowledgement atomically',
        (tester) async {
          await _deletionDesktop(tester);
          final api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                if (request.method != (create ? 'POST' : 'PATCH')) {
                  await _writeCatalog(request);
                  return;
                }
                await request.drain<void>();
                request.response.statusCode = invalid == 'status' ? 200 : 202;
                if (invalid != 'missing request') {
                  request.response.headers.set(
                    'X-Request-ID',
                    invalid == 'request'
                        ? 'req_bad'
                        : 'req_01J00000000000000000000009',
                  );
                }
                final body = _deleteAcceptance();
                switch (invalid) {
                  case 'extra':
                    body['phase'] = 'running';
                  case 'missing':
                    body.remove('state');
                  case 'type':
                    body['resource_type'] = 'image';
                  case 'VM ID':
                    body['resource_id'] = 'vm_bad';
                  case 'Operation ID':
                    body['operation_id'] = 'op_bad';
                  case 'state':
                    body['state'] = 'failed';
                  case 'target':
                    body['resource_id'] = 'vm_01J00000000000000000000001';
                }
                await _reply(request, body);
              },
            ),
          ))!;
          addTearDown(api.close);
          await _connectDeletion(tester, api);
          await _writeSubmit(tester, create: create);
          await _hostUntil(tester, find.text('VM write outcome unknown'));
          expect(
            find.textContaining('VM ${create ? 'create' : 'patch'} accepted'),
            findsNothing,
          );
          expect(find.text(_deletionOperationId), findsNothing);
          expect(find.text('running'), findsWidgets);
          expect(
            api.requests.where(
              (value) => value.startsWith('GET /v1/operations'),
            ),
            isEmpty,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final invalid in [
      'ID',
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
        'VM ${create ? 'create' : 'patch'} retains the last valid Operation after $invalid data',
        (tester) async {
          await _deletionDesktop(tester);
          String? key;
          var reads = 0;
          final api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                if (request.method == (create ? 'POST' : 'PATCH')) {
                  key = request.headers.value('Idempotency-Key');
                  await request.drain<void>();
                  await _deleteAccepted(request);
                } else if (request.uri.path.startsWith('/v1/operations/')) {
                  reads++;
                  request.response.headers.set(
                    'X-Request-ID',
                    reads == 2 && invalid == 'read request'
                        ? 'req_bad'
                        : 'req_01J00000000000000000000008',
                  );
                  final body = _operation(
                    id: _deletionOperationId,
                    type: create ? 'vm.create' : 'vm.patch',
                    key: key,
                    state: reads == 1 ? 'running' : 'succeeded',
                  );
                  if (reads == 2) {
                    switch (invalid) {
                      case 'ID':
                        body['id'] = 'op_01J00000000000000000000007';
                      case 'type':
                        body['type'] = 'vm.delete';
                      case 'resource':
                        body['resource_type'] = 'image';
                        body['resource_id'] = 'img_01J00000000000000000000000';
                      case 'target':
                        body['resource_id'] = 'vm_01J00000000000000000000001';
                      case 'key':
                        body['idempotency_key'] = 'different-key';
                      case 'original request':
                        body['request_id'] = 'req_01J00000000000000000000007';
                      case 'extra':
                        body['phase'] = 'running';
                      case 'status':
                        request.response.statusCode = 201;
                    }
                  }
                  await _reply(request, body);
                } else {
                  await _writeCatalog(request);
                }
              },
            ),
          ))!;
          addTearDown(api.close);
          await _connectDeletion(tester, api);
          await _writeSubmit(tester, create: create);
          await _hostUntil(
            tester,
            find.text('VM ${create ? 'create' : 'patch'} accepted · pending'),
          );
          await _writeRefresh(tester);
          await _hostUntil(tester, find.text('Write Operation · running'));
          await _writeRefresh(tester);
          await _hostUntil(
            tester,
            find.text('Write read failed · last validated Operation retained.'),
          );
          expect(find.text('Write Operation · running'), findsOneWidget);
          expect(find.text('Write Operation · succeeded'), findsNothing);
          expect(find.text('Reload written VM catalog'), findsNothing);
          expect(
            api.requests.where((value) => value == 'GET /v1/vms'),
            hasLength(1),
          );
          expect(reads, 2);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final invalid in ['empty', 'server fields', 'invalid spec']) {
      testWidgets(
        'VM ${create ? 'create' : 'patch'} invalid $invalid draft issues no command',
        (tester) async {
          await _deletionDesktop(tester);
          final api = (await tester.runAsync(
            () => _ApiFixture.open(handler: _writeCatalog),
          ))!;
          addTearDown(api.close);
          await _connectDeletion(tester, api);
          final input = switch (invalid) {
            'empty' => <String, Object?>{},
            'server fields' => _vm(),
            _ =>
              create
                  ? {
                      ..._writeCreateJson(),
                      'spec': {'cpu': 0},
                    }
                  : {
                      'spec': {'cpu': 0},
                    },
          };
          await _writeSubmit(tester, create: create, input: input);
          expect(find.byKey(const Key('vm-write-json')), findsOneWidget);
          expect(find.text('VM WRITE INTENT'), findsNothing);
          expect(
            api.requests.any(
              (value) =>
                  value.startsWith('POST ') || value.startsWith('PATCH '),
            ),
            isFalse,
          );
          await tester.tap(find.text('Discard draft'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'VM write navigation releases a stalled submission and retains its replay intent',
    (tester) async {
      await _deletionDesktop(tester);
      final stall = (await tester.runAsync(
        () async => _HostStall(expected: ['/v1/vms']),
      ))!;
      final keys = <String?>[];
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              if (keys.length == 1) {
                await stall.read(request, api);
              } else {
                await _deleteAccepted(request);
              }
            } else if (request.uri.path == '/v1/operations') {
              await _reply(request, {'items': [], 'next_cursor': null});
            } else {
              await _writeCatalog(request);
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await _writeSubmit(tester, create: true);
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
      await _hostUntil(tester, find.text('VM write outcome unknown'));
      await tester.ensureVisible(find.text('Replay VM write'));
      await tester.pump();
      await tester.runAsync(
        () async => tester.tap(find.text('Replay VM write')),
      );
      await _hostUntil(tester, find.text('VM create accepted · pending'));
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1));
      expect(
        api.requests.any(
          (value) => value.contains('/cancel') || value.contains('/actions/'),
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final create in [true, false]) {
    testWidgets(
      'VM ${create ? 'create' : 'patch'} reads durable completion and reloads resources only explicitly',
      (tester) async {
        await _deletionDesktop(tester);
        String? key;
        var state = 'running';
        var catalogs = 0;
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == (create ? 'POST' : 'PATCH')) {
                key = request.headers.value('Idempotency-Key');
                await request.drain<void>();
                await _deleteAccepted(request);
              } else if (request.uri.path.startsWith('/v1/operations/')) {
                request.response.headers.set(
                  'X-Request-ID',
                  'req_01J00000000000000000000008',
                );
                await _reply(
                  request,
                  _operation(
                    id: _deletionOperationId,
                    type: create ? 'vm.create' : 'vm.patch',
                    key: key,
                    state: state,
                  ),
                );
              } else if (request.uri.path == '/v1/vms') {
                catalogs++;
                await _reply(request, {
                  'items': [_vm()],
                  'next_cursor': null,
                });
              } else {
                await _writeCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _writeSubmit(tester, create: create);
        await _hostUntil(
          tester,
          find.text('VM ${create ? 'create' : 'patch'} accepted · pending'),
        );
        await _writeRefresh(tester);
        await _hostUntil(tester, find.text('Write Operation · running'));
        expect(
          find.text('Write original request · req_01J00000000000000000000000'),
          findsOneWidget,
        );
        state = 'succeeded';
        await _writeRefresh(tester);
        await _hostUntil(tester, find.text('Write Operation · succeeded'));
        expect(catalogs, 1);
        expect(find.text('4 vCPU · 4096 MiB'), findsWidgets);
        await tester.enterText(
          find.byType(TextField),
          '/unsubmitted/write.sock',
        );
        await tester.ensureVisible(find.text('Reload written VM catalog'));
        await tester.pump();
        await tester.runAsync(
          () async => tester.tap(find.text('Reload written VM catalog')),
        );
        await _hostUntil(tester, find.text('Select a VM'));
        await _hostUntil(tester, find.text('revision 7'));
        expect(catalogs, 2);
        expect(find.text('Write Operation · succeeded'), findsOneWidget);
        expect(
          api.requests.where(
            (value) => value.startsWith(create ? 'POST ' : 'PATCH '),
          ),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final create in [true, false]) {
    testWidgets(
      'VM ${create ? 'create' : 'patch'} lost reply replays the immutable body, key, socket and revision',
      (tester) async {
        await _deletionDesktop(tester);
        final bodies = <String>[];
        final keys = <String?>[];
        final revisions = <String?>[];
        late _ApiFixture api;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              if (request.method == (create ? 'POST' : 'PATCH')) {
                bodies.add(await utf8.decoder.bind(request).join());
                keys.add(request.headers.value('Idempotency-Key'));
                revisions.add(request.headers.value('If-Match'));
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
                await _writeCatalog(request);
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectDeletion(tester, api);
        await _writeSubmit(tester, create: create);
        await _hostUntil(tester, find.text('VM write outcome unknown'));
        expect(keys, hasLength(1));
        await tester.enterText(
          find.byType(TextField),
          '/unsubmitted/write.sock',
        );
        await tester.ensureVisible(find.text('Replay VM write'));
        await tester.pump();
        await tester.runAsync(
          () async => tester.tap(find.text('Replay VM write')),
        );
        await _hostUntil(
          tester,
          find.text('VM ${create ? 'create' : 'patch'} accepted · pending'),
        );
        expect(keys, hasLength(2));
        expect(keys.toSet(), hasLength(1));
        expect(bodies.toSet(), hasLength(1));
        expect(revisions, create ? [null, null] : ['"7"', '"7"']);
        expect(find.text('VM request JSON'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'VM editing uses a fresh matching ETag and stages the requested spec without guessing applied state',
    (tester) async {
      await _deletionDesktop(tester);
      final patch = {
        'metadata': {'name': 'renamed'},
        'spec': {'cpu': 8, 'guest_profile': null},
      };
      Object? sent;
      String? revision;
      String? mediaType;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'PATCH') {
              sent = jsonDecode(await utf8.decoder.bind(request).join());
              revision = request.headers.value('If-Match');
              mediaType = request.headers.contentType?.mimeType;
              await _deleteAccepted(request);
            } else if (request.uri.path == '/v1/vms') {
              await _reply(request, {
                'items': [_vm()],
                'next_cursor': null,
              });
            } else {
              request.response.headers.set('ETag', '"7"');
              request.response.headers.set(
                'X-Request-ID',
                'req_01J00000000000000000000008',
              );
              await _reply(request, _vm());
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectDeletion(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Edit VM')),
      );
      await _hostUntil(tester, find.text('Edit VM configuration'));
      expect(find.text('Revision precondition · "7"'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('vm-write-json')),
        jsonEncode(patch),
      );
      await tester.runAsync(
        () async =>
            tester.tap(find.widgetWithText(FilledButton, 'Submit update')),
      );
      await tester.pumpAndSettle();
      await _hostUntil(tester, find.text('VM patch accepted · pending'));
      expect(sent, patch);
      expect(revision, '"7"');
      expect(mediaType, 'application/merge-patch+json');
      expect(find.text('4 vCPU · 4096 MiB'), findsWidgets);
      expect(find.text('8 vCPU · 4096 MiB'), findsNothing);
      expect(find.text('running'), findsWidgets);
      expect(api.requests, [
        'GET /v1/vms',
        'GET /v1/vms/$_deletionVmId',
        'GET /v1/vms/$_deletionVmId',
        'PATCH /v1/vms/$_deletionVmId',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'VM creation validates a complete draft and keeps acceptance separate from catalog',
    (tester) async {
      await _deletionDesktop(tester);
      Object? sent;
      String? key;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              sent = jsonDecode(await utf8.decoder.bind(request).join());
              key = request.headers.value('Idempotency-Key');
              await _deleteAccepted(request);
            } else {
              await _reply(request, {'items': [], 'next_cursor': null});
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('vm-write-preview');
      await tester.pumpWidget(
        const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _hostUntil(tester, find.text('No virtual machines'));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Create VM'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('vm-write-json')),
        jsonEncode(_writeCreateJson()),
      );
      await _writePreview(
        tester,
        previewKey,
        'build/ui-vm-write-draft-preview.png',
      );
      await tester.runAsync(
        () async =>
            tester.tap(find.widgetWithText(FilledButton, 'Submit create')),
      );
      await tester.pumpAndSettle();
      await _hostUntil(tester, find.text('VM create accepted · pending'));
      expect(
        sent,
        models.VmCreateRequest.fromJson(_writeCreateJson()).toJson(),
      );
      expect(key, matches(RegExp(r'^ui-write-[0-9a-f]{32}$')));
      expect(find.text(_deletionVmId), findsOneWidget);
      expect(find.text('No virtual machines'), findsOneWidget);
      expect(find.text('Select a VM'), findsOneWidget);
      expect(api.requests, ['GET /v1/vms', 'POST /v1/vms']);
      await _writePreview(tester, previewKey, 'build/ui-vm-write-preview.png');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _writePreview(WidgetTester tester, Key key, String path) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File(path);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Map<String, Object?> _writeCreateJson() => {
  'api_version': 'gaovm.io/v1alpha1',
  'kind': 'VirtualMachine',
  'metadata': {
    'name': 'new-image-vm',
    'labels': {'channel': 'nightly'},
  },
  'spec': _vm()['spec'],
};

Future<void> _writeCatalog(HttpRequest request) async {
  request.response.headers.set('ETag', '"7"');
  request.response.headers.set(
    'X-Request-ID',
    'req_01J00000000000000000000008',
  );
  await _reply(
    request,
    request.uri.path == '/v1/vms'
        ? {
            'items': [_vm()],
            'next_cursor': null,
          }
        : _vm(),
  );
}

Future<void> _writeSubmit(
  WidgetTester tester, {
  required bool create,
  Object? input,
}) async {
  await tester.runAsync(
    () async => tester.tap(
      find.widgetWithText(
        create ? OutlinedButton : TextButton,
        create ? 'Create VM' : 'Edit VM',
      ),
    ),
  );
  await _hostUntil(
    tester,
    find.text(create ? 'Create VM' : 'Edit VM configuration'),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('vm-write-json')),
    jsonEncode(
      input ??
          (create
              ? _writeCreateJson()
              : {
                  'spec': {'cpu': 8, 'guest_profile': null},
                }),
    ),
  );
  await tester.runAsync(
    () async => tester.tap(
      find.widgetWithText(
        FilledButton,
        create ? 'Submit create' : 'Submit update',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _writeRefresh(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Refresh write Operation'));
  await tester.pump();
  await tester.runAsync(
    () async => tester.tap(find.text('Refresh write Operation')),
  );
}
