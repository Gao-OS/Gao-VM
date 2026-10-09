import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_mcp/gaovm_mcp.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late GaoVmDatabase database;
  late PublicApiServer api;
  late SqliteVmRepository vms;
  late _McpClient mcp;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('gvm-mcp-');
    imageFileMode(root.path, 0x1c0);
    database = await GaoVmDatabase.open('${root.path}/catalog.db');
    vms = SqliteVmRepository(database);
    final operations = SqliteOperationRepository(database);
    final router = PublicApiRouter();
    final outside = _ReadOnlyVm();
    ResourceApiHandlers(
      vms: VmApplicationService.composed(
        repository: vms,
        creates: SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ),
        patches: outside,
        lifecycle: outside,
        waiter: outside,
      ),
      operations: OperationApplicationService(
        repository: operations,
        mutations: _ReadOnlyOperations(),
        waiter: SqliteOperationWaiter(
          operations: operations,
          events: SqliteDurableEventFeed(database),
        ),
      ),
    ).register(router);
    api = PublicApiServer(
      socketPath: '${root.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await api.start();
    mcp = _McpClient(
      GaoVmMcpServer(api: GaoVmApiClient(socketPath: api.socketPath)),
    );
  });

  tearDown(() async {
    await mcp.close();
    await api.close();
    database.close();
    await root.delete(recursive: true);
  });

  test('stdio VM list agrees with the CLI public API catalog', () async {
    await vms.create(name: 'MCP catalog', spec: _spec());
    final cliOutput = StringBuffer();
    final cliError = StringBuffer();
    final code = await runCli(
      ['--socket-path', api.socketPath, 'vm', 'list', '--json'],
      output: cliOutput.writeln,
      error: cliError.writeln,
    );
    expect(code, 0, reason: cliError.toString());

    final reply = await mcp.call('vm_list');
    expect(reply['jsonrpc'], '2.0');
    expect(reply['id'], 1);
    final result = reply['result'] as Map;
    expect(result['resultType'], 'complete');
    expect(result['isError'], isFalse);
    expect(result['structuredContent'], jsonDecode(cliOutput.toString()));
    expect(
      jsonDecode((result['content'] as List).single['text'] as String),
      result['structuredContent'],
    );
  });

  test(
    'modern discovery declares its tools without an initialize session',
    () async {
      final reply = await mcp.request('server/discover');
      final result = reply['result'] as Map;
      expect(result['resultType'], 'complete');
      expect(result['supportedVersions'], contains('2026-07-28'));
      expect(result['capabilities'], {'tools': {}});
      expect(result['_meta']['io.modelcontextprotocol/serverInfo'], {
        'name': 'gaovm-mcp',
        'version': '0.1.0',
      });
    },
  );

  test('initialization-era clients share the same public VM catalog', () async {
    final vm = await vms.create(name: 'legacy MCP client', spec: _spec());
    final initialized = await mcp.legacyRequest(
      'initialize',
      params: {
        'protocolVersion': '2025-11-25',
        'capabilities': {},
        'clientInfo': {'name': 'test-client', 'version': '1.0'},
      },
    );
    expect(initialized, containsPair('result', isA<Map>()));
    expect(initialized['result']['protocolVersion'], '2025-11-25');
    expect(initialized['result']['capabilities'], {'tools': {}});
    expect(initialized['result']['serverInfo']['name'], 'gaovm-mcp');
    mcp.notify('notifications/initialized');
    final tools = await mcp.legacyRequest('tools/list');
    expect(tools['result']['tools'], hasLength(16));
    expect((tools['result'] as Map).containsKey('resultType'), isFalse);
    final listed = await mcp.legacyRequest(
      'tools/call',
      params: {'name': 'vm_list', 'arguments': {}},
    );
    expect(listed['result']['structuredContent']['items'], [vm.toJson()]);
    expect((listed['result'] as Map).containsKey('resultType'), isFalse);
    final modern = await mcp.call('vm_list');
    expect(modern['result']['resultType'], 'complete');
    expect(
      modern['result']['structuredContent'],
      listed['result']['structuredContent'],
    );
  });

  test(
    'legacy negotiation never downgrades explicit modern requests',
    () async {
      final before = await mcp.legacyRequest('tools/list');
      expect(before['error']['code'], -32602);
      final ping = await mcp.legacyRequest('ping');
      expect(ping['result'], isEmpty);
      final invalid = await mcp.legacyRequest(
        'initialize',
        params: {'protocolVersion': '2025-11-25', 'capabilities': {}},
      );
      expect(invalid['error']['code'], -32602);
      final initialized = await mcp.legacyRequest(
        'initialize',
        params: {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'older-client', 'version': '1.0'},
        },
      );
      expect(initialized['result']['protocolVersion'], '2025-11-25');
      final premature = await mcp.legacyRequest('tools/list');
      expect(premature['error']['code'], -32602);
      mcp.notify('notifications/initialized');
      final unsupported = await mcp.request(
        'tools/list',
        params: {
          '_meta': {
            'io.modelcontextprotocol/protocolVersion': '1900-01-01',
            'io.modelcontextprotocol/clientCapabilities': {},
          },
        },
      );
      expect(unsupported['error']['code'], -32022);
      final incomplete = await mcp.request(
        'tools/list',
        params: {
          '_meta': {'io.modelcontextprotocol/clientCapabilities': {}},
        },
      );
      expect(incomplete['error']['code'], -32602);
      final next = await mcp.legacyRequest(
        'tools/list',
        params: {
          '_meta': {'progressToken': 'legacy-trace'},
        },
      );
      expect(next['result']['tools'], hasLength(16));
      final modernPing = await mcp.request('ping');
      expect(modernPing['error']['code'], -32601);
    },
  );

  test(
    'tool discovery describes the frozen plan and public request bodies',
    () async {
      final reply = await mcp.request('tools/list');
      final tools = (reply['result'] as Map)['tools'] as List;
      expect(tools.map((tool) => tool['name']), [
        'vm_list',
        'vm_get',
        'vm_create',
        'vm_clone',
        'vm_start',
        'vm_stop',
        'vm_wait',
        'vm_logs',
        'image_list',
        'image_import',
        'guest_exec',
        'operation_get',
        'operation_cancel',
        'test_run',
        'test_status',
        'test_artifacts',
      ]);
      final create = tools.singleWhere((tool) => tool['name'] == 'vm_create');
      final schema = create['inputSchema'] as Map;
      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], containsAll(['body', 'idempotency_key']));
      final body = schema['properties']['body'] as Map;
      expect(body['required'], ['api_version', 'kind', 'metadata', 'spec']);
      expect(body['properties']['spec']['properties']['architecture']['enum'], [
        'arm64',
      ]);
      expect(tools.any((tool) => tool['name'] == 'driver.exec'), isFalse);
    },
  );

  test('VM get returns the same resource as another public client', () async {
    final vm = await vms.create(name: 'shared resource', spec: _spec());
    final reply = await mcp.call('vm_get', {'vm_id': vm.metadata.id.value});
    final result = reply['result'] as Map;
    expect(result['structuredContent'], vm.toJson());
    expect(result['isError'], isFalse);
    expect(result['_meta']['dev.gaovm/requestId'], startsWith('req_'));
    expect(result['_meta']['dev.gaovm/etag'], '"1"');
  });

  test('API Problems keep their structured error and do not end MCP', () async {
    final reply = await mcp.call('vm_get', {'vm_id': VmId.generate().value});
    final result = reply['result'] as Map;
    expect(result['isError'], isTrue);
    final problem = Problem.fromJson(result['structuredContent']);
    expect(problem.code, ErrorCode.vmNotFound);
    expect(problem.status, 404);
    expect(problem.requestId.value, startsWith('req_'));
    expect(result['_meta']['dev.gaovm/requestId'], problem.requestId.value);
    final next = await mcp.call('vm_list');
    expect(next['result']['isError'], isFalse);
  });

  test(
    'MCP create returns a durable Operation and replays across the CLI',
    () async {
      final manifest = ImageManifest.create(
        type: ImageType.linuxKernel,
        objects: {
          'payload': {
            'digest': contentDigest('kernel fixture'),
            'size_bytes': 1,
          },
        },
      );
      final kernel = Image(
        id: ImageId.generate(),
        digest: manifest.digest,
        type: ImageType.linuxKernel,
        architecture: Architecture.arm64,
        manifest: JsonObjectValue.fromJson(manifest.toJson()),
        createdAt: DateTime.now().toUtc(),
      );
      await ImageRepository(database).insert(kernel);
      final body = {
        'api_version': vmApiVersion,
        'kind': vmKind,
        'metadata': {'name': 'created through MCP'},
        'spec': _spec(kernel: kernel.id).toJson(),
      };
      final reply = await mcp.call('vm_create', {
        'body': body,
        'idempotency_key': 'create-once',
      });
      expect(reply['result']['isError'], isFalse);
      final acceptance = OperationAcceptance.fromJson(
        reply['result']['structuredContent'],
      );
      expect(acceptance.state, OperationState.pending);
      final cliOutput = StringBuffer();
      final cliError = StringBuffer();
      final code = await runCli(
        [
          '--socket-path',
          api.socketPath,
          'vm',
          'create',
          '--json',
          '--body-json',
          jsonEncode(body),
          '--idempotency-key',
          'create-once',
        ],
        output: cliOutput.writeln,
        error: cliError.writeln,
      );
      expect(code, 0, reason: cliError.toString());
      expect(jsonDecode(cliOutput.toString()), acceptance.toJson());
      final operation = await mcp.call('operation_get', {
        'operation_id': acceptance.operationId.value,
      });
      expect(
        operation['result']['structuredContent']['resource_id'],
        acceptance.resourceId.value,
      );
      final listed = await mcp.call('vm_list');
      expect(listed['result']['structuredContent']['items'], hasLength(1));
    },
  );

  for (final mode in ['cancellation', 'EOF']) {
    test(
      'local MCP $mode preserves an already accepted durable Operation',
      () async {
        final manifest = ImageManifest.create(
          type: ImageType.linuxKernel,
          objects: {
            'payload': {
              'digest': contentDigest('kernel fixture'),
              'size_bytes': 1,
            },
          },
        );
        final kernel = Image(
          id: ImageId.generate(),
          digest: manifest.digest,
          type: ImageType.linuxKernel,
          architecture: Architecture.arm64,
          manifest: JsonObjectValue.fromJson(manifest.toJson()),
          createdAt: DateTime.now().toUtc(),
        );
        await ImageRepository(database).insert(kernel);
        final body = {
          'api_version': vmApiVersion,
          'kind': vmKind,
          'metadata': {'name': 'accepted before MCP $mode'},
          'spec': _spec(kernel: kernel.id).toJson(),
        };
        final accepted = Completer<OperationAcceptance>();
        final release = Completer<void>();
        final paths = <String>[];
        await _withHttpMcp(
          root,
          (request) async {
            paths.add(request.uri.path);
            final response = await GaoVmApiClient(socketPath: api.socketPath)
                .request(
                  request.method,
                  request.uri.path,
                  body: JsonObjectValue.fromJson(
                    jsonDecode(await utf8.decoder.bind(request).join()),
                  ),
                  idempotencyKey: request.headers.value('idempotency-key'),
                );
            accepted.complete(
              OperationAcceptance.fromJson(response.body.toJson()),
            );
            // Hold the reply after real SQLite acceptance, not before dispatch.
            await release.future;
          },
          (client) async {
            try {
              final id = client.sendRequest(
                'tools/call',
                params: {
                  'name': 'vm_create',
                  'arguments': {
                    'body': body,
                    'idempotency_key': 'accepted-once',
                  },
                },
              );
              final operation = await accepted.future.timeout(
                const Duration(seconds: 3),
              );
              expect(operation.state, OperationState.pending);
              if (mode == 'cancellation') {
                client.notify(
                  'notifications/cancelled',
                  params: {'requestId': id},
                );
                expect(
                  (await client.request(
                    'server/discover',
                  ))['result']['resultType'],
                  'complete',
                );
              } else {
                await client.finishInput();
                await client.finished.timeout(const Duration(seconds: 3));
              }
              final output = StringBuffer();
              final error = StringBuffer();
              expect(
                await runCli(
                  [
                    '--socket-path',
                    api.socketPath,
                    'vm',
                    'create',
                    '--json',
                    '--body-json',
                    jsonEncode(body),
                    '--idempotency-key',
                    'accepted-once',
                  ],
                  output: output.writeln,
                  error: error.writeln,
                ),
                0,
                reason: error.toString(),
              );
              expect(jsonDecode(output.toString()), operation.toJson());
              final status = await mcp.call('operation_get', {
                'operation_id': operation.operationId.value,
              });
              expect(status['result']['structuredContent']['state'], 'pending');
              expect(
                status['result']['structuredContent']['resource_id'],
                operation.resourceId.value,
              );
              expect(paths, ['/v1/vms']);
            } finally {
              release.complete();
            }
          },
        );
      },
    );
  }

  test('unknown and driver-passthrough tools are protocol errors', () async {
    for (final name in ['driver.exec', 'not_a_tool']) {
      final reply = await mcp.call(name);
      expect(reply['error']['code'], -32602);
      expect(reply.containsKey('result'), isFalse);
    }
    final next = await mcp.call('vm_list');
    expect(next['result']['isError'], isFalse);
  });

  test(
    'invalid identities, options and unsafe retries fail as tool errors',
    () async {
      for (final (name, arguments) in [
        ('vm_get', {'vm_id': 'default'}),
        ('vm_get', {'vm_id': OperationId.generate().value}),
        ('vm_start', {'vm_id': VmId.generate().value}),
        ('vm_list', {'limit': 0}),
        ('vm_list', {'request_timeout_seconds': 0}),
        ('vm_list', {'driver_socket': '/some/private/driver.sock'}),
      ]) {
        final reply = await mcp.call(name, arguments);
        expect(reply['result']['isError'], isTrue, reason: '$name $arguments');
        expect(
          reply['result']['structuredContent']['code'],
          'MCP_INVALID_ARGUMENT',
        );
      }
      final next = await mcp.call('vm_list');
      expect(next['result']['isError'], isFalse);
    },
  );
  test(
    'modern protocol metadata is validated independently on every request',
    () async {
      final unsupported = await mcp.request(
        'tools/list',
        params: {
          '_meta': {
            'io.modelcontextprotocol/protocolVersion': '1900-01-01',
            'io.modelcontextprotocol/clientCapabilities': {},
          },
        },
      );
      expect(unsupported['error']['code'], -32022);
      expect(unsupported['error']['data']['requested'], '1900-01-01');
      expect(unsupported['error']['data']['supported'], contains('2026-07-28'));
      final absent = await mcp.request('tools/list', params: {'_meta': null});
      expect(absent['error']['code'], -32602);
      final valid = await mcp.request('tools/list');
      expect(valid['result']['tools'], hasLength(16));
    },
  );
  test(
    'malformed frames and unknown methods do not corrupt later requests',
    () async {
      final malformed = await mcp.raw('not JSON\n');
      expect(malformed['error']['code'], -32700);
      expect(malformed['id'], isNull);
      for (final method in ['driver.exec', 'ping']) {
        final unknown = await mcp.request(method, params: {'name': 'vm_list'});
        expect(unknown['error']['code'], -32601);
      }
      final next = await mcp.request('server/discover');
      expect(next['result']['resultType'], 'complete');
    },
  );
  test(
    'invalid envelopes are rejected and notifications receive no reply',
    () async {
      for (final envelope in [
        null,
        [],
        {'jsonrpc': '1.0', 'id': 21, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': null, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': true, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': {}, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 1.5, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 21, 'method': 7},
      ]) {
        final reply = await mcp.raw('${jsonEncode(envelope)}\n');
        expect(reply['error']['code'], -32600, reason: '$envelope');
        expect(reply['id'], isNull);
      }
      mcp.notify('notifications/initialized');
      mcp.notify('notifications/not_supported');
      final next = await mcp.request('server/discover');
      expect(next['id'], 1);
      expect(next['result']['resultType'], 'complete');
    },
  );
  test(
    'non-object tool arguments are protocol errors, not session failures',
    () async {
      for (final arguments in [null, [], 'invalid', true]) {
        final reply = await mcp.request(
          'tools/call',
          params: {'name': 'vm_list', 'arguments': arguments},
        );
        expect(reply['error']['code'], -32602, reason: '$arguments');
      }
      final next = await mcp.call('vm_list');
      expect(next['result']['isError'], isFalse);
    },
  );
  test('an unavailable public API is a structured tool error', () async {
    await api.close();
    final reply = await mcp.call('vm_list');
    expect(reply['result']['isError'], isTrue);
    expect(reply['result']['structuredContent']['code'], 'MCP_API_UNAVAILABLE');
    expect(reply['result']['structuredContent']['retryable'], isTrue);
    final next = await mcp.request('server/discover');
    expect(next['result']['resultType'], 'complete');
  });
  test('the advertised HTTP deadline returns a structured timeout', () async {
    await _withHttpMcp(
      root,
      (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"items":[],"next_cursor":null}');
        await request.response.close();
      },
      (client) async {
        final reply = await client.call('vm_list', {
          'request_timeout_seconds': 0.05,
        });
        expect(reply['result']['isError'], isTrue);
        expect(reply['result']['structuredContent']['code'], 'MCP_API_TIMEOUT');
        final next = await client.request('server/discover');
        expect(next['result']['resultType'], 'complete');
      },
    );
  });
  test('invalid public API responses remain structured tool errors', () async {
    await _withHttpMcp(
      root,
      (request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('not the public JSON contract');
        await request.response.close();
      },
      (client) async {
        final reply = await client.call('vm_list');
        expect(reply['result']['isError'], isTrue);
        expect(
          reply['result']['structuredContent']['code'],
          'MCP_API_PROTOCOL',
        );
        expect(reply['result']['structuredContent']['retryable'], isFalse);
        final next = await client.request('server/discover');
        expect(next['result']['resultType'], 'complete');
      },
    );
  });
  test('a pending HTTP tool does not block protocol discovery', () async {
    final received = Completer<void>();
    final release = Completer<void>();
    await _withHttpMcp(
      root,
      (request) async {
        received.complete();
        await release.future;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"items":[],"next_cursor":null}');
        await request.response.close();
      },
      (client) async {
        try {
          final slow = client.sendRequest(
            'tools/call',
            params: {'name': 'vm_list', 'arguments': {}},
          );
          await received.future.timeout(const Duration(seconds: 2));
          final fast = client.sendRequest('server/discover');
          final discovery = await client.receive(
            timeout: const Duration(seconds: 2),
          );
          expect(discovery['id'], fast);
          expect(discovery['result']['resultType'], 'complete');
          release.complete();
          final tool = await client.receive();
          expect(tool['id'], slow);
          expect(tool['result']['isError'], isFalse);
        } finally {
          if (!release.isCompleted) release.complete();
        }
      },
    );
  });
  test(
    'MCP cancellation closes HTTP and sends no late tool response',
    () async {
      final socketPath = '${root.path}/cancel.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      final received = Completer<void>();
      final peerClosed = Completer<void>();
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (bytes) {
            if (!received.isCompleted) received.complete();
          },
          onDone: () {
            if (!peerClosed.isCompleted) peerClosed.complete();
          },
        );
      });
      final client = _McpClient(
        GaoVmMcpServer(api: GaoVmApiClient(socketPath: socketPath)),
      );
      try {
        final cancelled = client.sendRequest(
          'tools/call',
          params: {'name': 'vm_list', 'arguments': {}},
        );
        await received.future.timeout(const Duration(seconds: 2));
        client.notify(
          'notifications/cancelled',
          params: {'requestId': cancelled},
        );
        await peerClosed.future.timeout(const Duration(seconds: 2));
        final next = client.sendRequest('server/discover');
        final reply = await client.receive();
        expect(reply['id'], next);
        expect(reply['result']['resultType'], 'complete');
        final tools = await client.request('tools/list');
        expect(tools['result']['tools'], hasLength(16));
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await client.close();
        await listener.close();
        await subscription.cancel();
      }
    },
  );
  test(
    'input EOF releases pending HTTP instead of waiting for its deadline',
    () async {
      final socketPath = '${root.path}/eof.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      final received = Completer<void>();
      final peerClosed = Completer<void>();
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (bytes) {
            if (!received.isCompleted) received.complete();
          },
          onDone: () {
            if (!peerClosed.isCompleted) peerClosed.complete();
          },
        );
      });
      final client = _McpClient(
        GaoVmMcpServer(api: GaoVmApiClient(socketPath: socketPath)),
      );
      try {
        client.sendRequest(
          'tools/call',
          params: {'name': 'vm_list', 'arguments': {}},
        );
        await received.future.timeout(const Duration(seconds: 2));
        await client.finishInput();
        await peerClosed.future.timeout(const Duration(seconds: 2));
        await client.finished.timeout(const Duration(seconds: 2));
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await client.close();
        await listener.close();
        await subscription.cancel();
      }
    },
  );
  test(
    'tool saturation returns a retryable error without blocking discovery',
    () async {
      final full = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      await _withHttpMcp(
        root,
        (request) async {
          if (++calls == 64) full.complete();
          await release.future;
        },
        (client) async {
          try {
            for (var i = 0; i < 64; i++) {
              client.sendRequest('tools/call', params: {'name': 'vm_list'});
            }
            await full.future.timeout(const Duration(seconds: 3));
            client.sendRequest('tools/call', params: {'name': 'vm_list'});
            final busy = await client.receive(
              timeout: const Duration(seconds: 2),
            );
            expect(busy['result']['isError'], isTrue);
            expect(
              busy['result']['structuredContent']['code'],
              'MCP_SERVER_BUSY',
            );
            expect(busy['result']['structuredContent']['retryable'], isTrue);
            expect(calls, 64);
            final discovery = await client.request('server/discover');
            expect(discovery['result']['resultType'], 'complete');
          } finally {
            release.complete();
          }
        },
      );
    },
  );

  test('invalid UTF-8 is an isolated framing error', () async {
    final reply = await mcp.rawBytes([0xff, 10]);
    expect(reply['error']['code'], -32700);
    expect(reply['id'], isNull);
    final next = await mcp.request('server/discover');
    expect(next['result']['resultType'], 'complete');
  });
  test(
    'oversized framing is bounded and recovers at the next newline',
    () async {
      final reply = await mcp.rawBytes(List<int>.filled(1024 * 1024 + 1, 97));
      expect(reply['error']['code'], -32600);
      expect(reply['error']['message'], contains('1 MiB'));
      mcp.sendBytes(utf8.encode('discarded suffix\n'));
      final next = await mcp.request('server/discover');
      expect(next['result']['resultType'], 'complete');
    },
  );

  test(
    'an unterminated EOF frame is rejected before reaching the API',
    () async {
      final calls = <String>[];
      await _withHttpMcp(
        root,
        (request) async {
          calls.add(request.uri.path);
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"items":[],"next_cursor":null}');
          await request.response.close();
        },
        (client) async {
          final reply = client.receive();
          client.sendBytes(
            utf8.encode(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 'partial',
                'method': 'tools/call',
                'params': {
                  '_meta': {
                    'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                    'io.modelcontextprotocol/clientCapabilities': {},
                  },
                  'name': 'vm_list',
                  'arguments': {},
                },
              }),
            ),
          );
          await client.finishInput();
          expect((await reply)['error']['code'], -32700);
          await client.finished;
          expect(calls, isEmpty);
        },
      );
    },
  );
  test('serve waits for asynchronous protocol output to drain', () async {
    final input = StreamController<List<int>>();
    final started = Completer<void>();
    final release = Completer<void>();
    final written = <Map>[];
    final serving =
        GaoVmMcpServer(api: GaoVmApiClient(socketPath: api.socketPath)).serve(
          input.stream,
          (message) async {
            started.complete();
            await release.future;
            written.add(jsonDecode(message) as Map);
          },
        );
    try {
      input.add(
        utf8.encode(
          '${jsonEncode({
            'jsonrpc': '2.0',
            'id': 'drain-1',
            'method': 'server/discover',
            'params': {
              '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}},
            },
          })}\n',
        ),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await input.close();
      await expectLater(
        serving.timeout(const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
      await serving;
      expect(written.single['id'], 'drain-1');
    } finally {
      if (!release.isCompleted) release.complete();
      await input.close();
      await serving;
    }
  });
  test(
    'failed protocol output terminates serve even while input stays open',
    () async {
      final input = StreamController<List<int>>();
      final serving = GaoVmMcpServer(
        api: GaoVmApiClient(socketPath: api.socketPath),
      ).serve(input.stream, (_) async => throw StateError('closed output'));
      final failed = expectLater(
        serving,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'closed output',
          ),
        ),
      );
      try {
        input.add(
          utf8.encode(
            '${jsonEncode({
              'jsonrpc': '2.0',
              'id': 'broken-output',
              'method': 'server/discover',
              'params': {
                '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}},
              },
            })}\n',
          ),
        );
        await failed.timeout(const Duration(seconds: 2));
      } finally {
        await input.close();
        await serving.catchError((Object _) {});
      }
    },
  );
}

Future<void> _withHttpMcp(
  Directory root,
  Future<void> Function(HttpRequest) handler,
  Future<void> Function(_McpClient) check,
) async {
  final socketPath = '${root.path}/transport.sock';
  final server = await HttpServer.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  final pending = <Future<void>>[];
  final subscription = server.listen(
    (request) => pending.add(handler(request)),
  );
  final client = _McpClient(
    GaoVmMcpServer(api: GaoVmApiClient(socketPath: socketPath)),
  );
  try {
    await check(client);
  } finally {
    await client.close();
    await server.close(force: true);
    await subscription.cancel();
    await Future.wait(pending);
  }
}

final class _McpClient {
  _McpClient(GaoVmMcpServer server) {
    _replies = StreamIterator(_output.stream);
    _serving = server
        .serve(
          _input.stream,
          (line) => _output.add(jsonDecode(line) as Map<String, dynamic>),
        )
        .catchError((Object error, StackTrace stack) {
          _output.addError(error, stack);
        });
  }

  final _input = StreamController<List<int>>();
  // Unused fixture clients must also be closeable without an output subscriber.
  final _output = StreamController<Map<String, dynamic>>.broadcast();
  late final StreamIterator<Map<String, dynamic>> _replies;
  late final Future<void> _serving;
  var _id = 0;

  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) => request('tools/call', params: {'name': name, 'arguments': arguments});

  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, Object?> params = const {},
  }) async {
    sendRequest(method, params: params);
    return receive();
  }

  int sendRequest(String method, {Map<String, Object?> params = const {}}) {
    final id = ++_id;
    _input.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': {
            '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}},
            ...params,
          },
        })}\n',
      ),
    );
    return id;
  }

  Future<Map<String, dynamic>> legacyRequest(
    String method, {
    Map<String, Object?> params = const {},
  }) => raw(
    '${jsonEncode({'jsonrpc': '2.0', 'id': ++_id, 'method': method, 'params': params})}\n',
  );

  Future<Map<String, dynamic>> raw(String line) async {
    _input.add(utf8.encode(line));
    return receive();
  }

  Future<Map<String, dynamic>> rawBytes(List<int> bytes) {
    _input.add(bytes);
    return receive();
  }

  void sendBytes(List<int> bytes) => _input.add(bytes);

  Future<Map<String, dynamic>> receive({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!await _replies.moveNext().timeout(timeout)) {
      throw StateError('MCP ended without replying');
    }
    return _replies.current;
  }

  void notify(
    String method, {
    Map<String, Object?> params = const {},
  }) => _input.add(
    utf8.encode(
      '${jsonEncode({'jsonrpc': '2.0', 'method': method, if (params.isNotEmpty) 'params': params})}\n',
    ),
  );

  Future<void> close() async {
    await _replies.cancel();
    await _input.close();
    await _serving;
    await _output.close();
  }

  Future<void> finishInput() => _input.close();
  Future<void> get finished => _serving;
}

VmSpec _spec({ImageId? kernel}) => VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: LinuxKernelBoot(kernelImageId: kernel ?? ImageId.generate()),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/fixture/disk.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

final class _ReadOnlyVm implements VmMutationAcceptor, VmConditionWaiter {
  @override
  Future<OperationAcceptance> create(VmCreateCommand _) =>
      throw UnimplementedError('read-only fixture');
  @override
  Future<OperationAcceptance> patch(VmPatchCommand _) =>
      throw UnimplementedError('read-only fixture');
  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand _) =>
      throw UnimplementedError('read-only fixture');
  @override
  Future<DateTime> wait(VmWaitCommand _) =>
      throw UnimplementedError('read-only fixture');
}

final class _ReadOnlyOperations implements OperationMutationAcceptor {
  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand _) =>
      throw UnimplementedError('read-only fixture');
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
