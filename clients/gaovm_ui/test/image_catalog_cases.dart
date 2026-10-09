part of 'catalog_test.dart';

void _imageCatalogTests() {
  testWidgets(
    'the image catalog uses only the public image list without selecting a VM',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [_imageRecord()],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('gaoos-bundle'));
      expect(find.text('img_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('2026.10 · nightly'), findsOneWidget);
      expect(find.text('gaoos.channel = nightly'), findsOneWidget);
      expect(find.text('Select an image'), findsOneWidget);
      expect(find.text('Select a VM'), findsNothing);
      expect(api.requests, ['GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'image selection exposes digest metadata and the complete manifest without another request',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [_imageRecord()],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('img_01J00000000000000000000000'));
      await tester.tap(find.text('img_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      expect(find.text('sha256:${'a' * 64}'), findsOneWidget);
      expect(find.text('arm64'), findsOneWidget);
      expect(find.text('gaoos'), findsOneWidget);
      expect(find.text('nightly-20261009'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('"guest_agent_expected": true'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('image-detail-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('"root_disk": "root"'), findsOneWidget);
      expect(find.textContaining('"size_bytes": 4096'), findsOneWidget);
      expect(find.text('2026-10-09T08:00:00.000Z'), findsOneWidget);
      expect(find.text('Select an image'), findsNothing);
      expect(api.requests, ['GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'image paging preserves the opaque cursor, selection, and configured socket',
    (tester) async {
      await _desktop(tester);
      const cursor = 'opaque+/==?after=42%raw';
      final queries = <Map<String, String>>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            final more = request.uri.queryParameters.containsKey('cursor');
            queries.add(request.uri.queryParameters);
            await _reply(request, {
              'items': [
                more
                    ? _imageRecord(
                        id: 'img_01J00000000000000000000001',
                        type: 'raw-disk',
                        labels: {},
                      )
                    : _imageRecord(),
              ],
              'next_cursor': more ? null : cursor,
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('img_01J00000000000000000000000'));
      await tester.tap(find.text('img_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(() async => tester.tap(find.text('Load more')));
      await _until(tester, find.text('raw-disk'));
      expect(find.text('2 images · catalog snapshot'), findsOneWidget);
      expect(find.text('img_01J00000000000000000000000'), findsNWidgets(2));
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      expect(find.text('No version · No channel'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      expect(queries, [
        {},
        {'cursor': cursor},
      ]);
      expect(api.requests, ['GET /v1/images', 'GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('image paging does not require selecting an image', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _reply(request, {
          'items': [_imageRecord()],
          'next_cursor': 'next-page',
        }),
      ),
    ))!;
    addTearDown(api.close);
    await _connectImages(tester, api);
    await _until(tester, find.text('gaoos-bundle'));
    expect(find.text('Load more'), findsOneWidget);
    expect(find.text('1 images · catalog snapshot'), findsOneWidget);
    expect(find.text('Select an image'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'an empty image continuation cursor is rejected before displaying records',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [_imageRecord()],
            'next_cursor': '',
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('Invalid image catalog response.'));
      expect(find.text('img_01J00000000000000000000000'), findsNothing);
      expect(find.text('Image catalog read failed'), findsOneWidget);
      expect(find.text('No images'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'duplicate image paging is rejected atomically and can retry the same cursor',
    (tester) async {
      await _desktop(tester);
      final cursors = <String?>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            cursors.add(request.uri.queryParameters['cursor']);
            await _reply(request, {
              'items': [
                if (cursors.length == 1)
                  _imageRecord()
                else ...[
                  _imageRecord(
                    id: 'img_01J00000000000000000000001',
                    type: 'raw-disk',
                    labels: {},
                  ),
                  if (cursors.length == 2) _imageRecord(),
                ],
              ],
              'next_cursor': cursors.length == 1 ? 'next-page' : null,
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('img_01J00000000000000000000000'));
      await tester.tap(find.text('img_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => tester.tap(find.text('Load more')));
      await _until(tester, find.text('Image catalog repeated a resource ID.'));
      expect(find.text('raw-disk'), findsNothing);
      expect(find.text('img_01J00000000000000000000000'), findsNWidgets(2));
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      expect(find.text('1 images · catalog snapshot'), findsOneWidget);
      await tester.runAsync(() async => tester.tap(find.text('Load more')));
      await _until(tester, find.text('raw-disk'));
      expect(find.text('Image catalog repeated a resource ID.'), findsNothing);
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      expect(cursors, [null, 'next-page', 'next-page']);
      expect(api.requests, List.filled(3, 'GET /v1/images'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('an image continuation loop keeps the previous validated page', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _reply(request, {
          'items': [
            request.uri.queryParameters['cursor'] == null
                ? _imageRecord()
                : _imageRecord(
                    id: 'img_01J00000000000000000000001',
                    type: 'raw-disk',
                    labels: {},
                  ),
          ],
          'next_cursor': 'next-page',
        }),
      ),
    ))!;
    addTearDown(api.close);
    await _connectImages(tester, api);
    await _until(tester, find.text('gaoos-bundle'));
    await tester.runAsync(() async => tester.tap(find.text('Load more')));
    await _until(tester, find.text('Image catalog repeated its cursor.'));
    expect(find.text('raw-disk'), findsNothing);
    expect(find.text('img_01J00000000000000000000000'), findsOneWidget);
    expect(find.text('1 images · catalog snapshot'), findsOneWidget);
    expect(api.requests, ['GET /v1/images', 'GET /v1/images']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Reload images rereads the configured catalog and clears the old snapshot',
    (tester) async {
      await _desktop(tester);
      final queries = <Map<String, String>>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            queries.add(request.uri.queryParameters);
            await _reply(request, {
              'items': [
                queries.length == 1
                    ? _imageRecord()
                    : _imageRecord(
                        id: 'img_01J00000000000000000000001',
                        type: 'raw-disk',
                        labels: {},
                      ),
              ],
              'next_cursor': queries.length == 1 ? 'old-page' : null,
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('img_01J00000000000000000000000'));
      await tester.tap(find.text('img_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(() async => tester.tap(find.text('Reload images')));
      await _until(tester, find.text('raw-disk'));
      expect(find.text('Select an image'), findsOneWidget);
      expect(find.text('img_01J00000000000000000000000'), findsNothing);
      expect(find.text('Load more'), findsNothing);
      expect(queries, [{}, {}]);
      expect(api.requests, ['GET /v1/images', 'GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'one invalid image record rejects the whole page without partial rows',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              _imageRecord(),
              {
                ..._imageRecord(id: 'img_01J00000000000000000000001'),
                'digest': 'not-a-digest',
              },
            ],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('Invalid image record.'));
      expect(find.text('img_01J00000000000000000000000'), findsNothing);
      expect(find.text('img_01J00000000000000000000001'), findsNothing);
      expect(find.text('Image catalog read failed'), findsOneWidget);
      expect(find.text('No images'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  for (final invalid in [
    'extra key',
    'missing cursor',
    'cursor type',
    'oversized cursor',
    'items type',
    'status',
  ]) {
    testWidgets(
      'image catalog rejects an invalid $invalid page without displaying records',
      (tester) async {
        await _desktop(tester);
        final page = <String, Object?>{
          'items': [_imageRecord()],
          'next_cursor': null,
        };
        switch (invalid) {
          case 'extra key':
            page['unexpected'] = true;
          case 'missing cursor':
            page.remove('next_cursor');
          case 'cursor type':
            page['next_cursor'] = 42;
          case 'oversized cursor':
            page['next_cursor'] = 'x' * 513;
          case 'items type':
            page['items'] = {};
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
        await _connectImages(tester, api);
        await _until(tester, find.text('Invalid image catalog response.'));
        expect(find.text('img_01J00000000000000000000000'), findsNothing);
        expect(find.text('Image catalog read failed'), findsOneWidget);
        expect(find.text('No images'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(api.requests, ['GET /v1/images']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final field in [
    'id',
    'type',
    'architecture',
    'manifest',
    'created_at',
    'labels',
  ]) {
    testWidgets('image catalog rejects a malformed $field record', (
      tester,
    ) async {
      await _desktop(tester);
      final invalid = <String, Object?>{
        'id': 'vm_01J00000000000000000000000',
        'type': 'snapshot',
        'architecture': 'x86_64',
        'manifest': [],
        'created_at': 'not-a-date',
        'labels': {'channel': 42},
      };
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              {..._imageRecord(), field: invalid[field]},
            ],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('Invalid image record.'));
      expect(find.text('Image catalog read failed'), findsOneWidget);
      expect(find.text('No images'), findsNothing);
      expect(find.text('img_01J00000000000000000000000'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final type in ['linux-kernel', 'initrd', 'raw-disk']) {
    testWidgets(
      'the image catalog reads $type without inventing GaoOS metadata',
      (tester) async {
        await _desktop(tester);
        final image = _imageRecord(type: type, labels: {});
        for (final field in [
          'guest_profile',
          'version',
          'build_id',
          'channel',
          'labels',
        ]) {
          image.remove(field);
        }
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) => _reply(request, {
              'items': [image],
              'next_cursor': null,
            }),
          ),
        ))!;
        addTearDown(api.close);
        await _connectImages(tester, api);
        await _until(tester, find.text(type));
        await tester.tap(find.text('img_01J00000000000000000000000'));
        await tester.pumpAndSettle();
        expect(find.text('Not provided'), findsNWidgets(4));
        expect(find.text('gaoos'), findsNothing);
        await tester.scrollUntilVisible(
          find.textContaining('"payload"'),
          180,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('image-detail-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('No labels'), findsOneWidget);
        expect(find.textContaining('"size_bytes": 4096'), findsOneWidget);
        expect(api.requests, ['GET /v1/images']);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('image cursor loops back to an earlier page are also rejected', (
    tester,
  ) async {
    await _desktop(tester);
    var reads = 0;
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          reads++;
          await _reply(request, {
            'items': [_imageRecord(id: 'img_01J0000000000000000000000$reads')],
            'next_cursor': reads == 2 ? 'page-b' : 'page-a',
          });
        },
      ),
    ))!;
    addTearDown(api.close);
    await _connectImages(tester, api);
    await _until(tester, find.text('img_01J00000000000000000000001'));
    await tester.runAsync(() async => tester.tap(find.text('Load more')));
    await _until(tester, find.text('img_01J00000000000000000000002'));
    await tester.runAsync(() async => tester.tap(find.text('Load more')));
    await _until(tester, find.text('Image catalog repeated its cursor.'));
    expect(find.text('img_01J00000000000000000000003'), findsNothing);
    expect(find.text('2 images · catalog snapshot'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a successful empty image list is different from disconnection or failure',
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
      await tester.tap(find.widgetWithText(TextButton, 'Images'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to read the image catalog'), findsOneWidget);
      expect(find.text('No images'), findsNothing);
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('No images'));
      expect(find.text('Image catalog read failed'), findsNothing);
      expect(find.text('Select an image'), findsOneWidget);
      expect(api.requests, ['GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image read problems retain structured metadata and can reload without commands',
    (tester) async {
      await _desktop(tester);
      var reads = 0;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (++reads == 1) {
              request.response.statusCode = 500;
              await _reply(request, {
                'type': 'https://gaovm.dev/problems/internal-error',
                'title': 'Image catalog unavailable',
                'status': 500,
                'code': 'INTERNAL_ERROR',
                'detail': 'Try the catalog again.',
                'request_id': 'req_01J00000000000000000000009',
                'retryable': true,
                'operation_id': null,
                'details': {},
              });
            } else {
              await _reply(request, {
                'items': [_imageRecord()],
                'next_cursor': null,
              });
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectImages(tester, api);
      await _until(tester, find.text('INTERNAL_ERROR'));
      expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
      expect(find.text('Retryable'), findsOneWidget);
      expect(find.text('No images'), findsNothing);
      await tester.runAsync(() async => tester.tap(find.text('Reload images')));
      await _until(tester, find.text('gaoos-bundle'));
      expect(find.text('INTERNAL_ERROR'), findsNothing);
      expect(api.requests, ['GET /v1/images', 'GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  for (final exit in ['window close', 'Operations', 'Connect']) {
    testWidgets(
      'image $exit releases a stalled catalog read without commands',
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
              if (request.uri.path == '/v1/images' && !arrived.isCompleted) {
                await _stallImageRead(request, api, disconnected);
                arrived.complete();
              } else {
                await _reply(request, {
                  'items': request.uri.path == '/v1/images'
                      ? [_imageRecord(type: 'raw-disk', labels: {})]
                      : [],
                  'next_cursor': null,
                });
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectImages(tester, api);
        await _untilSignal(tester, arrived);
        switch (exit) {
          case 'window close':
            await tester.pumpWidget(const SizedBox.shrink());
          case 'Operations':
            await tester.runAsync(
              () async =>
                  tester.tap(find.widgetWithText(TextButton, 'Operations')),
            );
          case 'Connect':
            await tester.runAsync(() async => tester.tap(find.text('Connect')));
        }
        await _untilSignal(tester, disconnected);
        if (exit == 'Operations') {
          await _until(tester, find.text('No Operations'));
        }
        if (exit == 'Connect') await _until(tester, find.text('raw-disk'));
        expect(api.requests, [
          'GET /v1/images',
          if (exit == 'Operations') 'GET /v1/operations',
          if (exit == 'Connect') 'GET /v1/images',
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final closeWindow in [true, false]) {
    testWidgets(
      'image ${closeWindow ? 'close' : 'navigation'} releases a stalled page read without commands',
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
              if (request.uri.queryParameters['cursor'] != null) {
                await _stallImageRead(request, api, disconnected);
                arrived.complete();
              } else {
                await _reply(request, {
                  'items': request.uri.path == '/v1/images'
                      ? [_imageRecord()]
                      : [],
                  'next_cursor': request.uri.path == '/v1/images'
                      ? 'next-page'
                      : null,
                });
              }
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectImages(tester, api);
        await _until(tester, find.text('gaoos-bundle'));
        await tester.runAsync(() async => tester.tap(find.text('Load more')));
        await _untilSignal(tester, arrived);
        if (closeWindow) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.runAsync(
            () async =>
                tester.tap(find.widgetWithText(TextButton, 'Operations')),
          );
        }
        await _untilSignal(tester, disconnected);
        if (!closeWindow) await _until(tester, find.text('No Operations'));
        expect(api.requests, [
          'GET /v1/images',
          'GET /v1/images',
          if (!closeWindow) 'GET /v1/operations',
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'connecting Images to another socket closes the old read and owns only the new catalog',
    (tester) async {
      await _desktop(tester);
      final latches = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>()),
      ))!;
      final arrived = latches.$1;
      final disconnected = latches.$2;
      late _ApiFixture first;
      first = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            await _stallImageRead(request, first, disconnected);
            arrived.complete();
          },
        ),
      ))!;
      addTearDown(first.close);
      final second = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              _imageRecord(
                id: 'img_01J00000000000000000000001',
                type: 'raw-disk',
                labels: {},
              ),
            ],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(second.close);
      await _connectImages(tester, first);
      await _untilSignal(tester, arrived);
      await tester.enterText(find.byType(TextField), second.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('raw-disk'));
      await _untilSignal(tester, disconnected);
      expect(find.text('img_01J00000000000000000000001'), findsOneWidget);
      expect(find.text('Image catalog read failed'), findsNothing);
      expect(find.text('Select an image'), findsOneWidget);
      expect(first.requests, ['GET /v1/images']);
      expect(second.requests, ['GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'entering Images releases the active event stream and uses the configured socket',
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
              await _reply(request, {
                'items': [_imageRecord()],
                'next_cursor': null,
              });
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
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(
        () async => tester.tap(find.widgetWithText(TextButton, 'Images')),
      );
      await _until(tester, find.text('gaoos-bundle'));
      await _untilSignal(tester, peer.disconnected);
      expect(find.text('Resume cursor · 42'), findsNothing);
      expect(api.requests, ['GET /v1/events', 'GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the desktop image catalog and manifest render with bundled fonts',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(request, {
            'items': [
              _imageRecord(),
              _imageRecord(
                id: 'img_01J00000000000000000000001',
                type: 'raw-disk',
                labels: {},
              ),
              _imageRecord(
                id: 'img_01J00000000000000000000002',
                type: 'linux-kernel',
                labels: {'purpose': 'generic'},
              ),
            ],
            'next_cursor': null,
          }),
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('image-preview');
      await _connectImages(
        tester,
        api,
        app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await _until(tester, find.text('img_01J00000000000000000000000'));
      await tester.tap(find.text('img_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      expect(find.text('IMAGE MANIFEST'), findsOneWidget);
      expect(find.text('3 images · catalog snapshot'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/ui-images-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(api.requests, ['GET /v1/images']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _stallImageRead(
  HttpRequest request,
  _ApiFixture api,
  Completer<void> disconnected,
) async {
  final socket = await request.response.detachSocket(writeHeaders: false);
  api.detached.add(socket);
  void closed() {
    if (!disconnected.isCompleted) disconnected.complete();
  }

  socket.listen((_) {}, onDone: closed, onError: (Object _) => closed());
}

Map<String, Object?> _imageRecord({
  String id = 'img_01J00000000000000000000000',
  String type = 'gaoos-bundle',
  Map<String, String> labels = const {'gaoos.channel': 'nightly'},
}) => {
  'id': id,
  'digest': 'sha256:${'a' * 64}',
  'type': type,
  'architecture': 'arm64',
  'guest_profile': type == 'gaoos-bundle' ? 'gaoos' : null,
  'version': type == 'gaoos-bundle' ? '2026.10' : null,
  'build_id': type == 'gaoos-bundle' ? 'nightly-20261009' : null,
  'channel': type == 'gaoos-bundle' ? 'nightly' : null,
  'labels': labels,
  'manifest': {
    'manifest_version': 1,
    'digest': 'sha256:${'a' * 64}',
    'architecture': 'arm64',
    'type': type,
    'objects': {
      for (final role
          in type == 'gaoos-bundle'
              ? ['kernel', 'initrd', 'root']
              : ['payload'])
        role: {'digest': 'sha256:${'b' * 64}', 'size_bytes': 4096},
    },
    if (type == 'gaoos-bundle') ...{
      'guest_profile': 'gaoos',
      'version': '2026.10',
      'build_id': 'nightly-20261009',
      'channel': 'nightly',
      'gaoos': {
        'kernel': 'kernel',
        'initrd': 'initrd',
        'root_disk': 'root',
        'default_command_line': 'console=hvc0',
        'guest_agent_expected': true,
      },
    },
  },
  'created_at': '2026-10-09T08:00:00Z',
};

Future<void> _connectImages(
  WidgetTester tester,
  _ApiFixture api, {
  Widget app = const GaoVmApp(),
}) async {
  await tester.pumpWidget(app);
  await tester.tap(find.widgetWithText(TextButton, 'Images'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), api.socketPath);
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
}
