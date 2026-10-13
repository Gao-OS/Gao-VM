import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/driver_runtime_layout.dart';
import 'package:gaovmd/src/guest_bridge_client.dart';
import 'package:gaovmd/src/guest_exec_request.dart';
import 'package:gaovmd/src/host_guest_session.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'collection descriptors cannot exceed the authorized file count',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final collecting = connection.artifactCollect(
        operationId: OperationId.generate(),
        request: JsonObjectValue.fromJson({
          'paths': [
            {'path': '/a', 'kind': 'file'},
          ],
          'max_total_bytes': 8,
        }),
        deadline: _deadline(),
      );
      final rejected = expectLater(
        collecting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      await guest.reply(await guest.read(), {
        'artifacts': [
          for (final index in [0, 1])
            {
              'artifact_id': ArtifactId.generate().value,
              'kind': 'file',
              'content_type': 'application/octet-stream',
              'size_bytes': 3,
              'digest': 'sha256:${'1' * 64}',
              'stream_id': '${index + 2}' * 64,
            },
        ],
      });
      await rejected;
      await connection.closed;
    },
  );
  test(
    'invalid unsent collection input preserves the original healthy control epoch',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      await expectLater(
        connection.artifactCollect(
          operationId: OperationId.generate(),
          request: JsonObjectValue.fromJson({
            'paths': [],
            'max_total_bytes': 8,
          }),
          deadline: _deadline(),
        ),
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      expect(connection.isReady, isTrue);
      final health = connection.health(deadline: _deadline());
      final call = await guest.read();
      expect(call['method'], 'health');
      await guest.reply(call, _health);
      await health;
    },
  );
  test(
    'collection aggregate accounting cannot wrap a large sibling size past its original budget',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final params = JsonObjectValue.fromJson({
        'paths': [
          {'path': '/a', 'kind': 'file'},
          {'path': '/b', 'kind': 'file'},
        ],
        'max_total_bytes': 8,
      });
      final collecting = connection.artifactCollect(
        operationId: OperationId.generate(),
        request: params,
        deadline: _deadline(),
      );
      final rejected = expectLater(
        collecting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      await guest.reply(await guest.read(), {
        'artifacts': [
          for (final (index, size) in [(0, 3), (1, 9223372036854775807)])
            {
              'artifact_id': ArtifactId.generate().value,
              'kind': 'file',
              'content_type': 'application/octet-stream',
              'size_bytes': size,
              'digest': 'sha256:${'1' * 64}',
              'stream_id': '${index + 2}' * 64,
            },
        ],
      });
      await rejected;
      await connection.closed;
      expect(session.isReady, isFalse);
    },
  );
  test(
    'artifact collection returns operation-bound immutable descriptors from the original control connection',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final operation = OperationId.generate();
      final params = JsonObjectValue.fromJson({
        'paths': [
          {'path': '/var/log/gaoos.log', 'kind': 'guest-log'},
        ],
        'max_total_bytes': 8,
        'follow_symlinks': false,
      });
      final collecting = connection.artifactCollect(
        operationId: operation,
        request: params,
        deadline: _deadline(),
      );
      final call = await guest.read();
      expect(call['method'], 'artifact.collect');
      expect(call['operation_id'], operation.value);
      expect(call['params'], params.toJson());
      final descriptor = {
        'artifact_id': ArtifactId.generate().value,
        'kind': 'guest-log',
        'content_type': 'application/octet-stream',
        'size_bytes': 3,
        'digest': 'sha256:${'1' * 64}',
        'stream_id': '2' * 64,
      };
      await guest.reply(call, {
        'artifacts': [descriptor],
      });
      final result = await collecting;
      expect(result.toJson(), {
        'artifacts': [descriptor],
      });
      (result.toJson()['artifacts'] as List).clear();
      expect(result.toJson()['artifacts'], hasLength(1));
      expect(connection.isReady, isTrue);
    },
  );
  for (final token in ['1.00000000000000000000001', '9007199254740990.5']) {
    test(
      'a fractional exec duration cannot round into an integer: $token',
      () async {
        final fixture = await _GuestFixture.create();
        final session = fixture.session();
        addTearDown(() async {
          await session.close();
          await fixture.close();
        });
        final (connection, guest) = await _ready(fixture, session);
        final status = connection.execStatus(
          operationId: OperationId.generate(),
          request: GuestExecRequest.fromJson({
            'argv': ['gaoos-test'],
            'cwd': '/',
            'env': <String, String>{},
            'timeout_seconds': 1,
            'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
          }),
          deadline: _deadline(),
        );
        final call = await guest.read()
          ..remove('params');
        final prefix = jsonEncode({...call, 'kind': 'response'});
        guest.socket.add(
          _frame(
            '${prefix.substring(0, prefix.length - 1)},"result":{"state":"succeeded","exit_code":0,"stdout":{"mode":"inline","text":"","truncated":false,"size_bytes":0},"stderr":{"mode":"inline","text":"","truncated":false,"size_bytes":0},"duration_ms":$token,"timed_out":false}}',
          ),
        );
        await guest.socket.flush();
        await expectLater(
          status,
          throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
        );
        await connection.closed;
        expect(session.isReady, isFalse);
      },
    );
  }

  test(
    'an oversized unsent exec request preserves the healthy control epoch',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final request = GuestExecRequest.fromJson({
        'argv': List.filled(130, 'x' * 131072),
        'cwd': '/',
        'env': <String, String>{},
        'timeout_seconds': 1,
        'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
      });
      await expectLater(
        connection.execStart(
          operationId: OperationId.generate(),
          request: request,
          deadline: _deadline(),
        ),
        throwsA(_sessionFailure(GuestSessionFailure.limitExceeded)),
      );
      expect(connection.isReady, isTrue);
      expect(session.isReady, isTrue);
      final health = connection.health(deadline: _deadline());
      final call = await guest.read();
      expect(call['method'], 'health');
      await guest.reply(call, _health);
      await health;
      expect(fixture.openingRequests, 1);
    },
  );

  test(
    'exec results accept exact integer-valued decimal and exponent JSON numbers',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final status = connection.execStatus(
        operationId: OperationId.generate(),
        request: GuestExecRequest.fromJson({
          'argv': ['gaoos-test'],
          'cwd': '/',
          'env': <String, String>{},
          'timeout_seconds': 1,
          'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
        }),
        deadline: _deadline(),
      );
      final call = await guest.read()
        ..remove('params');
      final prefix = jsonEncode({...call, 'kind': 'response'});
      guest.socket.add(
        _frame(
          '${prefix.substring(0, prefix.length - 1)},"result":{"state":"succeeded","exit_code":0.0,"stdout":{"mode":"inline","text":"ok","truncated":false,"size_bytes":20e-1},"stderr":{"mode":"inline","text":"","truncated":false,"size_bytes":0e10},"duration_ms":1.00e2,"timed_out":false,"signal":null}}',
        ),
      );
      await guest.socket.flush();
      final result = (await status).toJson();
      expect(result['exit_code'], 0);
      expect(result['duration_ms'], 100);
      expect((result['stdout'] as Map)['size_bytes'], 2);
      expect(connection.isReady, isTrue);
    },
  );

  test(
    'pending exec status leaves cancellation responsive on the same operation epoch',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final operation = OperationId.generate();
      final request = GuestExecRequest.fromJson({
        'argv': ['gaoos-test'],
        'cwd': '/',
        'env': <String, String>{},
        'timeout_seconds': 1,
        'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
      });
      final status = connection.execStatus(
        operationId: operation,
        request: request,
        deadline: _deadline(),
      );
      final cancellation = connection.execCancel(
        operationId: operation,
        request: request,
        deadline: _deadline(),
      );
      final statusRequest = await guest.read();
      final cancelRequest = await guest.read();
      expect(statusRequest['method'], 'exec.status');
      expect(cancelRequest['method'], 'exec.cancel');
      for (final call in [statusRequest, cancelRequest]) {
        expect(call['params'], isEmpty);
        expect(call['operation_id'], operation.value);
      }
      final cancelled = {
        'state': 'cancelled',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'stderr': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'duration_ms': 1,
        'timed_out': false,
        'signal': 9,
      };
      await guest.reply(cancelRequest, cancelled);
      expect((await cancellation).toJson(), cancelled);
      await guest.reply(statusRequest, cancelled);
      expect((await status).toJson(), cancelled);
      expect(session.isReady, isTrue);
      expect(fixture.openingRequests, 1);
    },
  );

  test(
    'oversized inline exec output fails closed instead of bypassing the capture budget',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final starting = connection.execStart(
        operationId: OperationId.generate(),
        request: GuestExecRequest.fromJson({
          'argv': ['gaoos-test'],
          'cwd': '/',
          'env': <String, String>{},
          'timeout_seconds': 1,
          'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 4},
        }),
        deadline: _deadline(),
      );
      await guest.reply(await guest.read(), {
        'state': 'succeeded',
        'exit_code': 0,
        'stdout': {
          'mode': 'inline',
          'text': '12345',
          'truncated': false,
          'size_bytes': 5,
        },
        'stderr': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'duration_ms': 1,
        'timed_out': false,
      });
      await expectLater(
        starting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      await connection.closed;
      expect(session.isReady, isFalse);
    },
  );

  test(
    'exec start preserves argv data and binds the original VM generation and operation',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final operation = OperationId.generate();
      final params = {
        'argv': ['gaoos-test', 'a b', r'$(not-a-host-command)', '中文'],
        'cwd': '/guest/tests',
        'env': {'TEST_MODE': 'smoke'},
        'timeout_seconds': 30,
        'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 65536},
      };
      final starting = connection.execStart(
        operationId: operation,
        request: GuestExecRequest.fromJson(params),
        deadline: _deadline(),
      );
      final request = await guest.read();
      expect(request['method'], 'exec.start');
      expect(request['params'], params);
      expect(request['operation_id'], operation.value);
      expect(request['vm_id'], fixture.correlation.vmId.value);
      expect(
        request['driver_generation'],
        fixture.correlation.driverGeneration,
      );
      final result = {
        'state': 'running',
        'exit_code': null,
        'stdout': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'stderr': {
          'mode': 'inline',
          'text': '',
          'truncated': false,
          'size_bytes': 0,
        },
        'duration_ms': 0,
        'timed_out': false,
      };
      await guest.reply(request, result);
      expect((await starting).toJson(), result);
      expect(connection.isReady, isTrue);
    },
  );

  test(
    'refresh checks healthy guests on the same epoch instead of returning cached readiness',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final refreshed = session.refresh(deadline: _deadline());
      final request = await guest.read();
      expect(request['method'], 'health');
      await guest.reply(request, _health);
      expect(await refreshed, same(connection));
      expect(fixture.openingRequests, 1);
      expect(session.isReady, isTrue);
    },
  );

  test(
    'guest readiness observations fence every health change and reconnect',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      final observed = <GuestReadinessObservation>[];
      final subscription = session.readiness.listen(observed.add);
      addTearDown(() async {
        await session.close();
        await subscription.cancel();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      expect(observed.map((event) => event.ready), [true]);
      final checking = connection.health(deadline: _deadline());
      await guest.reply(await guest.read(), {..._health, 'status': 'degraded'});
      await checking;
      expect(observed.map((event) => event.ready), [true, false]);
      final refreshing = session.connect(deadline: _deadline());
      await guest.reply(await guest.read(), _health);
      expect(await refreshing, same(connection));
      guest.socket.destroy();
      await connection.closed;
      final replacementPeer = () async {
        final next = await fixture.accept();
        await next.hello();
        await next.reply(await next.read(), _health);
      }();
      await session.connect(deadline: _deadline());
      await replacementPeer;
      await connection.close();
      expect(observed.map((event) => event.ready), [
        true,
        false,
        true,
        false,
        true,
      ]);
      expect(observed.map((event) => event.revision), [1, 2, 3, 4, 5]);
      expect(
        observed.every(
          (event) =>
              event.correlation.vmId == fixture.correlation.vmId &&
              event.correlation.driverGeneration ==
                  fixture.correlation.driverGeneration,
        ),
        isTrue,
      );
      await session.close();
      expect(observed.last.ready, isFalse);
      expect(observed.last.revision, 6);
    },
  );

  test(
    'bridge admission and hello alone cannot publish guest readiness',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final healthReceived = Completer<void>();
      final allowHealth = Completer<void>();
      final peer = () async {
        final guest = await fixture.accept();
        await guest.hello();
        final health = await guest.read();
        expect(health['method'], 'health');
        expect(health['operation_id'], isNull);
        healthReceived.complete();
        await allowHealth.future;
        await guest.reply(health, _health);
      }();
      final connecting = session.connect(deadline: _deadline());
      await healthReceived.future;
      expect(session.isReady, isFalse);
      allowHealth.complete();
      final connection = await connecting;
      expect(session.isReady, isTrue);
      expect(connection.isReady, isTrue);
      expect(connection.capabilities, unorderedEquals(_core));
      expect(() => connection.capabilities.clear(), throwsUnsupportedError);
      await peer;
    },
  );

  test(
    'escaped duplicate hello members fail before guest acknowledgement',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(
        deadline: _deadline(const Duration(milliseconds: 300)),
      );
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.reply(Map<String, Object?>.from(host), {
        'accepted_capabilities': _core.toList(),
      });
      final hello =
          jsonEncode({
            ...host,
            'id': 'guest-hello',
            'params': {
              'peer_role': 'guest',
              'offered_capabilities': _core.toList(),
              'required_capabilities': _core.toList(),
            },
          }).replaceFirst(
            '"required_capabilities":',
            '"\\u0072equired_capabilities":[],"required_capabilities":',
          );
      guest.socket.add(_frame(hello));
      await guest.socket.flush();
      await expectLater(
        connecting,
        throwsA(
          isA<GuestSessionException>().having(
            (error) => error.code,
            'failure',
            GuestSessionFailure.invalidMessage,
          ),
        ),
      );
      expect(session.isReady, isFalse);
      expect(guest.pending, isEmpty);
      expect(await guest.iterator.moveNext(), isFalse);
    },
  );

  test(
    'idle guest EOF revokes readiness without waiting for another request',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final peer = () async {
        final guest = await fixture.accept();
        await guest.hello();
        await guest.reply(await guest.read(), _health);
        return guest;
      }();
      final connection = await session.connect(deadline: _deadline());
      expect(session.isReady, isTrue);
      (await peer).socket.destroy();
      await connection.closed.timeout(const Duration(milliseconds: 500));
      expect(connection.isReady, isFalse);
      expect(session.isReady, isFalse);
    },
  );

  test(
    'ninth pending request is rejected without closing eight admitted requests',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final results = [
        for (var index = 0; index < 8; index++)
          connection
              .health(deadline: _deadline())
              .then<Object>(
                (result) => result,
                onError: (Object error) => error,
              ),
      ];
      final requests = [
        for (var index = 0; index < 8; index++) await guest.read(),
      ];
      await expectLater(
        connection.health(deadline: _deadline()),
        throwsA(_sessionFailure(GuestSessionFailure.limitExceeded)),
      );
      expect(connection.isReady, isTrue);
      for (var index = 7; index >= 0; index--) {
        await guest.reply(requests[index], {
          ..._health,
          'uptime_seconds': index,
        });
      }
      for (var index = 0; index < 8; index++) {
        final result = await results[index];
        expect(
          result,
          isA<GuestHealth>().having(
            (health) => health.uptimeSeconds,
            'matched response',
            index,
          ),
        );
      }
    },
  );

  test(
    'correlated guest health errors remain typed and do not force reconnect',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final health = connection.health(deadline: _deadline());
      final result = expectLater(
        health,
        throwsA(
          isA<GuestRemoteException>()
              .having(
                (error) => error.code,
                'wire error',
                'GUEST_INTERNAL_ERROR',
              )
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.toString(),
                'redacted diagnostic',
                isNot(contains('private-guest-path')),
              ),
        ),
      );
      final request = await guest.read();
      await guest.send({
        ...request..remove('params'),
        'kind': 'error',
        'error': {
          'code': 'GUEST_INTERNAL_ERROR',
          'message': 'private-guest-path',
          'retryable': true,
        },
      });
      await result;
      expect(session.isReady, isFalse);
      final healthy = connection.health(deadline: _deadline());
      await guest.reply(await guest.read(), _health);
      expect((await healthy).status, 'ok');
      expect(session.isReady, isTrue);
      expect(fixture.peers, hasLength(1));
    },
  );

  test(
    'degraded health is refreshed on the same live per-VM control epoch',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final health = connection.health(deadline: _deadline());
      await guest.reply(await guest.read(), {..._health, 'status': 'degraded'});
      expect((await health).status, 'degraded');
      expect(session.isReady, isFalse);
      final reconnecting = session
          .connect(deadline: _deadline())
          .then<Object>((result) => result, onError: (Object error) => error);
      final refresh = await guest.read().timeout(
        const Duration(milliseconds: 300),
      );
      expect(refresh['method'], 'health');
      await guest.reply(refresh, _health);
      expect(await reconnecting, same(connection));
      expect(session.isReady, isTrue);
      expect(fixture.peers, hasLength(1));
    },
  );

  test(
    'optional guest agent metadata still obeys the frozen hello schema',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(
        deadline: _deadline(const Duration(milliseconds: 300)),
      );
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.reply(Map<String, Object?>.from(host), {
        'accepted_capabilities': _core.toList(),
      });
      await guest.send({
        ..._guestHello(host),
        'params': {
          ...(_guestHello(host)['params'] as Map),
          'agent': {'name': '', 'version': '1'},
        },
      });
      await expectLater(
        connecting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      expect(session.isReady, isFalse);
      expect(await guest.iterator.moveNext(), isFalse);
    },
  );

  test('closing before admission prevents a late bridge opening', () async {
    final fixture = await _GuestFixture.create();
    final session = fixture.session();
    addTearDown(fixture.close);
    final connecting = session.connect(
      deadline: _deadline(const Duration(milliseconds: 100)),
    );
    final result = expectLater(
      connecting,
      throwsA(_sessionFailure(GuestSessionFailure.closed)),
    );
    await session.close();
    await result;
    expect(fixture.openingRequests, 0);
    expect(session.isReady, isFalse);
  });

  test(
    'system info is operation-correlated and returned as immutable validated JSON',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final operation = OperationId('op_01J00000000000000000000001');
      final info = connection.systemInfo(
        deadline: _deadline(),
        operationId: operation,
      );
      final request = await guest.read();
      expect(request['method'], 'system.info');
      expect(request['operation_id'], operation.value);
      final body = <String, Object?>{
        'os': {
          'name': 'GaoOS',
          'version': 'test',
          'build_id': null,
          'channel': 'test',
        },
        'kernel': 'fixture-kernel',
        'architecture': 'aarch64',
        'hostname': 'fixture',
        'boot_id': null,
      };
      await guest.reply(request, body);
      final value = await info;
      expect(value.toJson(), body);
      expect(
        () => (value.toJson()['os'] as Map)['version'] = 'caller-copy',
        throwsUnsupportedError,
      );
      expect((value.toJson()['os'] as Map)['version'], 'test');
      expect(session.isReady, isTrue);
    },
  );

  test(
    'reconnect creates a new epoch and late old closure cannot fence it',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (old, guest) = await _ready(fixture, session);
      final operation = OperationId('op_01J00000000000000000000001');
      final pending = old.health(deadline: _deadline(), operationId: operation);
      final failed = expectLater(
        pending,
        throwsA(_sessionFailure(GuestSessionFailure.disconnected)),
      );
      expect((await guest.read())['operation_id'], operation.value);
      guest.socket.destroy();
      await failed;
      await old.closed;
      expect(session.isReady, isFalse);
      final (current, replacement) = await _ready(fixture, session);
      expect(current, isNot(same(old)));
      await old.close(GuestSessionFailure.invalidMessage);
      expect(session.isReady, isTrue);
      final health = current.health(deadline: _deadline());
      final request = await replacement.read();
      expect(request['operation_id'], isNull);
      await replacement.reply(request, _health);
      expect((await health).status, 'ok');
      expect(fixture.openingRequests, 2);
    },
  );

  test(
    'idle time is unbounded but one partial-frame budget cannot renew',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session(
        frameTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(session.isReady, isTrue);
      guest.socket.add([0]);
      await guest.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      guest.socket.add([0]);
      await guest.socket.flush();
      await connection.closed.timeout(const Duration(milliseconds: 130));
      expect(session.isReady, isFalse);
    },
  );

  test(
    'concurrent connect calls share one admitted channel and hello',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final first = session.connect(deadline: _deadline());
      final second = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      await guest.hello();
      await guest.reply(await guest.read(), _health);
      expect(await first, same(await second));
      expect(fixture.openingRequests, 1);
    },
  );

  test(
    'guest hello first still requires the host hello acknowledgement',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.send(_guestHello(host));
      expect((await guest.read())['kind'], 'response');
      expect(session.isReady, isFalse);
      await guest.reply(Map<String, Object?>.from(host), {
        'accepted_capabilities': _core.toList(),
      });
      await guest.reply(await guest.read(), _health);
      expect((await connecting).isReady, isTrue);
    },
  );

  for (final token in ['8.0', '8000e-0003', '0.8e1']) {
    test('exact generation retains legal JSON number $token', () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      await guest.hello(generationToken: token);
      await guest.reply(await guest.read(), _health);
      expect((await connecting).isReady, isTrue);
    });
  }

  for (final entry in <String, Object?>{
    'protocol_version': 'gaovm.guest.bad',
    'vm_id': 'vm_01J00000000000000000000001',
    'driver_generation': 9,
    'operation_id': 'op_01J00000000000000000000001',
    'id': 'another-host-hello',
    'method': 'health',
    'extra': 'unexpected',
  }.entries) {
    test('hello rejects mismatched ${entry.key} before readiness', () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.send({
        ...host..remove('params'),
        'kind': 'response',
        'result': {'accepted_capabilities': _core.toList()},
        entry.key: entry.value,
      });
      await expectLater(
        connecting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      expect(session.isReady, isFalse);
      expect(await guest.iterator.moveNext(), isFalse);
    });
  }

  test(
    'fractional near-safe-limit generations cannot round into the current epoch',
    () async {
      final fixture = await _GuestFixture.create(generation: 9007199254740991);
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      final host = await guest.read();
      final ack =
          jsonEncode({
            ...host..remove('params'),
            'kind': 'response',
            'result': {'accepted_capabilities': _core.toList()},
          }).replaceFirst(
            '"driver_generation":9007199254740991',
            '"driver_generation":9007199254740990.5',
          );
      guest.socket.add(_frame(ack));
      await guest.socket.flush();
      await expectLater(
        connecting,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      expect(session.isReady, isFalse);
    },
  );

  test(
    'expired unsent requests leave the healthy guest epoch usable',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final expired = _deadline(const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await expectLater(
        connection.health(deadline: expired),
        throwsA(_sessionFailure(GuestSessionFailure.deadlineExpired)),
      );
      expect(session.isReady, isTrue);
      final health = connection.health(deadline: _deadline());
      await guest.reply(await guest.read(), _health);
      expect((await health).status, 'ok');
      expect(fixture.openingRequests, 1);
    },
  );

  test(
    'large exact generation coefficients remain valid across bounded reads',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      await guest.hello(generationToken: '8${'0' * 16384}e-16384');
      await guest.reply(await guest.read(), _health);
      expect((await connecting).isReady, isTrue);
    },
  );

  for (final entry in <String, Object?>{
    'protocol_version': 'gaovm.guest.bad',
    'vm_id': 'vm_01J00000000000000000000001',
    'driver_generation': 9,
    'operation_id': 'op_01J00000000000000000000002',
    'id': 'another-request',
    'method': 'system.info',
    'extra': true,
  }.entries) {
    test(
      'application reply rejects wrong ${entry.key} without completing health',
      () async {
        final fixture = await _GuestFixture.create();
        final session = fixture.session();
        addTearDown(() async {
          await session.close();
          await fixture.close();
        });
        final (connection, guest) = await _ready(fixture, session);
        final operation = OperationId('op_01J00000000000000000000001');
        final health = connection.health(
          deadline: _deadline(),
          operationId: operation,
        );
        final rejected = expectLater(
          health,
          throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
        );
        final request = await guest.read();
        await guest.send({
          ...request..remove('params'),
          'kind': 'response',
          'result': _health,
          entry.key: entry.value,
        });
        await rejected;
        await connection.closed;
        expect(session.isReady, isFalse);
      },
    );
  }

  test(
    'a valid execution notification cannot complete a pending health request',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      var completed = false;
      final operation = OperationId('op_01J00000000000000000000001');
      final health = connection
          .health(deadline: _deadline(), operationId: operation)
          .then((result) {
            completed = true;
            return result;
          });
      final request = await guest.read();
      final eventBinding = Map<String, Object?>.from(request)
        ..remove('params')
        ..remove('id');
      await guest.send({
        ...eventBinding,
        'kind': 'event',
        'method': 'exec.state_changed',
        'occurred_at': '2026-10-11T00:00:00Z',
        'payload': {'exec_state': 'succeeded'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      await guest.reply(request, _health);
      expect((await health).status, 'ok');
      expect(session.isReady, isTrue);
    },
  );

  for (final missing in ['health', 'artifact.collect']) {
    test('guest hello cannot omit P0 $missing', () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.send({
        ..._guestHello(host),
        'params': {
          'peer_role': 'guest',
          'offered_capabilities': _core
              .where((capability) => capability != missing)
              .toList(),
          'required_capabilities': [],
        },
      });
      await expectLater(
        connecting,
        throwsA(_sessionFailure(GuestSessionFailure.capabilityMismatch)),
      );
      expect(session.isReady, isFalse);
      expect(await guest.iterator.moveNext(), isFalse);
    });
  }

  test(
    'optional P1 offerings do not become required or negotiated host features',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(deadline: _deadline());
      final guest = await fixture.accept();
      final host = await guest.read();
      await guest.send({
        ..._guestHello(host),
        'params': {
          'peer_role': 'guest',
          'offered_capabilities': [..._core, 'service.status'],
          'required_capabilities': _core.toList(),
          'agent': {'name': 'gaovm-guestd', 'version': 'fixture'},
        },
      });
      final ack = await guest.read();
      expect(
        (ack['result'] as Map)['accepted_capabilities'],
        unorderedEquals(_core),
      );
      await guest.reply(Map<String, Object?>.from(host), {
        'accepted_capabilities': _core.toList(),
      });
      await guest.reply(await guest.read(), _health);
      expect(
        (await connecting).capabilities,
        isNot(contains('service.status')),
      );
    },
  );

  test('requiring an unsupported P1 capability fails the handshake', () async {
    final fixture = await _GuestFixture.create();
    final session = fixture.session();
    addTearDown(() async {
      await session.close();
      await fixture.close();
    });
    final connecting = session.connect(deadline: _deadline());
    final guest = await fixture.accept();
    final host = await guest.read();
    await guest.send({
      ..._guestHello(host),
      'params': {
        'peer_role': 'guest',
        'offered_capabilities': [..._core, 'service.status'],
        'required_capabilities': [..._core, 'service.status'],
      },
    });
    await expectLater(
      connecting,
      throwsA(_sessionFailure(GuestSessionFailure.capabilityMismatch)),
    );
    expect(session.isReady, isFalse);
  });

  test(
    'a single handshake direction cannot renew the original opening budget',
    () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final connecting = session.connect(
        deadline: _deadline(const Duration(milliseconds: 200)),
      );
      final rejected = expectLater(
        connecting,
        throwsA(_sessionFailure(GuestSessionFailure.deadlineExpired)),
      );
      final guest = await fixture.accept();
      final host = await guest.read();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await guest.reply(Map<String, Object?>.from(host), {
        'accepted_capabilities': _core.toList(),
      });
      await rejected;
      expect(session.isReady, isFalse);
      expect(await guest.iterator.moveNext(), isFalse);
    },
  );

  for (final payload in [
    '[]',
    '{"status":"ok","status":"degraded","uptime_seconds":1}',
    '{"status":"ok","uptime_seconds":1,"checks":{"a":"ok","\\u0061":"failed"}}',
    '{"status":"ok","uptime_seconds":-1}',
    '{"status":"ok","uptime_seconds":1e999}',
    '{"status":"ok","uptime_seconds":1,"extra":true}',
    '{"status":"ok","uptime_seconds":1,"checks":{"a":"\\ud800"}}',
  ]) {
    test('malformed health result is rejected: $payload', () async {
      final fixture = await _GuestFixture.create();
      final session = fixture.session();
      addTearDown(() async {
        await session.close();
        await fixture.close();
      });
      final (connection, guest) = await _ready(fixture, session);
      final health = connection.health(deadline: _deadline());
      final rejected = expectLater(
        health,
        throwsA(_sessionFailure(GuestSessionFailure.invalidMessage)),
      );
      final request = await guest.read();
      final response = jsonEncode({
        ...request..remove('params'),
        'kind': 'response',
      });
      guest.socket.add(
        _frame(
          '${response.substring(0, response.length - 1)},"result":$payload}',
        ),
      );
      await guest.socket.flush();
      await rejected;
      await connection.closed;
      expect(session.isReady, isFalse);
    });
  }

  for (final length in [0, 16 * 1024 * 1024 + 1, 4294967295]) {
    test(
      'control frame length $length is rejected before payload reads',
      () async {
        final fixture = await _GuestFixture.create();
        final session = fixture.session();
        addTearDown(() async {
          await session.close();
          await fixture.close();
        });
        final (connection, guest) = await _ready(fixture, session);
        final prefix = Uint8List(4);
        ByteData.sublistView(prefix).setUint32(0, length, Endian.big);
        guest.socket.add(prefix);
        await guest.socket.flush();
        await connection.closed.timeout(const Duration(milliseconds: 500));
        expect(session.isReady, isFalse);
      },
    );
  }
}

const _core = {
  'health',
  'system.info',
  'exec.start',
  'exec.status',
  'exec.cancel',
  'artifact.collect',
};
const _health = <String, Object?>{
  'status': 'ok',
  'uptime_seconds': 1.25,
  'checks': {'dispatcher': 'ok'},
};
GuestBridgeDeadline _deadline([Duration budget = const Duration(seconds: 3)]) =>
    GuestBridgeDeadline.after(budget);

Matcher _sessionFailure(GuestSessionFailure failure) =>
    isA<GuestSessionException>().having(
      (error) => error.code,
      'failure',
      failure,
    );

Map<String, Object?> _guestHello(Map<String, Object?> host) => {
  ...host,
  'id': 'guest-hello',
  'params': {
    'peer_role': 'guest',
    'offered_capabilities': _core.toList(),
    'required_capabilities': _core.toList(),
  },
};

Future<(GuestControlConnection, _GuestPeer)> _ready(
  _GuestFixture fixture,
  HostGuestSession session,
) async {
  final peer = () async {
    final guest = await fixture.accept();
    await guest.hello();
    await guest.reply(await guest.read(), _health);
    return guest;
  }();
  final connection = await session.connect(deadline: _deadline());
  return (connection, await peer);
}

final class _GuestFixture implements GuestBridgeProvider {
  _GuestFixture(
    this.root,
    this.layout,
    this.paths,
    this.listener,
    this.correlation,
  ) : accepted = StreamIterator(listener) {
    bridge = GuestBridgeClient(
      paths: paths,
      correlation: correlation,
      authToken: 'fixture-private-token',
      isSessionActive: () => true,
      sessionClosed: rootClosed.future,
    );
  }
  final Directory root;
  final DriverRuntimeLayout layout;
  final DriverRuntimePaths paths;
  final ServerSocket listener;
  final StreamIterator<Socket> accepted;
  final DriverCorrelation correlation;
  final Completer<Object?> rootClosed = Completer<Object?>();
  late final GuestBridgeClient bridge;
  final peers = <_GuestPeer>[];
  int openingRequests = 0;

  static Future<_GuestFixture> create({int generation = 8}) async {
    final root =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvs-');
    final layout = DriverRuntimeLayout('${root.path}/run');
    final correlation = DriverCorrelation(
      vmId: VmId('vm_01J00000000000000000000000'),
      driverGeneration: generation,
      operationId: null,
    );
    final paths = await layout.create(correlation);
    final listener = await ServerSocket.bind(
      InternetAddress(paths.guestSocketPath, type: InternetAddressType.unix),
      0,
    );
    final chmod = await Process.run('/bin/chmod', [
      '600',
      paths.guestSocketPath,
    ]);
    if (chmod.exitCode != 0)
      throw StateError('fixture socket protection failed');
    return _GuestFixture(root, layout, paths, listener, correlation);
  }

  HostGuestSession session({
    Duration frameTimeout = const Duration(seconds: 2),
  }) => HostGuestSession(
    bridge: this,
    correlation: correlation,
    frameTimeout: frameTimeout,
  );

  @override
  Future<GuestBridgeChannel> openGuestChannel({
    required GuestBridgeStreamKind streamKind,
    required RequestId requestId,
    required OperationId? operationId,
    required GuestBridgeDeadline deadline,
  }) {
    openingRequests++;
    return bridge.open(
      streamKind: streamKind,
      requestId: requestId,
      operationId: operationId,
      deadline: deadline,
    );
  }

  Future<_GuestPeer> accept() async {
    if (!await accepted.moveNext()) throw StateError('fixture listener closed');
    final peer = _GuestPeer(accepted.current);
    peers.add(peer);
    final opening = await peer.read();
    expect(opening['protocol_version'], 'gaovm.bridge.v1');
    expect(opening['auth_token'], 'fixture-private-token');
    expect(opening['stream_kind'], 'control');
    await peer.send({...opening..remove('auth_token'), 'kind': 'ready'});
    return peer;
  }

  Future<void> close() async {
    await bridge.close();
    for (final peer in peers) {
      peer.socket.destroy();
      await peer.iterator.cancel();
    }
    await accepted.cancel();
    await listener.close();
    await layout.remove(paths);
    await root.delete(recursive: true);
  }
}

final class _GuestPeer {
  _GuestPeer(this.socket) : iterator = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> iterator;
  final pending = <int>[];
  Map<String, Object?>? binding;

  Future<Uint8List> bytes(int count) async {
    while (pending.length < count) {
      if (!await iterator.moveNext()) throw StateError('fixture EOF');
      pending.addAll(iterator.current);
    }
    final value = Uint8List.fromList(pending.take(count).toList());
    pending.removeRange(0, count);
    return value;
  }

  Future<Map<String, Object?>> read() async {
    final count = ByteData.sublistView(await bytes(4)).getUint32(0, Endian.big);
    if (count < 1 || count > 16 * 1024 * 1024)
      throw StateError('fixture length');
    return Map<String, Object?>.from(
      jsonDecode(utf8.decode(await bytes(count))) as Map,
    );
  }

  Future<void> send(Map<String, Object?> message) async {
    socket.add(_frame(jsonEncode(message)));
    await socket.flush();
  }

  Future<void> reply(
    Map<String, Object?> request,
    Map<String, Object?> result,
  ) => send({
    ...request..remove('params'),
    'kind': 'response',
    'result': result,
  });

  Future<void> hello({String? generationToken}) async {
    final host = await read();
    binding = Map<String, Object?>.from(host);
    expect(host['protocol_version'], 'gaovm.guest.v1');
    expect(host['kind'], 'request');
    expect(host['method'], 'session.hello');
    expect((host['params'] as Map)['peer_role'], 'host');
    await reply(Map<String, Object?>.from(host), {
      'accepted_capabilities': _core.toList(),
    });
    final message = jsonEncode(_guestHello(host));
    socket.add(
      _frame(
        generationToken == null
            ? message
            : message.replaceFirst(
                '"driver_generation":${host['driver_generation']}',
                '"driver_generation":$generationToken',
              ),
      ),
    );
    await socket.flush();
    final ack = await read();
    expect(ack['kind'], 'response');
    expect(ack['id'], 'guest-hello');
    expect(
      (ack['result'] as Map)['accepted_capabilities'],
      unorderedEquals(_core),
    );
  }
}

Uint8List _frame(String json) {
  final bytes = utf8.encode(json);
  final frame = Uint8List(4 + bytes.length);
  ByteData.sublistView(frame).setUint32(0, bytes.length, Endian.big);
  frame.setRange(4, frame.length, bytes);
  return frame;
}
