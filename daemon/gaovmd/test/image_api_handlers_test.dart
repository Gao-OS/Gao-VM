import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_api_handlers.dart';
import 'package:gaovmd/src/image_application_service.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/public_api_server.dart';
import 'package:gaovmd/src/rotating_logger.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late ImageApplicationService images;
  late PublicApiServer server;
  late RotatingLogger logger;
  late HttpClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gvm-image-api-');
    imageFileMode(directory.path, 0x1c0);
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    images = ImageApplicationService(
      database: database,
      store: ImageStore(database, Directory('${directory.path}/images')),
    );
    final router = PublicApiRouter();
    ImageApiHandlers(images: images).register(router);
    logger = RotatingLogger(path: '${directory.path}/daemon.log');
    server = PublicApiServer(
      socketPath: '${directory.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
      logger: logger,
    );
    await server.start();
    client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(server.socketPath, type: InternetAddressType.unix),
        0,
      );
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    await logger.flush();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})>
  request(String method, String path, {String? body, String? key}) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) request.headers.set('Idempotency-Key', key);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    return (
      status: response.statusCode,
      body:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
      headers: response.headers,
    );
  }

  test('deletion rechecks VM references made after acceptance', () async {
    final source = await File(
      '${directory.path}/disk',
    ).writeAsString('base-disk');
    final image = await images.store.importFile(
      source,
      type: ImageType.rawDisk,
    );
    final accepted = await request('DELETE', '/v1/images/${image.id.value}');
    expect(accepted.status, 202);
    await SqliteVmRepository(database).create(
      name: 'retains-image',
      spec: VmSpec(
        cpu: 2,
        memoryBytes: 2147483648,
        boot: EfiBoot(),
        disks: [
          VmDisk(
            id: 'root',
            source: ManagedImageDiskSource(image.id),
            writable: true,
          ),
        ],
        networks: [SharedNetwork(id: 'net0')],
        graphics: GraphicsConfig(enabled: false),
        serial: const SerialConfig(enabled: true, capture: true),
        guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
        restartPolicy: RestartPolicy.never,
      ),
    );
    await images.dispatchOnce();
    final operation = (await SqliteOperationRepository(
      database,
    ).get(OperationId(accepted.body['operation_id'] as String)))!;
    expect(operation.state, OperationState.failed);
    expect(operation.error!.code, ErrorCode.imageInUse);
    expect((await request('GET', '/v1/images')).body['items'], hasLength(1));
    expect(
      await (await images.store.objectFile(image.id, 'payload')).readAsString(),
      'base-disk',
    );
    final rejected = await request('DELETE', '/v1/images/${image.id.value}');
    expect(rejected.status, 409);
    expect(rejected.body['code'], 'IMAGE_IN_USE');
  });

  test(
    'rejects malformed queries and import fields before acceptance',
    () async {
      for (final query in [
        'limit=0',
        'limit=201',
        'limit=1&limit=2',
        'extra=1',
        'cursor=!',
        'label_selector=%3Dwrong',
      ]) {
        final rejected = await request('GET', '/v1/images?$query');
        expect(rejected.status, 400, reason: query);
        expect(rejected.body['code'], 'INVALID_REQUEST');
      }
      final valid = {
        'source_path': '/missing',
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      for (final body in [
        {...valid, 'architecture': 'x64'},
        {...valid, 'unexpected': true},
        {...valid, 'labels': null},
        {
          ...valid,
          'labels': {'x' * 254: 'v'},
        },
        {...valid, 'version': 1},
        {...valid, 'source_path': ''},
      ]) {
        final rejected = await request(
          'POST',
          '/v1/images/import',
          body: jsonEncode(body),
        );
        expect(rejected.status, 400, reason: body.toString());
        expect(rejected.body['code'], 'INVALID_REQUEST');
      }
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(await images.store.directory.exists(), isFalse);
    },
  );

  test('imports and lists images over the public Unix HTTP socket', () async {
    final source = await File(
      '${directory.path}/kernel',
    ).writeAsString('kernel');
    final body = jsonEncode({
      'source_path': source.path,
      'type': 'linux-kernel',
      'architecture': 'arm64',
    });
    final accepted = await request(
      'POST',
      '/v1/images/import',
      body: body,
      key: 'same-import',
    );
    expect(accepted.status, 202);
    expect(accepted.body['state'], 'pending');
    expect(
      accepted.headers.value('location'),
      '/v1/operations/${accepted.body['operation_id']}',
    );
    expect(accepted.headers.value('x-request-id'), startsWith('req_'));
    await logger.flush();
    final log = await File(logger.path).readAsString();
    final record = const LineSplitter()
        .convert(log)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .singleWhere(
          (record) =>
              record['request_id'] == accepted.headers.value('x-request-id'),
        );
    expect(record['operation_id'], accepted.body['operation_id']);
    expect(record['vm_id'], isNull);
    expect(log, isNot(contains(source.path)));
    expect((await request('GET', '/v1/images')).body['items'], isEmpty);
    await images.dispatchOnce();
    final catalog = await request('GET', '/v1/images');
    expect(catalog.status, 200);
    expect(catalog.body['next_cursor'], isNull);
    expect(
      (catalog.body['items'] as List).single['id'],
      accepted.body['resource_id'],
    );
    final replay = await request(
      'POST',
      '/v1/images/import',
      body: body,
      key: 'same-import',
    );
    expect(replay.status, 202);
    expect(replay.body, accepted.body);
    final operation = (await SqliteOperationRepository(
      database,
    ).get(OperationId(accepted.body['operation_id'] as String)))!;
    expect(operation.state, OperationState.succeeded);
  });

  test('deletes an image through a durable replayable operation', () async {
    final source = await File(
      '${directory.path}/disk',
    ).writeAsString('base-disk');
    final imported = await request(
      'POST',
      '/v1/images/import',
      body: jsonEncode({
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      }),
    );
    await images.dispatchOnce();
    final id = imported.body['resource_id'] as String;
    final accepted = await request(
      'DELETE',
      '/v1/images/$id',
      key: 'delete-image',
    );
    expect(accepted.status, 202);
    expect((await request('GET', '/v1/images')).body['items'], hasLength(1));
    await images.dispatchOnce();
    expect((await request('GET', '/v1/images')).body['items'], isEmpty);
    expect(
      (await SqliteOperationRepository(
        database,
      ).get(OperationId(accepted.body['operation_id'] as String)))!.state,
      OperationState.succeeded,
    );
    final replay = await request(
      'DELETE',
      '/v1/images/$id',
      key: 'delete-image',
    );
    expect(replay.status, 202);
    expect(replay.body, accepted.body);
    expect(await source.readAsString(), 'base-disk');
  });

  test(
    'catalog pagination is selector-bound and survives removal of its anchor',
    () async {
      for (final name in ['one', 'two', 'other']) {
        final source = await File(
          '${directory.path}/$name',
        ).writeAsString(name);
        final body = jsonEncode({
          'source_path': source.path,
          'type': 'initrd',
          'architecture': 'arm64',
          'labels': {'suite': name == 'other' ? 'other' : 'smoke'},
        });
        expect(
          (await request('POST', '/v1/images/import', body: body)).status,
          202,
        );
        await images.dispatchOnce();
      }
      final first = await request(
        'GET',
        '/v1/images?limit=1&label_selector=suite%3Dsmoke',
      );
      expect(first.status, 200);
      expect(first.body['items'], hasLength(1));
      final cursor = first.body['next_cursor'] as String;
      final firstId = ImageId(
        (first.body['items'] as List).single['id'] as String,
      );
      await images.store.delete(firstId);
      final second = await request(
        'GET',
        '/v1/images?limit=1&label_selector=suite%3Dsmoke&cursor=${Uri.encodeQueryComponent(cursor)}',
      );
      expect(second.status, 200);
      expect(second.body['items'], hasLength(1));
      expect((second.body['items'] as List).single['id'], isNot(firstId.value));
      expect(second.body['next_cursor'], isNull);
      final wrongSelector = await request(
        'GET',
        '/v1/images?label_selector=suite%3Dother&cursor=${Uri.encodeQueryComponent(cursor)}',
      );
      expect(wrongSelector.status, 400);
      expect(wrongSelector.body['code'], 'INVALID_REQUEST');
    },
  );
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
