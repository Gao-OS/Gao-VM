import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late ImageApplicationService images;
  late PublicApiServer server;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gvm-cli-img-');
    imageFileMode(directory.path, 0x1c0);
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    images = ImageApplicationService(
      database: database,
      store: ImageStore(database, Directory('${directory.path}/images')),
    );
    final operations = SqliteOperationRepository(database);
    final router = PublicApiRouter();
    ImageApiHandlers(images: images).register(router);
    final outside = _UnusedVmActions();
    ResourceApiHandlers(
      vms: VmApplicationService(
        repository: SqliteVmRepository(database),
        mutations: outside,
        waiter: outside,
      ),
      operations: OperationApplicationService(
        repository: operations,
        mutations: images,
        waiter: SqliteOperationWaiter(
          operations: operations,
          events: SqliteDurableEventFeed(database),
        ),
      ),
    ).register(router);
    server = PublicApiServer(
      socketPath: '${directory.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await server.start();
  });
  tearDown(() async {
    await server.close();
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'image import returns a durable operation visible to another API client',
    () async {
      final source = await File(
        '${directory.path}/磁盘 image.raw',
      ).writeAsString('disk');
      final result = await _invoke(server, [
        'image',
        'import',
        '--body-json',
        jsonEncode({
          'source_path': source.path,
          'type': 'raw-disk',
          'architecture': 'arm64',
          'version': '1.0',
          'labels': {'channel': 'nightly'},
        }),
        '--idempotency-key',
        'cli-image-import',
      ]);
      expect(result.code, 0, reason: result.error);
      final accepted = jsonDecode(result.output) as Map;
      expect(accepted['state'], 'pending');
      expect(accepted['resource_type'], 'image');
      final id = ImageId(accepted['resource_id'] as String);
      final operationId = OperationId(accepted['operation_id'] as String);
      final other = GaoVmApiClient(socketPath: server.socketPath);
      final pending = Operation.fromJson(
        (await other.request(
          'GET',
          '/v1/operations/${operationId.value}',
        )).body.toJson(),
      );
      expect(pending.state, OperationState.pending);
      expect(pending.resourceId, id);
      expect(await images.store.list(), isEmpty);
      await images.dispatchOnce();
      final waited = await _invoke(server, [
        'operation',
        'wait',
        operationId.value,
        '--timeout-seconds',
        '1',
      ]);
      expect(waited.code, 0, reason: waited.error);
      final completed = Operation.fromJson(jsonDecode(waited.output));
      expect(completed.state, OperationState.succeeded);
      expect(completed.result!.toJson()['image_id'], id.value);
      expect(
        await (await images.store.objectFile(id, 'payload')).readAsString(),
        'disk',
      );
    },
  );

  test('image list filters and resumes the public catalog cursor', () async {
    final ids = <String>[];
    for (final name in ['one', 'two', 'excluded']) {
      final source = await File('${directory.path}/$name').writeAsString(name);
      final imported = await _invoke(server, [
        'image',
        'import',
        '--body-json',
        jsonEncode({
          'source_path': source.path,
          'type': 'initrd',
          'architecture': 'arm64',
          'labels': {'channel': name == 'excluded' ? 'stable' : 'nightly'},
        }),
      ]);
      expect(imported.code, 0, reason: imported.error);
      ids.add(jsonDecode(imported.output)['resource_id'] as String);
      await images.dispatchOnce();
    }
    final args = [
      'image',
      'list',
      '--label-selector',
      'channel=nightly',
      '--limit',
      '1',
    ];
    final first = await _invoke(server, args);
    expect(first.code, 0, reason: first.error);
    final page = jsonDecode(first.output) as Map;
    expect(Image.fromJson((page['items'] as List).single).id.value, ids[0]);
    final cursor = page['next_cursor'] as String;
    final next = await _invoke(server, [...args, '--cursor', cursor]);
    expect(next.code, 0, reason: next.error);
    final nextPage = jsonDecode(next.output) as Map;
    expect(Image.fromJson((nextPage['items'] as List).single).id.value, ids[1]);
    expect(nextPage['next_cursor'], isNull);
    final wrongScope = await _invoke(server, [
      'image',
      'list',
      '--label-selector',
      'channel=stable',
      '--cursor',
      cursor,
    ]);
    expect(wrongScope.code, 1);
    expect(
      Problem.fromJson(jsonDecode(wrongScope.error)).code,
      ErrorCode.invalidRequest,
    );
  });

  test(
    'image delete returns a replayable operation and preserves the source',
    () async {
      final source = await File('${directory.path}/disk').writeAsString('disk');
      final image = await images.store.importFile(
        source,
        type: ImageType.rawDisk,
      );
      final args = [
        'image',
        'delete',
        image.id.value,
        '--idempotency-key',
        'cli-delete-image',
      ];
      final accepted = await _invoke(server, args);
      expect(accepted.code, 0, reason: accepted.error);
      final acceptance = jsonDecode(accepted.output) as Map;
      expect(acceptance['state'], 'pending');
      final listed = await _invoke(server, ['image', 'list']);
      expect(jsonDecode(listed.output)['items'], hasLength(1));
      await images.dispatchOnce();
      final waited = await _invoke(server, [
        'operation',
        'wait',
        acceptance['operation_id'] as String,
        '--timeout-seconds',
        '1',
      ]);
      expect(waited.code, 0, reason: waited.error);
      expect(
        Operation.fromJson(jsonDecode(waited.output)).state,
        OperationState.succeeded,
      );
      expect(
        jsonDecode((await _invoke(server, ['image', 'list'])).output)['items'],
        isEmpty,
      );
      final replay = await _invoke(server, args);
      expect(replay.code, 0, reason: replay.error);
      expect(jsonDecode(replay.output), acceptance);
      final missing = await _invoke(server, [
        'image',
        'delete',
        image.id.value,
      ]);
      expect(missing.code, 1);
      final problem = Problem.fromJson(jsonDecode(missing.error));
      expect(problem.code, ErrorCode.imageNotFound);
      expect(problem.status, 404);
      expect(await source.readAsString(), 'disk');
    },
  );

  test(
    'image get resolves an immutable image through the public catalog',
    () async {
      final source = await File('${directory.path}/disk').writeAsString('disk');
      final image = await images.store.importFile(
        source,
        type: ImageType.rawDisk,
      );
      final fetched = await _invoke(server, ['image', 'get', image.id.value]);
      expect(fetched.code, 0, reason: fetched.error);
      expect(Image.fromJson(jsonDecode(fetched.output)), image);
      final missing = await _invoke(server, [
        'image',
        'get',
        ImageId.generate().value,
      ]);
      expect(missing.code, 1);
      expect(missing.output, isEmpty);
      expect(jsonDecode(missing.error)['code'], 'IMAGE_NOT_FOUND');
    },
  );

  test(
    'image get follows pagination beyond the maximum first page',
    () async {
      final source = await File('${directory.path}/disk').writeAsString('disk');
      for (var i = 0; i < 201; i++) {
        await images.store.importFile(
          source,
          type: ImageType.rawDisk,
          version: '$i',
        );
      }
      final catalog = await images.store.list();
      expect(catalog, hasLength(201));
      final target = catalog.last;
      final fetched = await _invoke(server, ['image', 'get', target.id.value]);
      expect(fetched.code, 0, reason: fetched.error);
      expect(Image.fromJson(jsonDecode(fetched.output)), target);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('image get bounds the entire catalog walk by one deadline', () async {
    final pending = <Completer<void>>[];
    final timers = <Timer>[];
    var pages = 0;
    final router = PublicApiRouter()
      ..add('GET', '/v1/images', (request) async {
        pages++;
        final release = Completer<void>();
        pending.add(release);
        // Controlled server latency, not a sleep used to order production work.
        timers.add(
          Timer(const Duration(milliseconds: 650), () {
            if (!release.isCompleted) release.complete();
          }),
        );
        await release.future;
        return PublicApiResponse.json(
          status: 200,
          body: {
            'items': [],
            'next_cursor': request.uri.queryParameters['cursor'] == null
                ? 'next'
                : null,
          },
        );
      });
    try {
      await _withBoundary(directory, router, (boundary) async {
        final fetched = await _invoke(boundary, [
          'image',
          'get',
          ImageId.generate().value,
          '--timeout-seconds',
          '1',
        ]);
        expect(pages, 2);
        expect(fetched.code, 124, reason: fetched.error);
        expect(fetched.output, isEmpty);
        expect(jsonDecode(fetched.error)['code'], 'CLI_TIMEOUT');
      });
    } finally {
      for (final timer in timers) timer.cancel();
      for (final release in pending) {
        if (!release.isCompleted) release.complete();
      }
    }
  });

  test(
    'image get rejects malformed catalog pages as protocol failures',
    () async {
      for (final body in [
        {'items': []},
        {'items': {}, 'next_cursor': null},
        {
          'items': [{}],
          'next_cursor': null,
        },
        {'items': [], 'next_cursor': 1},
        {'items': [], 'next_cursor': ''},
        {'items': [], 'next_cursor': 'x' * 513},
        {'items': [], 'next_cursor': null, 'unexpected': true},
      ]) {
        final router = PublicApiRouter()
          ..add(
            'GET',
            '/v1/images',
            (_) async => PublicApiResponse.json(status: 200, body: body),
          );
        await _withBoundary(directory, router, (boundary) async {
          final fetched = await _invoke(boundary, [
            'image',
            'get',
            ImageId.generate().value,
          ]);
          expect(fetched.code, 4, reason: body.toString());
          expect(fetched.output, isEmpty);
          expect(jsonDecode(fetched.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );

  test(
    'image get rejects a repeated cursor instead of reporting absence',
    () async {
      var pages = 0;
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/images',
          (_) async => PublicApiResponse.json(
            status: 200,
            body: {'items': [], 'next_cursor': ++pages < 3 ? 'repeated' : null},
          ),
        );
      await _withBoundary(directory, router, (boundary) async {
        final fetched = await _invoke(boundary, [
          'image',
          'get',
          ImageId.generate().value,
        ]);
        expect(fetched.code, 4, reason: fetched.error);
        expect(fetched.output, isEmpty);
        expect(jsonDecode(fetched.error)['code'], 'CLI_PROTOCOL');
      });
    },
  );

  test(
    'image import replays acceptance and preserves idempotency conflicts',
    () async {
      final source = await File('${directory.path}/disk').writeAsString('disk');
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      final args = [
        'image',
        'import',
        '--body-json',
        jsonEncode(body),
        '--idempotency-key',
        'cli-replay',
      ];
      final accepted = await _invoke(server, args);
      expect(accepted.code, 0, reason: accepted.error);
      final acceptance = jsonDecode(accepted.output);
      expect(jsonDecode((await _invoke(server, args)).output), acceptance);
      await images.dispatchOnce();
      final replay = await _invoke(server, args);
      expect(replay.code, 0, reason: replay.error);
      expect(jsonDecode(replay.output), acceptance);
      final conflict = await _invoke(server, [
        'image',
        'import',
        '--body-json',
        jsonEncode({...body, 'type': 'initrd'}),
        '--idempotency-key',
        'cli-replay',
      ]);
      expect(conflict.code, 1);
      final problem = Problem.fromJson(jsonDecode(conflict.error));
      expect(problem.code, ErrorCode.idempotencyConflict);
      expect(problem.status, 409);
      expect(problem.requestId.value, startsWith('req_'));
      expect(await images.store.list(), hasLength(1));
    },
  );

  test(
    'image import cancellation is queried and waited through public Operations',
    () async {
      final source = await File('${directory.path}/disk').writeAsString('disk');
      final imported = await _invoke(server, [
        'image',
        'import',
        '--body-json',
        jsonEncode({
          'source_path': source.path,
          'type': 'raw-disk',
          'architecture': 'arm64',
        }),
      ]);
      expect(imported.code, 0, reason: imported.error);
      final operationId = jsonDecode(imported.output)['operation_id'] as String;
      final args = [
        'operation',
        'cancel',
        operationId,
        '--idempotency-key',
        'cli-cancel-image',
      ];
      final cancelled = await _invoke(server, args);
      expect(cancelled.code, 0, reason: cancelled.error);
      final action = jsonDecode(cancelled.output) as Map;
      expect(action['state'], 'pending');
      final pending = await _invoke(server, ['operation', 'get', operationId]);
      expect(
        Operation.fromJson(jsonDecode(pending.output)).state,
        OperationState.pending,
      );
      await images.dispatchOnce();
      final target = await _invoke(server, [
        'operation',
        'wait',
        operationId,
        '--timeout-seconds',
        '1',
      ]);
      expect(target.code, 1, reason: target.error);
      expect(
        Operation.fromJson(jsonDecode(target.output)).state,
        OperationState.cancelled,
      );
      final completed = await _invoke(server, [
        'operation',
        'wait',
        action['operation_id'] as String,
        '--timeout-seconds',
        '1',
      ]);
      expect(completed.code, 0, reason: completed.error);
      expect(
        Operation.fromJson(jsonDecode(completed.output)).state,
        OperationState.succeeded,
      );
      final replay = await _invoke(server, args);
      expect(replay.code, 0, reason: replay.error);
      expect(jsonDecode(replay.output), action);
      final refused = await _invoke(server, [
        'operation',
        'cancel',
        operationId,
      ]);
      expect(refused.code, 1);
      expect(
        Problem.fromJson(jsonDecode(refused.error)).code,
        ErrorCode.operationNotCancellable,
      );
      expect(
        jsonDecode((await _invoke(server, ['image', 'list'])).output)['items'],
        isEmpty,
      );
      expect(await source.readAsString(), 'disk');
    },
  );
}

Future<void> _withBoundary(
  Directory directory,
  PublicApiRouter router,
  Future<void> Function(PublicApiServer) run,
) async {
  final boundary = PublicApiServer(
    socketPath: '${directory.path}/fault.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  await boundary.start();
  try {
    await run(boundary);
  } finally {
    await boundary.close();
  }
}

Future<({int code, String output, String error})> _invoke(
  PublicApiServer server,
  List<String> args,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', server.socketPath, ...args, '--json'],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

// VM mutation paths are outside this image/Operation fixture. Image acceptance,
// cancellation, persistence, waiting, and HTTP transport use the real services.
final class _UnusedVmActions implements VmMutationAcceptor, VmConditionWaiter {
  @override
  Future<OperationAcceptance> create(VmCreateCommand _) =>
      throw UnimplementedError();
  @override
  Future<OperationAcceptance> patch(VmPatchCommand _) =>
      throw UnimplementedError();
  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand _) =>
      throw UnimplementedError();
  @override
  Future<DateTime> wait(VmWaitCommand _) => throw UnimplementedError();
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
