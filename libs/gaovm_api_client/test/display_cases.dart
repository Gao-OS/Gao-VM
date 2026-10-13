part of 'client_test.dart';

void _displayTests() {
  final vm = VmId.generate();
  final operation = OperationId.generate();
  final acceptance = {
    'operation_id': operation.value,
    'state': 'pending',
    'resource_type': 'virtual_machine',
    'resource_id': vm.value,
  };
  final snapshot = {
    'vm_id': vm.value,
    'driver_generation': 1,
    'state': 'closed',
    'observed_at': '2026-10-11T03:00:00Z',
  };

  test(
    'typed display actions and status use only the correlated public API',
    () async {
      final paths = <String>[];
      await _serve(
        (request) async {
          paths.add(request.uri.path);
          request.response.headers.contentType = ContentType.json;
          if (request.method == 'POST') {
            expect(request.headers.value('Idempotency-Key'), 'display-retry');
            expect(jsonDecode(await utf8.decoder.bind(request).join()), {});
            request.response.statusCode = 202;
            request.response.write(jsonEncode(acceptance));
          } else {
            expect(request.headers.value('Idempotency-Key'), isNull);
            request.response.write(jsonEncode(snapshot));
          }
          await request.response.close();
        },
        (client) async {
          final opened = await client.openDisplay(
            vm,
            idempotencyKey: 'display-retry',
          );
          final closed = await client.closeDisplay(
            vm,
            idempotencyKey: 'display-retry',
          );
          expect(opened.operationId, operation);
          expect(closed.toJson(), acceptance);
          expect(
            (await client.displayStatus(vm)).toJson(),
            VmDisplayStatus.fromJson(snapshot).toJson(),
          );
          expect(paths, [
            '/v1/vms/${vm.value}/actions/open-display',
            '/v1/vms/${vm.value}/actions/close-display',
            '/v1/vms/${vm.value}/display',
          ]);
        },
      );
    },
  );

  for (final invalid in [
    {...acceptance, 'resource_id': VmId.generate().value},
    {...acceptance, 'resource_type': 'image'},
    {...acceptance, 'operation_id': 'default'},
    {...acceptance, 'state': 'failed'},
    {...acceptance, 'extra': true},
  ]) {
    test(
      'typed display rejects a malformed or misbound acceptance $invalid',
      () async {
        await _serve(
          (request) async {
            request.response.statusCode = 202;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(invalid));
            await request.response.close();
          },
          (client) async {
            await expectLater(
              client.openDisplay(vm, idempotencyKey: 'retry'),
              throwsA(isA<ApiProtocolException>()),
            );
          },
        );
      },
    );
  }

  test(
    'typed status rejects wrong VM identity and HTTP acceptance status',
    () async {
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({...snapshot, 'vm_id': VmId.generate().value}),
          );
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.displayStatus(vm),
            throwsA(isA<ApiProtocolException>()),
          );
        },
      );
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(acceptance));
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.closeDisplay(vm, idempotencyKey: 'retry'),
            throwsA(isA<ApiProtocolException>()),
          );
        },
      );
    },
  );
}
