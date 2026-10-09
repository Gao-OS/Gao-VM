part of 'catalog_test.dart';

void _eventJournalTests() {
  testWidgets(
    'the event journal reads typed SSE records only after an explicit start',
    (tester) async {
      await _desktop(tester);
      final release = (await tester.runAsync(() async => Completer<void>()))!;
      final sent = (await tester.runAsync(() async => Completer<void>()))!;
      final queries = <Map<String, String>>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            queries.add(request.uri.queryParameters);
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.bufferOutput = false;
            request.response.write(': connected\n\n');
            _writeEvent(request.response, _eventRecord());
            await request.response.flush();
            sent.complete();
            await release.future;
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        return api.close();
      });
      await _connectEvents(tester, api);
      expect(api.requests, isEmpty);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _untilSignal(tester, sent);
      expect(find.textContaining('Exception'), findsNothing);
      await _until(tester, find.text('vm.phase_changed'));
      expect(find.text('Resume cursor · 42'), findsOneWidget);
      expect(find.text('Select an event'), findsOneWidget);
      await tester.tap(find.text('evt_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      expect(find.text('Event · 42'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('"driver_generation": 7'),
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('event-detail-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('"driver_generation": 7'), findsOneWidget);
      expect(find.text('2026-10-09T08:00:00.000Z'), findsOneWidget);
      expect(find.text('Select a VM'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      release.complete();
      expect(queries, [
        {'after_sequence': '0'},
      ]);
      expect(api.requests, ['GET /v1/events']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'event EOF retains records and resumes on the configured socket',
    (tester) async {
      await _desktop(tester);
      final release = (await tester.runAsync(() async => Completer<void>()))!;
      final queries = <Map<String, String>>[];
      final headers = <String?>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            queries.add(request.uri.queryParameters);
            headers.add(request.headers.value('Last-Event-ID'));
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.bufferOutput = false;
            _writeEvent(
              request.response,
              _eventRecord(
                sequence: queries.length == 1 ? 42 : 47,
                eventId: queries.length == 1
                    ? 'evt_01J00000000000000000000000'
                    : 'evt_01J00000000000000000000001',
              ),
            );
            await request.response.flush();
            if (queries.length > 1) await release.future;
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        return api.close();
      });
      await _connectEvents(tester, api);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Stream interrupted'));
      expect(find.text('Resume cursor · 42'), findsOneWidget);
      expect(find.text('evt_01J00000000000000000000000'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        '/unsubmitted/socket.sock',
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(api.requests, ['GET /v1/events']);
      await tester.runAsync(() async => tester.tap(find.text('Resume stream')));
      await _until(tester, find.text('Resume cursor · 47'));
      expect(find.text('evt_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('evt_01J00000000000000000000001'), findsOneWidget);
      expect(find.text('Stream interrupted'), findsNothing);
      expect(queries, [
        {'after_sequence': '0'},
        {'after_sequence': '42'},
      ]);
      expect(headers, [null, '42']);
      await tester.pumpWidget(const SizedBox.shrink());
      release.complete();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'event filters start a new typed scope; resume ignores draft edits',
    (tester) async {
      await _desktop(tester);
      final queries = <Map<String, String>>[];
      final headers = <String?>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            queries.add(request.uri.queryParameters);
            headers.add(request.headers.value('Last-Event-ID'));
            final freshScope = queries.length == 3;
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.bufferOutput = false;
            _writeEvent(request.response, {
              ..._eventRecord(
                sequence: freshScope
                    ? 901
                    : queries.length == 1
                    ? 42
                    : 47,
                eventId: 'evt_01J0000000000000000000000${queries.length - 1}',
              ),
              'resource_id': freshScope
                  ? 'vm_01J00000000000000000000009'
                  : 'vm_01J00000000000000000000000',
              'vm_id': freshScope
                  ? 'vm_01J00000000000000000000009'
                  : 'vm_01J00000000000000000000000',
              'operation_id': freshScope
                  ? 'op_01J00000000000000000000009'
                  : 'op_01J00000000000000000000001',
              'test_run_id': freshScope
                  ? 'tr_01J00000000000000000000009'
                  : 'tr_01J00000000000000000000002',
            });
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectEvents(tester, api);
      await _setEventFilters(
        tester,
        vm: 'vm_01J00000000000000000000000',
        operation: 'op_01J00000000000000000000001',
        testRun: 'tr_01J00000000000000000000002',
        after: '40',
      );
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Stream interrupted'));
      await tester.tap(find.text('evt_01J00000000000000000000000'));
      await tester.pumpAndSettle();
      expect(find.text('Event · 42'), findsOneWidget);
      await _setEventFilters(
        tester,
        vm: 'vm_01J00000000000000000000009',
        operation: 'op_01J00000000000000000000009',
        testRun: 'tr_01J00000000000000000000009',
        after: '900',
      );
      await tester.runAsync(() async => tester.tap(find.text('Resume stream')));
      await _until(tester, find.text('Resume cursor · 47'));
      await _until(tester, find.text('Stream interrupted'));
      expect(find.text('Event · 42'), findsOneWidget);
      expect(find.text('evt_01J00000000000000000000001'), findsOneWidget);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Resume cursor · 901'));
      expect(find.text('evt_01J00000000000000000000000'), findsNothing);
      expect(find.text('evt_01J00000000000000000000001'), findsNothing);
      expect(find.text('Select an event'), findsOneWidget);
      expect(queries, [
        {
          'after_sequence': '40',
          'vm_id': 'vm_01J00000000000000000000000',
          'operation_id': 'op_01J00000000000000000000001',
          'test_run_id': 'tr_01J00000000000000000000002',
        },
        {
          'after_sequence': '42',
          'vm_id': 'vm_01J00000000000000000000000',
          'operation_id': 'op_01J00000000000000000000001',
          'test_run_id': 'tr_01J00000000000000000000002',
        },
        {
          'after_sequence': '900',
          'vm_id': 'vm_01J00000000000000000000009',
          'operation_id': 'op_01J00000000000000000000009',
          'test_run_id': 'tr_01J00000000000000000000009',
        },
      ]);
      expect(headers, [null, '42', null]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, List.filled(3, 'GET /v1/events'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('event retention evicts old rows and selection, not the cursor', (
    tester,
  ) async {
    await _desktop(tester);
    late _ApiFixture api;
    late _EventPeer peer;
    api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          peer = await _EventPeer.open(request, api);
          await peer.send(
            _eventRecord(sequence: 1, eventId: 'evt_${'1'.padLeft(26, '0')}'),
          );
        },
      ),
    ))!;
    addTearDown(api.close);
    await _connectEvents(tester, api);
    await tester.runAsync(() async => tester.tap(find.text('Start stream')));
    await _until(tester, find.text('Resume cursor · 1'));
    await tester.tap(find.text('evt_${'1'.padLeft(26, '0')}'));
    await tester.pumpAndSettle();
    expect(find.text('Event · 1'), findsOneWidget);
    await tester.runAsync(() async {
      for (var sequence = 2; sequence <= 202; sequence++) {
        await peer.send(
          _eventRecord(
            sequence: sequence,
            eventId: 'evt_${'$sequence'.padLeft(26, '0')}',
          ),
        );
      }
    });
    await _until(tester, find.text('Resume cursor · 202'));
    expect(
      find.text('Retained · 200 events · 2 omitted from this view'),
      findsOneWidget,
    );
    expect(find.text('evt_${'1'.padLeft(26, '0')}'), findsNothing);
    expect(find.text('evt_${'3'.padLeft(26, '0')}'), findsOneWidget);
    expect(find.text('Event · 1'), findsNothing);
    expect(
      find.text('Selected event left the retained window.'),
      findsOneWidget,
    );
    await tester.runAsync(() async => tester.tap(find.text('Pause stream')));
    await _untilSignal(tester, peer.disconnected);
    expect(api.requests, ['GET /v1/events']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('the event window also bounds retained encoded payload bytes', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.bufferOutput = false;
          for (var sequence = 1; sequence <= 4; sequence++) {
            _writeEvent(request.response, {
              ..._eventRecord(
                sequence: sequence,
                eventId: 'evt_${'$sequence'.padLeft(26, '0')}',
              ),
              'payload': {'output': 'x' * 600000},
            });
          }
          await request.response.close();
        },
      ),
    ))!;
    addTearDown(api.close);
    await _connectEvents(tester, api);
    await tester.runAsync(() async => tester.tap(find.text('Start stream')));
    await _until(tester, find.text('Resume cursor · 4'));
    expect(
      find.text('Retained · 3 events · 1 omitted from this view'),
      findsOneWidget,
    );
    expect(find.text('evt_${'2'.padLeft(26, '0')}'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'a reused event ID cannot advance the cursor or duplicate a row',
    (tester) async {
      await _desktop(tester);
      late _ApiFixture api;
      late _EventPeer peer;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            peer = await _EventPeer.open(request, api);
            await peer.send(_eventRecord());
            await peer.send(_eventRecord(sequence: 47));
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectEvents(tester, api);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Stream interrupted'));
      expect(find.textContaining('reused a retained event ID'), findsOneWidget);
      expect(find.text('Resume cursor · 42'), findsOneWidget);
      expect(
        find.text('Retained · 1 events · 0 omitted from this view'),
        findsOneWidget,
      );
      expect(find.text('evt_01J00000000000000000000000'), findsOneWidget);
      await _untilSignal(tester, peer.disconnected);
      expect(api.requests, ['GET /v1/events']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  for (final field in ['vm_id', 'operation_id', 'test_run_id']) {
    testWidgets(
      'event $field outside the active scope is rejected before consumption',
      (tester) async {
        await _desktop(tester);
        late _ApiFixture api;
        late _EventPeer peer;
        api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              peer = await _EventPeer.open(request, api);
              await peer.send({
                ..._eventRecord(),
                'test_run_id': 'tr_01J00000000000000000000002',
              });
              await peer.send({
                ..._eventRecord(
                  sequence: 47,
                  eventId: 'evt_01J00000000000000000000001',
                ),
                'test_run_id': 'tr_01J00000000000000000000002',
                field:
                    '${field == 'vm_id'
                        ? 'vm'
                        : field == 'operation_id'
                        ? 'op'
                        : 'tr'}_01J00000000000000000000009',
              });
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectEvents(tester, api);
        await _setEventFilters(
          tester,
          vm: 'vm_01J00000000000000000000000',
          operation: 'op_01J00000000000000000000001',
          testRun: 'tr_01J00000000000000000000002',
        );
        await tester.runAsync(
          () async => tester.tap(find.text('Start stream')),
        );
        await _until(tester, find.text('Stream interrupted'));
        expect(
          find.textContaining('event does not match the active scope'),
          findsOneWidget,
        );
        expect(find.text('Resume cursor · 42'), findsOneWidget);
        expect(
          find.text('Retained · 1 events · 0 omitted from this view'),
          findsOneWidget,
        );
        expect(find.text('evt_01J00000000000000000000001'), findsNothing);
        await _untilSignal(tester, peer.disconnected);
        expect(api.requests, ['GET /v1/events']);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final invalid in [
    'extra key',
    'missing payload',
    'payload type',
    'event ID',
    'event type',
    'sequence mismatch',
    'duplicate sequence',
    'old sequence',
    'truncated frame',
    'duplicate SSE id',
    'oversized frame',
  ]) {
    testWidgets(
      'event $invalid preserves the last validated record and cursor',
      (tester) async {
        await _desktop(tester);
        final event = _eventRecord(
          sequence: 47,
          eventId: 'evt_01J00000000000000000000001',
        );
        switch (invalid) {
          case 'extra key':
            event['unexpected'] = true;
          case 'missing payload':
            event.remove('payload');
          case 'payload type':
            event['payload'] = [];
          case 'event ID':
            event['event_id'] = 'vm_01J00000000000000000000001';
          case 'event type':
            event['type'] = 'VM changed';
          case 'sequence mismatch':
            event['sequence'] = 48;
          case 'duplicate sequence':
            event['sequence'] = 42;
          case 'old sequence':
            event['sequence'] = 41;
          case 'oversized frame':
            event['payload'] = {'output': 'x' * (1024 * 1024)};
        }
        final frame = switch (invalid) {
          'truncated frame' => 'id: 47\ndata: ${jsonEncode(event)}\n',
          'duplicate SSE id' =>
            'id: 47\nid: 47\ndata: ${jsonEncode(event)}\n\n',
          'sequence mismatch' => 'id: 47\ndata: ${jsonEncode(event)}\n\n',
          _ => 'id: ${event['sequence']}\ndata: ${jsonEncode(event)}\n\n',
        };
        final api = (await tester.runAsync(
          () => _ApiFixture.open(
            handler: (request) async {
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
              );
              request.response.bufferOutput = false;
              _writeEvent(request.response, _eventRecord());
              request.response.write(frame);
              await request.response.close();
            },
          ),
        ))!;
        addTearDown(api.close);
        await _connectEvents(tester, api);
        await tester.runAsync(
          () async => tester.tap(find.text('Start stream')),
        );
        await _until(tester, find.text('Stream interrupted'));
        expect(find.textContaining('SSE'), findsOneWidget);
        expect(find.text('Resume cursor · 42'), findsOneWidget);
        expect(
          find.text('Retained · 1 events · 0 omitted from this view'),
          findsOneWidget,
        );
        expect(find.text('evt_01J00000000000000000000000'), findsOneWidget);
        expect(find.text('evt_01J00000000000000000000001'), findsNothing);
        expect(api.requests, ['GET /v1/events']);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final headers in [true, false]) {
    for (final exit in ['pause', 'pane change', 'connect', 'window close']) {
      testWidgets(
        'event $exit releases the actual ${headers ? 'idle' : 'pre-header'} socket',
        (tester) async {
          await _desktop(tester);
          final arrived = (await tester.runAsync(
            () async => Completer<void>(),
          ))!;
          late _ApiFixture api;
          late _EventPeer peer;
          api = (await tester.runAsync(
            () => _ApiFixture.open(
              handler: (request) async {
                if (request.uri.path != '/v1/events') {
                  await _reply(request, {'items': [], 'next_cursor': null});
                  return;
                }
                peer = await _EventPeer.open(request, api, headers: headers);
                if (headers) {
                  await peer.write(': connected\n\n: heartbeat id: 999\n\n');
                }
                arrived.complete();
              },
            ),
          ))!;
          addTearDown(api.close);
          await _connectEvents(tester, api);
          await tester.runAsync(
            () async => tester.tap(find.text('Start stream')),
          );
          await _untilSignal(tester, arrived);
          expect(find.text('Resume cursor · 0'), findsOneWidget);
          expect(
            find.text('Retained · 0 events · 0 omitted from this view'),
            findsOneWidget,
          );
          switch (exit) {
            case 'pause':
              await tester.runAsync(
                () async => tester.tap(find.text('Pause stream')),
              );
            case 'pane change':
              await tester.runAsync(
                () async =>
                    tester.tap(find.widgetWithText(TextButton, 'Operations')),
              );
            case 'connect':
              await tester.runAsync(
                () async => tester.tap(find.text('Connect')),
              );
            case 'window close':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          await _untilSignal(tester, peer.disconnected);
          if (exit == 'pane change') {
            await _until(tester, find.text('No Operations'));
          }
          if (exit == 'pause') {
            expect(find.text('Stream paused'), findsOneWidget);
          }
          expect(api.requests, [
            'GET /v1/events',
            if (exit == 'pane change') 'GET /v1/operations',
          ]);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('invalid event drafts cannot clear the last validated scope', (
    tester,
  ) async {
    await _desktop(tester);
    final queries = <Map<String, String>>[];
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          queries.add(request.uri.queryParameters);
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          _writeEvent(
            request.response,
            _eventRecord(
              sequence: queries.length == 1 ? 42 : 47,
              eventId: queries.length == 1
                  ? 'evt_01J00000000000000000000000'
                  : 'evt_01J00000000000000000000001',
            ),
          );
          await request.response.close();
        },
      ),
    ))!;
    addTearDown(api.close);
    await _connectEvents(tester, api);
    await tester.runAsync(() async => tester.tap(find.text('Start stream')));
    await _until(tester, find.text('Stream interrupted'));
    for (final invalid in [
      ('event-after-filter', '-1'),
      ('event-after-filter', '+1'),
      ('event-after-filter', '1.5'),
      ('event-after-filter', '9223372036854775808'),
      ('event-vm-filter', 'default'),
      ('event-operation-filter', 'vm_01J00000000000000000000000'),
      ('event-test-run-filter', 'op_01J00000000000000000000000'),
    ]) {
      await _setEventFilters(tester);
      await tester.enterText(find.byKey(ValueKey(invalid.$1)), invalid.$2);
      await tester.tap(find.text('Start stream'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Invalid event scope:'), findsOneWidget);
      expect(find.text('Resume cursor · 42'), findsOneWidget);
      expect(find.text('evt_01J00000000000000000000000'), findsOneWidget);
      expect(api.requests, ['GET /v1/events']);
    }
    await tester.runAsync(() async => tester.tap(find.text('Resume stream')));
    await _until(tester, find.text('Resume cursor · 47'));
    expect(find.textContaining('Invalid event scope:'), findsNothing);
    expect(queries, [
      {'after_sequence': '0'},
      {'after_sequence': '42'},
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['problem', 'content type', 'success status']) {
    testWidgets('event $failure is a failed stream, not an empty journal', (
      tester,
    ) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (failure == 'problem') {
              request.response.statusCode = 400;
              await _reply(request, {
                'type': 'https://gaovm.dev/problems/invalid-request',
                'title': 'Invalid event cursor',
                'status': 400,
                'detail': 'The daemon rejected this event scope.',
                'code': 'INVALID_REQUEST',
                'request_id': 'req_01J00000000000000000000009',
                'operation_id': null,
                'retryable': false,
                'details': {},
              });
            } else {
              request.response.statusCode = failure == 'success status'
                  ? 201
                  : 200;
              request.response.headers.contentType = failure == 'content type'
                  ? ContentType.json
                  : ContentType('text', 'event-stream');
              _writeEvent(request.response, _eventRecord());
              await request.response.close();
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connectEvents(tester, api);
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Stream interrupted'));
      if (failure == 'problem') {
        expect(find.text('INVALID_REQUEST'), findsOneWidget);
        expect(find.text('req_01J00000000000000000000009'), findsOneWidget);
        expect(find.text('Not retryable'), findsOneWidget);
      } else {
        expect(find.text('expected an SSE response'), findsOneWidget);
      }
      expect(find.text('Resume cursor · 0'), findsOneWidget);
      expect(
        find.text('Retained · 0 events · 0 omitted from this view'),
        findsOneWidget,
      );
      expect(find.text('evt_01J00000000000000000000000'), findsNothing);
      expect(api.requests, ['GET /v1/events']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'the event journal renders system and non-VM resources with bundled fonts',
    (tester) async {
      await _desktop(tester);
      late _ApiFixture api;
      late _EventPeer peer;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            peer = await _EventPeer.open(request, api);
            await peer.send(_eventRecord());
            await peer.send({
              ..._eventRecord(
                sequence: 43,
                eventId: 'evt_01J00000000000000000000001',
              ),
              'type': 'daemon.ready',
              'resource_type': 'system',
              'resource_id': null,
              'vm_id': null,
              'operation_id': null,
              'test_run_id': null,
              'payload': {
                'transport': 'http+unix',
                'boot_id': 'fixture-session',
              },
            });
            await peer.send({
              ..._eventRecord(
                sequence: 47,
                eventId: 'evt_01J00000000000000000000002',
              ),
              'type': 'image.imported',
              'resource_type': 'image',
              'resource_id': 'img_01J00000000000000000000000',
              'vm_id': null,
              'payload': {'revision': 1},
            });
          },
        ),
      ))!;
      addTearDown(api.close);
      const previewKey = Key('event-preview');
      await _connectEvents(
        tester,
        api,
        app: const RepaintBoundary(key: previewKey, child: GaoVmApp()),
      );
      await tester.runAsync(() async => tester.tap(find.text('Start stream')));
      await _until(tester, find.text('Resume cursor · 47'));
      expect(find.text('Scope · all resources'), findsOneWidget);
      expect(find.text('image.imported'), findsOneWidget);
      await tester.tap(find.text('evt_01J00000000000000000000001'));
      await tester.pumpAndSettle();
      expect(find.text('Event · 43'), findsOneWidget);
      expect(find.text('system'), findsOneWidget);
      expect(find.text('No VM correlation'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/ui-events-preview.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.scrollUntilVisible(
        find.textContaining('"boot_id": "fixture-session"'),
        160,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('event-detail-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('No TestRun correlation'), findsOneWidget);
      expect(find.text('No Operation correlation'), findsOneWidget);
      expect(find.text('Select a VM'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _untilSignal(tester, peer.disconnected);
      expect(api.requests, ['GET /v1/events']);
      expect(tester.takeException(), isNull);
    },
  );
}

class _EventPeer {
  _EventPeer(this.socket) {
    socket.listen((_) {}, onDone: _closed, onError: (Object _) => _closed());
  }

  final Socket socket;
  final disconnected = Completer<void>();

  static Future<_EventPeer> open(
    HttpRequest request,
    _ApiFixture api, {
    bool headers = true,
  }) async {
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.headers.chunkedTransferEncoding = false;
    request.response.persistentConnection = false;
    final socket = await request.response.detachSocket(writeHeaders: headers);
    api.detached.add(socket);
    return _EventPeer(socket);
  }

  void _closed() {
    if (!disconnected.isCompleted) disconnected.complete();
  }

  Future<void> send(Map<String, Object?> event) =>
      write('id: ${event['sequence']}\ndata: ${jsonEncode(event)}\n\n');

  Future<void> write(String frame) async {
    socket.add(utf8.encode(frame));
    await socket.flush();
  }
}

Map<String, Object?> _eventRecord({
  int sequence = 42,
  String eventId = 'evt_01J00000000000000000000000',
}) => {
  'sequence': sequence,
  'event_id': eventId,
  'type': 'vm.phase_changed',
  'resource_type': 'virtual_machine',
  'resource_id': 'vm_01J00000000000000000000000',
  'vm_id': 'vm_01J00000000000000000000000',
  'operation_id': 'op_01J00000000000000000000001',
  'test_run_id': null,
  'payload': {'phase': 'running', 'driver_generation': 7},
  'occurred_at': '2026-10-09T08:00:00Z',
};

void _writeEvent(HttpResponse response, Map<String, Object?> event) =>
    response.write('id: ${event['sequence']}\ndata: ${jsonEncode(event)}\n\n');

Future<void> _connectEvents(
  WidgetTester tester,
  _ApiFixture api, {
  Widget app = const GaoVmApp(),
}) async {
  await tester.pumpWidget(app);
  await tester.tap(find.widgetWithText(TextButton, 'Events'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, api.socketPath);
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
  await tester.pumpAndSettle();
}

Future<void> _setEventFilters(
  WidgetTester tester, {
  String vm = '',
  String operation = '',
  String testRun = '',
  String after = '0',
}) async {
  await tester.enterText(find.byKey(const ValueKey('event-vm-filter')), vm);
  await tester.enterText(
    find.byKey(const ValueKey('event-operation-filter')),
    operation,
  );
  await tester.enterText(
    find.byKey(const ValueKey('event-test-run-filter')),
    testRun,
  );
  await tester.enterText(
    find.byKey(const ValueKey('event-after-filter')),
    after,
  );
}
