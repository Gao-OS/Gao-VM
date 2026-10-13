import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/driver_runtime_layout.dart';
import 'package:gaovmd/src/guest_bridge_client.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'joined opening failure retains its owner until the original status worker actually settles',
    () async {
      final fixture = await _BridgeFixture.create();
      final started = Completer<void>();
      final release = Completer<void>();
      final client = GuestBridgeClient(
        paths: fixture.paths,
        correlation: fixture.correlation,
        authToken: _token,
        isSessionActive: () => true,
        sessionClosed: Completer<Object?>().future,
        prepareOpening: (_) async {
          started.complete();
          await release.future;
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await client.close();
        await fixture.close();
      });
      var settled = false;
      final observed = client
          .openAndJoin(
            streamKind: GuestBridgeStreamKind.binary,
            requestId: _requestId,
            operationId: OperationId.generate(),
            deadline: GuestBridgeDeadline.after(
              const Duration(milliseconds: 50),
            ),
          )
          .then<Object>(
            (_) {
              settled = true;
              return 'unexpected handoff';
            },
            onError: (Object error) {
              settled = true;
              return error;
            },
          );
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(settled, isFalse);
      release.complete();
      expect(await observed, _failure(GuestBridgeFailure.deadlineExpired));
    },
  );
  test(
    'matched ready strips the bridge frame and preserves coalesced guest bytes',
    () async {
      final fixture = await _BridgeFixture.create();
      final sessionClosed = Completer<Object?>();
      final client = GuestBridgeClient(
        paths: fixture.paths,
        correlation: fixture.correlation,
        authToken: _token,
        isSessionActive: () => true,
        sessionClosed: sessionClosed.future,
      );
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = () async {
        final socket = await fixture.accept();
        final reader = _PeerReader(socket);
        fixture.readers.add(reader);
        final opening = jsonDecode(utf8.decode(await reader.frame())) as Map;
        expect(opening['protocol_version'], 'gaovm.bridge.v1');
        expect(opening['auth_token'], _token);
        expect(opening['vm_id'], fixture.correlation.vmId.value);
        expect(opening['driver_generation'], 8);
        final ready = Map<String, Object?>.from(opening)
          ..remove('auth_token')
          ..['kind'] = 'ready';
        socket.add(_frame(ready) + utf8.encode('GAB1'));
        await socket.flush();
        expect(await reader.read(3), utf8.encode('RAW'));
      }();
      final channel = await client.open(
        streamKind: GuestBridgeStreamKind.control,
        requestId: RequestId('req_01J00000000000000000000001'),
        operationId: null,
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
      );
      expect(
        await channel.readExact(
          4,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
        ),
        utf8.encode('GAB1'),
      );
      await channel.write(
        Uint8List.fromList(utf8.encode('RAW')),
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      );
      await peer;
      await channel.close();
    },
  );

  test(
    'escaped duplicate response correlation is rejected before handoff',
    () async {
      final fixture = await _BridgeFixture.create();
      final client = fixture.client();
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = fixture.respond((opening) {
        final ready = jsonEncode(_ready(opening));
        return '{"\\u0076m_id":"untrusted",${ready.substring(1)}';
      });
      await expectLater(
        client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
        ),
        throwsA(_failure(GuestBridgeFailure.invalidResponse)),
      );
      final reader = await peer;
      expect(await reader.iterator.moveNext(), isFalse);
    },
  );

  test(
    'fractional generation must not round into the active generation',
    () async {
      final fixture = await _BridgeFixture.create();
      final client = fixture.client();
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = fixture.respond(
        (opening) => jsonEncode(_ready(opening)).replaceFirst(
          '"driver_generation":8',
          '"driver_generation":8.0000000000000001',
        ),
      );
      await expectLater(
        client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
        ),
        throwsA(_failure(GuestBridgeFailure.invalidResponse)),
      );
      expect(await (await peer).iterator.moveNext(), isFalse);
    },
  );

  test(
    'integer-valued decimal and exponent generations remain compatible',
    () async {
      for (final generation in ['8.0', '8000e-0003', '0.8e1']) {
        final fixture = await _BridgeFixture.create();
        final client = fixture.client();
        addTearDown(() async {
          await client.close();
          await fixture.close();
        });
        final peer = fixture.respond(
          (opening) => jsonEncode(_ready(opening)).replaceFirst(
            '"driver_generation":8',
            '"driver_generation":$generation',
          ),
        );
        final channel = await client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
        );
        await channel.close();
        expect(await (await peer).iterator.moveNext(), isFalse);
      }
    },
  );

  test(
    'kernel peer UID mismatch closes before transmitting the token',
    () async {
      final fixture = await _BridgeFixture.create();
      final client = fixture.client(expectedPeerUID: -1);
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final received = () async {
        final socket = await fixture.accept();
        return socket.fold<List<int>>([], (all, bytes) => all..addAll(bytes));
      }();
      await expectLater(
        client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
        ),
        throwsA(_failure(GuestBridgeFailure.authenticationFailed)),
      );
      expect(await received, isEmpty);
    },
  );

  test(
    'original driver session EOF fences and closes an in-flight opening',
    () async {
      final fixture = await _BridgeFixture.create();
      final sessionClosed = Completer<Object?>();
      final client = fixture.client(sessionClosed: sessionClosed.future);
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final opened = Completer<void>();
      final peer = () async {
        final socket = await fixture.accept();
        final reader = _PeerReader(socket);
        fixture.readers.add(reader);
        await reader.frame();
        opened.complete();
        expect(await reader.iterator.moveNext(), isFalse);
      }();
      final failure = expectLater(
        client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
        ),
        throwsA(_failure(GuestBridgeFailure.closed)),
      );
      await opened.future;
      sessionClosed.complete(null);
      await failure;
      await peer.timeout(const Duration(seconds: 1));
      await expectLater(
        client.open(
          streamKind: GuestBridgeStreamKind.control,
          requestId: _requestId,
          operationId: null,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
        ),
        throwsA(_failure(GuestBridgeFailure.closed)),
      );
    },
  );

  test(
    'session EOF closes established raw I/O without waiting for its deadline',
    () async {
      final fixture = await _BridgeFixture.create();
      final sessionClosed = Completer<Object?>();
      final client = fixture.client(sessionClosed: sessionClosed.future);
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = fixture.respond((opening) => jsonEncode(_ready(opening)));
      final channel = await client.open(
        streamKind: GuestBridgeStreamKind.control,
        requestId: _requestId,
        operationId: null,
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 2)),
      );
      final pendingRead = expectLater(
        channel.readExact(
          1,
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 5)),
        ),
        throwsA(_failure(GuestBridgeFailure.closed)),
      );
      sessionClosed.complete(null);
      await pendingRead.timeout(const Duration(seconds: 1));
      await channel.closed.timeout(const Duration(seconds: 1));
      expect(await (await peer).iterator.moveNext(), isFalse);
    },
  );

  test(
    'every response binding and exact key set is checked before handoff',
    () async {
      final changes = <Map<String, Object?> Function(Map<String, Object?>)>[
        (ready) => {...ready, 'protocol_version': 'gaovm.bridge.other'},
        (ready) => {...ready, 'vm_id': 'vm_01J00000000000000000000002'},
        (ready) => {...ready, 'driver_generation': 9},
        (ready) => {...ready, 'request_id': 'req_01J00000000000000000000002'},
        (ready) => {...ready, 'operation_id': 'op_01J00000000000000000000001'},
        (ready) => {...ready, 'stream_kind': 'binary'},
        (ready) => {...ready, 'kind': 'open'},
        (ready) => {...ready, 'auth_token': _token},
        (ready) => {...ready}..remove('operation_id'),
        (ready) => {...ready, 'driver_generation': '8'},
        (ready) => {...ready, 'kind': 'error', 'code': 'UNKNOWN_CODE'},
      ];
      for (final change in changes) {
        final fixture = await _BridgeFixture.create();
        final client = fixture.client();
        try {
          final peer = fixture.respond(
            (opening) => jsonEncode(change(_ready(opening))),
          );
          await expectLater(
            _openBridge(client),
            throwsA(_failure(GuestBridgeFailure.invalidResponse)),
          );
          expect(await (await peer).iterator.moveNext(), isFalse);
        } finally {
          await client.close();
          await fixture.close();
        }
      }
    },
  );

  test(
    'invalid lengths and UTF-8 are rejected without guest-byte handoff',
    () async {
      final oversized = Uint8List(4);
      ByteData.sublistView(oversized).setUint32(0, 4097, Endian.big);
      for (final frame in [
        Uint8List(4),
        oversized,
        _frameBytes([0xff]),
      ]) {
        final fixture = await _BridgeFixture.create();
        final client = fixture.client();
        try {
          final peer = fixture.respondBytes((_) => frame);
          await expectLater(
            _openBridge(client),
            throwsA(_failure(GuestBridgeFailure.invalidResponse)),
          );
          expect(await (await peer).iterator.moveNext(), isFalse);
        } finally {
          await client.close();
          await fixture.close();
        }
      }
    },
  );

  test(
    'fragmented response prefix does not renew the original opening deadline',
    () async {
      final fixture = await _BridgeFixture.create();
      final client = fixture.client();
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = () async {
        final socket = await fixture.accept();
        final reader = _PeerReader(socket);
        fixture.readers.add(reader);
        final opening = Map<String, Object?>.from(
          jsonDecode(utf8.decode(await reader.frame())) as Map,
        );
        final ready = _frame(_ready(opening));
        var closed = false;
        final eof = reader.iterator.moveNext().then((hasBytes) {
          expect(hasBytes, isFalse);
          closed = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 120));
        socket.add(ready.sublist(0, 4));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!closed) {
          socket.add(ready.sublist(4));
          await socket.flush();
        }
        await eof;
      }();
      await expectLater(
        _openBridge(client, budget: const Duration(milliseconds: 300)),
        throwsA(_failure(GuestBridgeFailure.deadlineExpired)),
      );
      await peer.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'a backpressured bounded write expires and closes its owned descriptor',
    () async {
      final fixture = await _BridgeFixture.create();
      final client = fixture.client();
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = () async {
        final socket = await fixture.accept();
        socket.setRawOption(
          RawSocketOption.fromInt(
            RawSocketOption.levelSocket,
            Platform.isMacOS ? 0x1002 : 8,
            4096,
          ),
        );
        final reader = _PeerReader(socket);
        fixture.readers.add(reader);
        final opening = Map<String, Object?>.from(
          jsonDecode(utf8.decode(await reader.frame())) as Map,
        );
        socket.add(_frame(_ready(opening)));
        await socket.flush();
        // Keep the real input subscription paused after the opening frame.
      }();
      final channel = await _openBridge(client);
      await peer;
      final buffer = Uint8List(8192);
      var writes = 0;
      await expectLater(() async {
        for (; writes < 4096; writes++) {
          await channel.write(
            buffer,
            deadline: GuestBridgeDeadline.after(
              const Duration(milliseconds: 150),
            ),
          );
        }
      }(), throwsA(_failure(GuestBridgeFailure.deadlineExpired)));
      expect(writes, lessThan(4096));
      await channel.closed.timeout(const Duration(seconds: 1));
    },
  );
  test(
    'maximum safe generation retains exact integer-valued decimal compatibility',
    () async {
      final fixture = await _BridgeFixture.create(generation: 9007199254740991);
      final client = fixture.client();
      addTearDown(() async {
        await client.close();
        await fixture.close();
      });
      final peer = fixture.respond(
        (opening) => jsonEncode(_ready(opening)).replaceFirst(
          '"driver_generation":9007199254740991',
          '"driver_generation":9007199254740991.0',
        ),
      );
      final channel = await _openBridge(client);
      await channel.close();
      expect(await (await peer).iterator.moveNext(), isFalse);
    },
  );
}

const _token = 'test-only-generation-token';
final _requestId = RequestId('req_01J00000000000000000000001');

Future<GuestBridgeChannel> _openBridge(
  GuestBridgeClient client, {
  Duration budget = const Duration(seconds: 2),
}) => client.open(
  streamKind: GuestBridgeStreamKind.control,
  requestId: _requestId,
  operationId: null,
  deadline: GuestBridgeDeadline.after(budget),
);

Matcher _failure(GuestBridgeFailure code) => isA<GuestBridgeException>().having(
  (error) => error.code,
  'failure code',
  code,
);

Map<String, Object?> _ready(Map<String, Object?> opening) =>
    Map<String, Object?>.from(opening)
      ..remove('auth_token')
      ..['kind'] = 'ready';

final class _BridgeFixture {
  _BridgeFixture(
    this.root,
    this.layout,
    this.paths,
    this.listener,
    this.correlation,
  ) : accepted = StreamIterator(listener);
  final Directory root;
  final DriverRuntimeLayout layout;
  final DriverRuntimePaths paths;
  final ServerSocket listener;
  final StreamIterator<Socket> accepted;
  final sockets = <Socket>[];
  final readers = <_PeerReader>[];
  final DriverCorrelation correlation;

  static Future<_BridgeFixture> create({int generation = 8}) async {
    final root =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvb-');
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
      throw StateError('could not protect bridge fixture');
    return _BridgeFixture(root, layout, paths, listener, correlation);
  }

  Future<Socket> accept() async {
    if (!await accepted.moveNext()) throw StateError('fixture listener closed');
    final socket = accepted.current;
    sockets.add(socket);
    return socket;
  }

  GuestBridgeClient client({
    Future<Object?>? sessionClosed,
    bool Function()? isSessionActive,
    int? expectedPeerUID,
  }) => GuestBridgeClient(
    paths: paths,
    correlation: correlation,
    authToken: _token,
    isSessionActive: isSessionActive ?? () => true,
    sessionClosed: sessionClosed ?? Completer<Object?>().future,
    expectedPeerUID: expectedPeerUID,
  );

  Future<_PeerReader> respond(
    String Function(Map<String, Object?> opening) response,
  ) => respondBytes((opening) => _frameBytes(utf8.encode(response(opening))));

  Future<_PeerReader> respondBytes(
    Uint8List Function(Map<String, Object?> opening) response,
  ) async {
    final socket = await accept();
    final reader = _PeerReader(socket);
    readers.add(reader);
    final opening = Map<String, Object?>.from(
      jsonDecode(utf8.decode(await reader.frame())) as Map,
    );
    socket.add(response(opening));
    await socket.flush();
    return reader;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    for (final reader in readers) {
      await reader.iterator.cancel();
    }
    await accepted.cancel();
    await listener.close();
    await layout.remove(paths);
    await root.delete(recursive: true);
  }
}

final class _PeerReader {
  _PeerReader(Socket socket) : iterator = StreamIterator(socket);
  final StreamIterator<Uint8List> iterator;
  final pending = <int>[];

  Future<Uint8List> read(int count) async {
    while (pending.length < count) {
      if (!await iterator.moveNext()) throw StateError('fixture peer EOF');
      pending.addAll(iterator.current);
    }
    final result = Uint8List.fromList(pending.take(count).toList());
    pending.removeRange(0, count);
    return result;
  }

  Future<Uint8List> frame() async {
    final length = ByteData.sublistView(await read(4)).getUint32(0, Endian.big);
    if (length < 1 || length > 4096)
      throw StateError('fixture invalid opening length');
    return read(length);
  }
}

Uint8List _frame(Map<String, Object?> body) {
  return _frameBytes(utf8.encode(jsonEncode(body)));
}

Uint8List _frameBytes(List<int> payload) {
  final frame = Uint8List(4 + payload.length);
  ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
  frame.setRange(4, frame.length, payload);
  return frame;
}
