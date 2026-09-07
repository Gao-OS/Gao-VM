import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/public_api_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String socketPath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-public-api-',
    );
    socketPath = '${temporaryDirectory.path}/api.sock';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('router registration is exact, versioned, and method-aware', () {
    final router = PublicApiRouter();
    Future<PublicApiResponse> handler(PublicApiRequest _) async =>
        PublicApiResponse.json(status: 200, body: const {});
    router.add('post', '/v1/example', handler);

    expect(router.containsPath('/v1/example'), isTrue);
    expect(router.allowedMethods('/v1/example'), {'POST'});
    expect(router.handler('POST', '/v1/example'), same(handler));
    expect(() => router.add('POST', '/v1/example', handler), throwsStateError);
    expect(
      () => router.add('GET', '/unversioned', handler),
      throwsArgumentError,
    );
  });

  test(
    'passes resource path parameters through the HTTP handler boundary',
    () async {
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/vms/{vm_id}',
          (request) async =>
              PublicApiResponse.json(status: 200, body: request.pathParameters),
        );
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {},
        systemHealth: _HealthService(),
        router: router,
      );
      addTearDown(server.close);
      await server.start();

      final response = await _request(socketPath, 'GET', '/v1/vms/vm_example');

      expect(response.status, 200);
      expect(jsonDecode(response.body), {'vm_id': 'vm_example'});
      final unsupported = await _request(
        socketPath,
        'POST',
        '/v1/vms/vm_example',
      );
      expect(unsupported.status, 405);
      expect(unsupported.headers['allow'], 'GET');
    },
  );

  test(
    'preserves exact immutable request bytes for idempotency hashing',
    () async {
      final router = PublicApiRouter()
        ..add('POST', '/v1/echo', (request) async {
          expect(() => request.bodyBytes.add(0), throwsUnsupportedError);
          return PublicApiResponse.json(
            status: 200,
            body: {
              'raw': utf8.decode(request.bodyBytes),
              'json': request.jsonBody!.toJson(),
            },
          );
        });
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {},
        systemHealth: _HealthService(),
        router: router,
      );
      addTearDown(server.close);
      await server.start();
      const raw = '{ "name" : "vm" }\n';

      final response = await _request(
        socketPath,
        'POST',
        '/v1/echo',
        headers: {'Content-Type': 'application/json'},
        body: utf8.encode(raw),
      );

      expect(response.status, 200);
      expect(jsonDecode(response.body), {
        'raw': raw,
        'json': {'name': 'vm'},
      });
    },
  );

  test('accepts merge-patch JSON only for PATCH', () async {
    final router = PublicApiRouter();
    for (final method in ['PATCH', 'POST']) {
      router.add(
        method,
        '/v1/vms/{vm_id}',
        (request) async => PublicApiResponse.json(
          status: 200,
          body: request.jsonBody!.toJson(),
        ),
      );
    }
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {},
      systemHealth: _HealthService(),
      router: router,
    );
    addTearDown(server.close);
    await server.start();
    for (final method in ['PATCH', 'POST']) {
      final response = await _request(
        socketPath,
        method,
        '/v1/vms/vm_example',
        headers: {'Content-Type': 'application/merge-patch+json'},
        body: utf8.encode('{"description":null}'),
      );
      expect(response.status, method == 'PATCH' ? 200 : 415);
    }
  });

  test('serves OpenAPI and injected health over a mode-0600 UDS', () async {
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {
        'openapi': '3.1.0',
        'info': {'title': 'GaoVM Public API'},
      },
      systemHealth: _HealthService(),
      newRequestId: () => _requestId,
    );
    addTearDown(server.close);

    await server.start();

    final mode = (await FileStat.stat(socketPath)).mode & 0x1ff;
    expect(mode, 0x180);
    final schema = await _request(socketPath, 'GET', '/v1/openapi.json');
    expect(schema.status, 200);
    expect(schema.headers['content-type'], startsWith('application/json'));
    expect(schema.headers['x-request-id'], _requestId.value);
    expect(jsonDecode(schema.body), containsPair('openapi', '3.1.0'));

    final live = await _request(socketPath, 'GET', '/v1/system/live');
    expect(live.status, 200);
    expect(jsonDecode(live.body), {'live': true});

    final ready = await _request(socketPath, 'GET', '/v1/system/ready');
    expect(ready.status, 200);
    expect(jsonDecode(ready.body), {
      'ready': true,
      'checks': {'database': 'ok'},
    });
  });

  test(
    'deep-copies OpenAPI and health-check values at their boundaries',
    () async {
      final info = <String, Object?>{'title': 'Original'};
      final openApi = <String, Object?>{'openapi': '3.1.0', 'info': info};
      final database = <String, Object?>{'state': 'ok'};
      final checks = <String, Object?>{'database': database};
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: openApi,
        systemHealth: _FrozenHealthService(checks),
        newRequestId: () => _requestId,
      );
      addTearDown(server.close);
      info['title'] = 'Mutated';
      database['state'] = 'failed';
      await server.start();

      final schema =
          jsonDecode(
                (await _request(socketPath, 'GET', '/v1/openapi.json')).body,
              )
              as Map<String, Object?>;
      expect((schema['info'] as Map<String, Object?>)['title'], 'Original');
      final ready =
          jsonDecode(
                (await _request(socketPath, 'GET', '/v1/system/ready')).body,
              )
              as Map<String, Object?>;
      expect((ready['checks'] as Map<String, Object?>)['database'], {
        'state': 'ok',
      });
    },
  );

  test(
    'returns stable problem responses for 404, method, and handler errors',
    () async {
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _ThrowingHealthService(),
        newRequestId: () => _requestId,
      );
      addTearDown(server.close);
      await server.start();

      final missing = await _request(socketPath, 'GET', '/v1/missing');
      _expectProblem(missing, HttpStatus.notFound, 'INVALID_REQUEST');

      final method = await _request(socketPath, 'POST', '/v1/openapi.json');
      _expectProblem(method, HttpStatus.methodNotAllowed, 'INVALID_REQUEST');
      expect(method.headers['allow'], 'GET');

      final error = await _request(socketPath, 'GET', '/v1/system/live');
      _expectProblem(error, HttpStatus.internalServerError, 'INTERNAL_ERROR');
      expect(error.body, isNot(contains('injected secret failure')));

      final version = await _request(
        socketPath,
        'GET',
        '/v1/openapi.json',
        protocol: 'HTTP/1.0',
      );
      _expectProblem(
        version,
        HttpStatus.httpVersionNotSupported,
        'INVALID_REQUEST',
      );
    },
  );

  test('router enforces JSON content type, syntax, and body limit', () async {
    final router = PublicApiRouter()
      ..add(
        'POST',
        '/v1/echo',
        (request) async => PublicApiResponse.json(
          status: HttpStatus.ok,
          body: request.jsonBody!.toJson(),
        ),
      );
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
      router: router,
      maxJsonBodyBytes: 16,
      newRequestId: () => _requestId,
    );
    addTearDown(server.close);
    await server.start();

    final ok = await _request(
      socketPath,
      'POST',
      '/v1/echo',
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode('{"ok":true}'),
    );
    expect(ok.status, HttpStatus.ok);
    expect(jsonDecode(ok.body), {'ok': true});

    final media = await _request(
      socketPath,
      'POST',
      '/v1/echo',
      headers: {'Content-Type': 'text/plain'},
      body: utf8.encode('{}'),
    );
    _expectProblem(media, HttpStatus.unsupportedMediaType, 'INVALID_REQUEST');

    final malformed = await _request(
      socketPath,
      'POST',
      '/v1/echo',
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode('{'),
    );
    _expectProblem(malformed, HttpStatus.badRequest, 'INVALID_REQUEST');

    final oversized = await _request(
      socketPath,
      'POST',
      '/v1/echo',
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode('{"value":"too large"}'),
    );
    _expectProblem(
      oversized,
      HttpStatus.requestEntityTooLarge,
      'INVALID_REQUEST',
    );

    final chunkedBody = utf8.encode('{"value":"too large"}');
    final chunked = await _request(
      socketPath,
      'POST',
      '/v1/echo',
      headers: {
        'Content-Type': 'application/json',
        'Transfer-Encoding': 'chunked',
      },
      body: [
        ...ascii.encode(chunkedBody.length.toRadixString(16)),
        13,
        10,
        ...chunkedBody,
        13,
        10,
        ...ascii.encode('0\r\n\r\n'),
      ],
    );
    _expectProblem(
      chunked,
      HttpStatus.requestEntityTooLarge,
      'INVALID_REQUEST',
    );
  });

  test(
    'handler problems stay stable and request ID cannot be spoofed',
    () async {
      final router = PublicApiRouter()
        ..add(
          'POST',
          '/v1/methods',
          (_) async => PublicApiResponse.json(
            status: HttpStatus.ok,
            body: const {'ok': true},
            headers: {'x-request-id': 'spoofed'},
          ),
        )
        ..add(
          'PUT',
          '/v1/methods',
          (_) async => PublicApiResponse.json(
            status: HttpStatus.ok,
            body: const {'ok': true},
          ),
        )
        ..add(
          'GET',
          '/v1/problem-return',
          (_) async => PublicApiResponse.problem(
            status: HttpStatus.conflict,
            code: ErrorCode.vmOperationConflict,
            type: 'vm-operation-conflict',
            title: 'VM operation conflict',
            detail: 'The VM already has an active operation.',
            retryable: true,
            operationId: _operationId,
            details: JsonObjectValue.fromJson(const {'phase': 'starting'}),
          ),
        )
        ..add('GET', '/v1/problem-throw', (_) async {
          throw PublicApiException(
            PublicApiProblem(
              status: HttpStatus.serviceUnavailable,
              code: ErrorCode.driverUnhealthy,
              type: 'driver-unhealthy',
              title: 'Driver unhealthy',
              detail: 'The runtime driver is unavailable.',
              retryable: true,
              details: JsonObjectValue.empty,
            ),
          );
        });
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        router: router,
        newRequestId: () => _requestId,
      );
      addTearDown(server.close);
      await server.start();

      final method = await _request(socketPath, 'GET', '/v1/methods');
      _expectProblem(method, HttpStatus.methodNotAllowed, 'INVALID_REQUEST');
      expect(method.headers['allow'], 'POST, PUT');
      expect(method.body, contains('POST, PUT'));

      final spoof = await _request(socketPath, 'POST', '/v1/methods');
      expect(spoof.headers['x-request-id'], _requestId.value);

      final returned = await _request(socketPath, 'GET', '/v1/problem-return');
      _expectProblem(returned, HttpStatus.conflict, 'VM_OPERATION_CONFLICT');
      final returnedBody = jsonDecode(returned.body) as Map<String, Object?>;
      expect(returnedBody['retryable'], isTrue);
      expect(returnedBody['operation_id'], _operationId.value);
      expect(returnedBody['details'], {'phase': 'starting'});

      final thrown = await _request(socketPath, 'GET', '/v1/problem-throw');
      _expectProblem(thrown, HttpStatus.serviceUnavailable, 'DRIVER_UNHEALTHY');
    },
  );

  test(
    'request-ID generator failure uses a canonical emergency response',
    () async {
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        newRequestId: () => throw StateError('request ID unavailable'),
      );
      addTearDown(server.close);
      await server.start();

      final response = await _request(socketPath, 'GET', '/v1/system/live');

      expect(response.status, HttpStatus.internalServerError);
      expect(
        response.headers['x-request-id'],
        emergencyPublicApiRequestId.value,
      );
      final problem = jsonDecode(response.body) as Map<String, Object?>;
      expect(problem['code'], 'INTERNAL_ERROR');
      expect(problem['request_id'], emergencyPublicApiRequestId.value);
    },
  );

  test('bounded request deadline returns a stable timeout problem', () async {
    final never = Completer<void>();
    final router = PublicApiRouter()
      ..add('GET', '/v1/slow', (_) async {
        await never.future;
        return PublicApiResponse.json(status: HttpStatus.ok, body: const {});
      });
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
      router: router,
      requestDeadline: const Duration(milliseconds: 20),
      newRequestId: () => _requestId,
    );
    addTearDown(server.close);
    await server.start();

    final response = await _request(socketPath, 'GET', '/v1/slow');

    _expectProblem(response, HttpStatus.gatewayTimeout, 'WAIT_TIMEOUT');
  });

  test('concurrent UDS requests are not globally serialized', () async {
    const requestCount = 8;
    final release = Completer<void>();
    final allStarted = Completer<void>();
    var started = 0;
    final router = PublicApiRouter()
      ..add('GET', '/v1/concurrent', (_) async {
        started++;
        if (started == requestCount) allStarted.complete();
        await release.future;
        return PublicApiResponse.json(
          status: HttpStatus.ok,
          body: const {'ok': true},
        );
      });
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
      router: router,
      requestDeadline: const Duration(seconds: 1),
    );
    addTearDown(server.close);
    await server.start();

    final requests = List.generate(
      requestCount,
      (_) => _request(socketPath, 'GET', '/v1/concurrent'),
    );
    await allStarted.future;
    release.complete();
    final responses = await Future.wait(requests);

    expect(responses, everyElement(isA<_HttpResponse>()));
    expect(responses.map((response) => response.status), everyElement(200));
    expect(
      responses.map((response) => response.headers['x-request-id']).toSet(),
      hasLength(requestCount),
    );
  });

  test(
    'cleans stale sockets but protects live sockets and regular files',
    () async {
      final staleSource = '${temporaryDirectory.path}/stale-source.sock';
      final address = InternetAddress(
        staleSource,
        type: InternetAddressType.unix,
      );
      final stale = await ServerSocket.bind(address, 0);
      await File(staleSource).rename(socketPath);
      await stale.close();
      expect(
        await FileSystemEntity.type(socketPath, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
      final first = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
      );
      addTearDown(first.close);
      await first.start();

      final second = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
      );
      await expectLater(second.start(), throwsStateError);
      await second.close();
      expect(
        (await _request(socketPath, 'GET', '/v1/system/live')).status,
        HttpStatus.ok,
      );
      await first.close();
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );

      await File(socketPath).writeAsString('do not delete');
      final protected = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
      );
      await expectLater(protected.start(), throwsA(isA<FileSystemException>()));
      expect(await File(socketPath).readAsString(), 'do not delete');
    },
  );

  test('cleans crash-stale public and ownership hard links', () async {
    final generationPath = '${temporaryDirectory.path}/.g.crashstale';
    final ownerPath = '${temporaryDirectory.path}/.o.crashstale';
    final stale = await ServerSocket.bind(
      InternetAddress(generationPath, type: InternetAddressType.unix),
      0,
    );
    _TestPermissions.link(generationPath, ownerPath);
    _TestPermissions.link(generationPath, socketPath);
    await stale.close();
    expect(
      await FileSystemEntity.type(ownerPath, followLinks: false),
      FileSystemEntityType.unixDomainSock,
    );
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
    );
    addTearDown(server.close);

    await server.start();

    expect(
      await FileSystemEntity.type(ownerPath, followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(
      (await _request(socketPath, 'GET', '/v1/system/live')).status,
      HttpStatus.ok,
    );
  });

  test(
    'stale cleanup moves then restores a replacement from the rename race',
    () async {
      final staleSource = '${temporaryDirectory.path}/stale-race.sock';
      final stale = await ServerSocket.bind(
        InternetAddress(staleSource, type: InternetAddressType.unix),
        0,
      );
      await File(staleSource).rename(socketPath);
      await stale.close();
      ServerSocket? replacement;
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        beforeSocketQuarantineRename:
            (path, quarantinePath, quarantineRename) async {
              if (path != socketPath || replacement != null) return;
              await File(socketPath).delete();
              replacement = await ServerSocket.bind(
                InternetAddress(socketPath, type: InternetAddressType.unix),
                0,
              );
              await quarantineRename();
            },
      );

      await expectLater(server.start(), throwsA(isA<FileSystemException>()));

      expect(replacement, isNotNull);
      expect(
        await FileSystemEntity.type(socketPath, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
      final connection = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      connection.destroy();
      await replacement!.close();
    },
  );

  test(
    'rename-race replacement is preserved when another creator takes public path',
    () async {
      final staleSource = '${temporaryDirectory.path}/stale-contended.sock';
      final stale = await ServerSocket.bind(
        InternetAddress(staleSource, type: InternetAddressType.unix),
        0,
      );
      await File(staleSource).rename(socketPath);
      await stale.close();
      ServerSocket? replacement;
      ServerSocket? concurrent;
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        beforeSocketQuarantineRename:
            (path, quarantinePath, quarantineRename) async {
              if (path != socketPath || replacement != null) return;
              await File(socketPath).delete();
              replacement = await ServerSocket.bind(
                InternetAddress(socketPath, type: InternetAddressType.unix),
                0,
              );
              await quarantineRename();
              concurrent = await ServerSocket.bind(
                InternetAddress(socketPath, type: InternetAddressType.unix),
                0,
              );
            },
      );

      await expectLater(server.start(), throwsA(isA<FileSystemException>()));

      final publicConnection = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      publicConnection.destroy();
      final quarantines = await temporaryDirectory
          .list(followLinks: false)
          .where((entity) => entity.path.split('/').last.startsWith('.q.'))
          .toList();
      expect(quarantines, hasLength(1));
      final replacementConnection = await Socket.connect(
        InternetAddress(
          quarantines.single.path,
          type: InternetAddressType.unix,
        ),
        0,
      );
      replacementConnection.destroy();

      await concurrent!.close();
      await replacement!.close();
      if (await quarantines.single.exists()) {
        await quarantines.single.delete();
      }
    },
  );

  test(
    'no-replace quarantine collision preserves both live socket inodes',
    () async {
      final staleSource = '${temporaryDirectory.path}/stale-theft.sock';
      final stale = await ServerSocket.bind(
        InternetAddress(staleSource, type: InternetAddressType.unix),
        0,
      );
      await File(staleSource).rename(socketPath);
      await stale.close();
      ServerSocket? victim;
      ServerSocket? destination;
      String? destinationPath;
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        beforeSocketQuarantineRename:
            (path, quarantinePath, quarantineRename) async {
              if (path != socketPath || victim != null) {
                await quarantineRename();
                return;
              }
              await File(socketPath).delete();
              victim = await ServerSocket.bind(
                InternetAddress(socketPath, type: InternetAddressType.unix),
                0,
              );
              destinationPath = quarantinePath;
              destination = await ServerSocket.bind(
                InternetAddress(quarantinePath, type: InternetAddressType.unix),
                0,
              );
              await quarantineRename();
            },
      );

      await expectLater(
        server.start(),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.osError?.errorCode,
            'errno',
            17,
          ),
        ),
      );

      final victimConnection = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      victimConnection.destroy();
      final destinationConnection = await Socket.connect(
        InternetAddress(destinationPath!, type: InternetAddressType.unix),
        0,
      );
      destinationConnection.destroy();
      await victim!.close();
      await destination!.close();
    },
  );

  test(
    'graceful close waits for active request and removes its socket',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final router = PublicApiRouter()
        ..add('GET', '/v1/blocking', (_) async {
          started.complete();
          await release.future;
          return PublicApiResponse.json(
            status: HttpStatus.ok,
            body: const {'closed': false},
          );
        });
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        router: router,
      );
      await server.start();
      final request = _request(socketPath, 'GET', '/v1/blocking');
      await started.future;
      final done = server.done;
      var closed = false;
      final close = server.close().whenComplete(() => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);

      release.complete();
      expect((await request).status, HttpStatus.ok);
      await close;
      await done;
      expect(server.isRunning, isFalse);
      expect(server.fatalError, isNull);
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );
    },
  );

  test('fails closed when a live socket probe is permission denied', () async {
    final first = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
    );
    addTearDown(first.close);
    await first.start();
    _TestPermissions.chmod(socketPath, 0);
    final second = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
    );

    await expectLater(second.start(), throwsA(isA<FileSystemException>()));

    expect(
      await FileSystemEntity.type(socketPath, followLinks: false),
      FileSystemEntityType.unixDomainSock,
    );
    _TestPermissions.chmod(socketPath, 0x180);
    expect(
      (await _request(socketPath, 'GET', '/v1/system/live')).status,
      HttpStatus.ok,
    );
  });

  test('old close cannot unlink a replacement socket inode', () async {
    final first = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
    );
    await first.start();
    await File(socketPath).delete();
    final replacement = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    addTearDown(replacement.close);

    await first.close();

    expect(
      await FileSystemEntity.type(socketPath, followLinks: false),
      FileSystemEntityType.unixDomainSock,
    );
    final connection = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    connection.destroy();
  });

  test(
    'close quarantines and restores an owned-link replacement from the race',
    () async {
      ServerSocket? replacement;
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        beforeSocketQuarantineRename:
            (path, quarantinePath, quarantineRename) async {
              if (path == socketPath && replacement == null) {
                await File(socketPath).delete();
                replacement = await ServerSocket.bind(
                  InternetAddress(socketPath, type: InternetAddressType.unix),
                  0,
                );
              }
              await quarantineRename();
            },
      );
      await server.start();

      await expectLater(server.close(), throwsA(isA<FileSystemException>()));

      expect(replacement, isNotNull);
      final connection = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      connection.destroy();
      await server.close();
      await replacement!.close();
    },
  );

  test(
    'concurrent start and close are serialized across generations',
    () async {
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
      );

      final start = server.start();
      final close = server.close();
      await Future.wait([start, close]);
      expect(server.isRunning, isFalse);
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );

      await server.start();
      expect(server.isRunning, isTrue);
      expect(
        (await _request(socketPath, 'GET', '/v1/system/live')).status,
        HttpStatus.ok,
      );
      await server.close();
    },
  );

  test('listen setup failure leaves a stopped retryable server', () async {
    final listenerFactory = _FailOnceListenerFactory();
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
      listenerFactory: listenerFactory,
    );

    await expectLater(server.start(), throwsStateError);

    expect(server.isRunning, isFalse);
    await server.done;
    expect(
      await FileSystemEntity.type(socketPath),
      FileSystemEntityType.notFound,
    );

    await server.start();
    expect(server.isRunning, isTrue);
    expect(
      (await _request(socketPath, 'GET', '/v1/system/live')).status,
      HttpStatus.ok,
    );
    await server.close();
  });

  test(
    'unexpected listener error or EOF settles done and cleans ownership',
    () async {
      final listenerFactory = _ControllableListenerFactory();
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        listenerFactory: listenerFactory,
      );
      await server.start();
      final errorDone = server.done;
      final failure = StateError('injected listener failure');

      listenerFactory.emitError(failure);
      await errorDone;

      expect(server.isRunning, isFalse);
      expect(server.fatalError, same(failure));
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );

      await server.start();
      final eofDone = server.done;
      listenerFactory.emitDone();
      await eofDone;

      expect(server.isRunning, isFalse);
      expect(server.fatalError, isA<StateError>());
      expect(
        await FileSystemEntity.type(socketPath),
        FileSystemEntityType.notFound,
      );
    },
  );

  test(
    'listener cleanup failure still settles done without leaking errors',
    () async {
      final listenerFactory = _ControllableListenerFactory();
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
        listenerFactory: listenerFactory,
      );
      await server.start();
      final done = server.done;
      _TestPermissions.chmod(temporaryDirectory.path, 0);
      try {
        listenerFactory.emitError(StateError('listener failed'));
        await done;
        expect(server.isRunning, isFalse);
        expect(server.fatalError, isNotNull);
      } finally {
        _TestPermissions.chmod(temporaryDirectory.path, 0x1c0);
        await server.close();
      }
    },
  );

  test('requires an absolute path and a private existing parent', () async {
    expect(
      () => PublicApiServer(
        socketPath: 'relative.sock',
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: _HealthService(),
      ),
      throwsArgumentError,
    );
    _TestPermissions.chmod(temporaryDirectory.path, 0x1ed);
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: _HealthService(),
    );

    await expectLater(server.start(), throwsA(isA<FileSystemException>()));
    expect((await temporaryDirectory.stat()).mode & 0x1ff, 0x1ed);
    _TestPermissions.chmod(temporaryDirectory.path, 0x1c0);
  });
}

final _requestId = RequestId('req_01J00000000000000000000000');
final _operationId = OperationId('op_01J00000000000000000000001');

final class _HealthService implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: {});

  @override
  Future<SystemHealthStatus> readiness() async =>
      SystemHealthStatus(healthy: true, checks: {'database': 'ok'});
}

final class _FrozenHealthService implements SystemHealthService {
  _FrozenHealthService(Map<String, Object?> checks)
    : status = SystemHealthStatus(healthy: true, checks: checks);

  final SystemHealthStatus status;

  @override
  Future<SystemHealthStatus> liveness() async => status;

  @override
  Future<SystemHealthStatus> readiness() async => status;
}

final class _ThrowingHealthService implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() =>
      Future.error(StateError('injected secret failure'));

  @override
  Future<SystemHealthStatus> readiness() =>
      Future.error(StateError('injected secret failure'));
}

final class _HttpResponse {
  const _HttpResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers;
  final String body;
}

void _expectProblem(_HttpResponse response, int status, String code) {
  expect(response.status, status);
  expect(
    response.headers['content-type'],
    startsWith('application/problem+json'),
  );
  expect(response.headers['x-request-id'], _requestId.value);
  final problem = jsonDecode(response.body) as Map<String, Object?>;
  expect(problem['status'], status);
  expect(problem['code'], code);
  expect(problem['request_id'], _requestId.value);
}

Future<_HttpResponse> _request(
  String socketPath,
  String method,
  String path, {
  Map<String, String> headers = const {},
  List<int> body = const [],
  String protocol = 'HTTP/1.1',
}) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  final request = StringBuffer()
    ..write('$method $path $protocol\r\n')
    ..write('Host: localhost\r\n')
    ..write('Connection: close\r\n');
  for (final entry in headers.entries) {
    request.write('${entry.key}: ${entry.value}\r\n');
  }
  final hasTransferEncoding = headers.keys.any(
    (name) => name.toLowerCase() == 'transfer-encoding',
  );
  final hasContentLength = headers.keys.any(
    (name) => name.toLowerCase() == 'content-length',
  );
  if (body.isNotEmpty && !hasTransferEncoding && !hasContentLength) {
    request.write('Content-Length: ${body.length}\r\n');
  }
  request.write('\r\n');
  socket.add(utf8.encode(request.toString()));
  if (body.isNotEmpty) socket.add(body);
  await socket.flush();
  final bytes = await socket.fold<List<int>>(<int>[], (out, chunk) {
    out.addAll(chunk);
    return out;
  });
  final split = _headerBoundary(bytes);
  final head = ascii.decode(bytes.sublist(0, split));
  final lines = head.split('\r\n');
  final status = int.parse(lines.first.split(' ')[1]);
  final responseHeaders = <String, String>{};
  for (final line in lines.skip(1)) {
    final separator = line.indexOf(':');
    if (separator < 0) continue;
    responseHeaders[line.substring(0, separator).toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  return _HttpResponse(
    status,
    responseHeaders,
    utf8.decode(bytes.sublist(split + 4)),
  );
}

int _headerBoundary(List<int> bytes) {
  for (var index = 0; index <= bytes.length - 4; index++) {
    if (bytes[index] == 13 &&
        bytes[index + 1] == 10 &&
        bytes[index + 2] == 13 &&
        bytes[index + 3] == 10) {
      return index;
    }
  }
  throw StateError('HTTP response had no header boundary');
}

final class _FailOnceListenerFactory implements PublicApiListenerFactory {
  final delegate = const DartPublicApiListenerFactory();
  var attempts = 0;

  @override
  PublicApiBoundListener listen({
    required ServerSocket socket,
    required void Function(HttpRequest request) onRequest,
    required PublicApiListenerError onError,
    required void Function() onDone,
  }) {
    attempts++;
    if (attempts == 1) throw StateError('injected listen failure');
    return delegate.listen(
      socket: socket,
      onRequest: onRequest,
      onError: onError,
      onDone: onDone,
    );
  }
}

final class _ControllableListenerFactory implements PublicApiListenerFactory {
  final delegate = const DartPublicApiListenerFactory();
  PublicApiListenerError? _onError;
  void Function()? _onDone;

  @override
  PublicApiBoundListener listen({
    required ServerSocket socket,
    required void Function(HttpRequest request) onRequest,
    required PublicApiListenerError onError,
    required void Function() onDone,
  }) {
    _onError = onError;
    _onDone = onDone;
    return delegate.listen(
      socket: socket,
      onRequest: onRequest,
      onError: onError,
      onDone: onDone,
    );
  }

  void emitError(Object error) => _onError!(error, StackTrace.current);

  void emitDone() => _onDone!();
}

final class _TestPermissions {
  static final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.open(
    '/usr/lib/libSystem.B.dylib',
  );
  static final int Function(ffi.Pointer<Utf8>, int) _chmod = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
        int Function(ffi.Pointer<Utf8>, int)
      >('chmod');
  static final int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>) _link = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>),
        int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>)
      >('link');

  static void chmod(String path, int mode) {
    final pointer = path.toNativeUtf8();
    try {
      if (_chmod(pointer, mode) != 0) {
        throw FileSystemException('chmod failed', path);
      }
    } finally {
      calloc.free(pointer);
    }
  }

  static void link(String source, String target) {
    final sourcePointer = source.toNativeUtf8();
    final targetPointer = target.toNativeUtf8();
    try {
      if (_link(sourcePointer, targetPointer) != 0) {
        throw FileSystemException('hard-link creation failed', target);
      }
    } finally {
      calloc.free(sourcePointer);
      calloc.free(targetPointer);
    }
  }
}
