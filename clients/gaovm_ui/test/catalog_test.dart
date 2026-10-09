import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaovm_ui/main.dart';

// Exercise real HTTP/Unix sockets, not Flutter's default HTTP-400 substitute.
class _SocketTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _SocketTestBinding();

  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final family in ['InstrumentSerif', 'JetBrainsMono']) {
      final loader = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/$family-Regular.ttf'));
      await loader.load();
    }
  });

  testWidgets('connect shows the public VM catalog without selecting a VM', (
    tester,
  ) async {
    await _desktop(tester);
    final api = await tester.runAsync(() => _ApiFixture.open());
    addTearDown(() => api!.close());
    await _connect(tester, api!);

    expect(find.text('gaoos-nightly-network'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('gaoos.channel = nightly'), findsOneWidget);
    expect(find.text('revision 7'), findsOneWidget);
    expect(find.text('Select a VM'), findsOneWidget);
    expect(api.requests, ['GET /v1/vms']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selecting a VM reads its detail and distinguishes applied spec',
    (tester) async {
      await _desktop(tester);
      final api = await tester.runAsync(() => _ApiFixture.open());
      addTearDown(() => api!.close());
      await _connect(tester, api!);
      await tester.runAsync(() async {
        await tester.tap(find.text('gaoos-nightly-network'));
      });
      await _until(tester, find.text('Desired state'));

      expect(find.text('Spec generation'), findsOneWidget);
      expect(find.text('Applied generation'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Driver generation'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('Restart required'), findsOneWidget);
      expect(find.text('4 vCPU · 4096 MiB'), findsWidgets);
      expect(api.requests, [
        'GET /v1/vms',
        'GET /v1/vms/vm_01J00000000000000000000000',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing the UI closes a stalled local request without VM commands',
    (tester) async {
      await _desktop(tester);
      // Latches for real IO must also belong to runAsync's real-clock zone.
      final latches = (await tester.runAsync(
        () async => (Completer<void>(), Completer<void>()),
      ))!;
      final arrived = latches.$1;
      final disconnected = latches.$2;
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            arrived.complete();
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            api.detached.add(socket);
            socket.listen(
              (_) {},
              onDone: () {
                if (!disconnected.isCompleted) disconnected.complete();
              },
              onError: (Object _) {
                if (!disconnected.isCompleted) disconnected.complete();
              },
            );
          },
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async {
        await tester.tap(find.text('Connect'));
        await arrived.future.timeout(const Duration(seconds: 3));
      });
      expect(api.requests, ['GET /v1/vms']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => disconnected.future.timeout(const Duration(seconds: 3)),
      );

      expect(api.requests, ['GET /v1/vms']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a daemon problem preserves its code and request ID and can be retried',
    (tester) async {
      await _desktop(tester);
      var unavailable = true;
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (unavailable) {
              request.response.statusCode = 503;
              request.response.headers.contentType = ContentType(
                'application',
                'problem+json',
              );
              request.response.write(
                jsonEncode({
                  'type': 'https://gaovm.dev/problems/internal-error',
                  'title': 'Daemon not ready',
                  'status': 503,
                  'code': 'INTERNAL_ERROR',
                  'detail': 'Recovery is still running.',
                  'request_id': 'req_01J00000000000000000000000',
                  'retryable': true,
                  'operation_id': null,
                  'details': {},
                }),
              );
            } else {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'items': [_vm()],
                  'next_cursor': null,
                }),
              );
            }
            await request.response.close();
          },
        ),
      ))!;
      addTearDown(api.close);
      await tester.pumpWidget(const GaoVmApp());
      await tester.enterText(find.byType(TextField), api.socketPath);
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('Recovery is still running.'));

      expect(find.text('INTERNAL_ERROR'), findsOneWidget);
      expect(find.text('req_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('Retryable'), findsOneWidget);
      unavailable = false;
      await tester.runAsync(() async => tester.tap(find.text('Connect')));
      await _until(tester, find.text('gaoos-nightly-network'));
      expect(find.text('INTERNAL_ERROR'), findsNothing);
      expect(api.requests, ['GET /v1/vms', 'GET /v1/vms']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('load more preserves the opaque cursor and all catalog rows', (
    tester,
  ) async {
    await _desktop(tester);
    const cursor = 'opaque/+cursor=2';
    final cursors = <String?>[];
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          final current = request.uri.queryParameters['cursor'];
          cursors.add(current);
          await _reply(request, {
            'items': [
              current == null
                  ? _vm()
                  : _vm(
                      id: 'vm_01J00000000000000000000001',
                      name: 'gaoos-secondary',
                    ),
            ],
            'next_cursor': current == null ? cursor : null,
          });
        },
      ),
    ))!;
    addTearDown(api.close);
    await _connect(tester, api);
    expect(find.text('Load more'), findsOneWidget);
    await tester.runAsync(() async => tester.tap(find.text('Load more')));
    await _until(tester, find.text('gaoos-secondary'));

    expect(find.text('gaoos-nightly-network'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Select a VM'), findsOneWidget);
    expect(cursors, [null, cursor]);
    expect(api.requests, ['GET /v1/vms', 'GET /v1/vms']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a delayed previous detail cannot replace the selected VM', (
    tester,
  ) async {
    await _desktop(tester);
    const secondId = 'vm_01J00000000000000000000001';
    final latches = (await tester.runAsync(
      () async => (Completer<void>(), Completer<void>(), Completer<void>()),
    ))!;
    final firstDetail = latches.$1;
    final release = latches.$2;
    final lateReply = latches.$3;
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) async {
          if (request.uri.path == '/v1/vms') {
            await _reply(request, {
              'items': [_vm(), _vm(id: secondId, name: 'gaoos-secondary')],
              'next_cursor': null,
            });
          } else if (request.uri.path.endsWith(secondId)) {
            await _reply(request, _vm(id: secondId, name: 'gaoos-secondary'));
          } else {
            firstDetail.complete();
            await release.future;
            try {
              await _reply(request, _vm());
            } on HttpException {
              // The superseded request is allowed to have closed its connection.
            } on SocketException {
              // Native peer cancellation is also a valid outcome.
            } finally {
              lateReply.complete();
            }
          }
        },
      ),
    ))!;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      return api.close();
    });
    await _connect(tester, api);
    await tester.runAsync(() async {
      await tester.tap(find.text('gaoos-nightly-network'));
      await firstDetail.future.timeout(const Duration(seconds: 3));
    });
    await tester.pump();
    await tester.runAsync(() async => tester.tap(find.text('gaoos-secondary')));
    await _until(tester, find.text('Desired state'));
    await tester.runAsync(() async {
      release.complete();
      await lateReply.future.timeout(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();

    expect(find.text('gaoos-secondary'), findsNWidgets(2));
    expect(find.text('gaoos-nightly-network'), findsOneWidget);
    expect(api.requests, [
      'GET /v1/vms',
      'GET /v1/vms/vm_01J00000000000000000000000',
      'GET /v1/vms/$secondId',
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a successful empty catalog is distinct from a disconnected UI', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) =>
            _reply(request, {'items': [], 'next_cursor': null}),
      ),
    ))!;
    addTearDown(api.close);
    await tester.pumpWidget(const GaoVmApp());
    await tester.enterText(find.byType(TextField), api.socketPath);
    await tester.runAsync(() async => tester.tap(find.text('Connect')));
    await _until(tester, find.text('No virtual machines'));
    expect(find.text('Select a VM'), findsOneWidget);
    expect(api.requests, ['GET /v1/vms']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop catalog and detail render with bundled typography', (
    tester,
  ) async {
    await _desktop(tester);
    final api = (await tester.runAsync(
      () => _ApiFixture.open(
        handler: (request) => _reply(
          request,
          request.uri.path == '/v1/vms'
              ? {
                  'items': [
                    _vm(),
                    _vm(
                      id: 'vm_01J00000000000000000000001',
                      name: 'gaoos-stable-base',
                      phase: 'stopped',
                      desiredState: 'stopped',
                      restartRequired: false,
                    ),
                    _vm(
                      id: 'vm_01J00000000000000000000002',
                      name: 'kernel-debug',
                      phase: 'failed',
                      desiredState: 'stopped',
                      restartRequired: false,
                    ),
                  ],
                  'next_cursor': null,
                }
              : _vm(),
        ),
      ),
    ))!;
    addTearDown(api.close);
    const previewKey = Key('desktop-preview');
    await tester.pumpWidget(
      const RepaintBoundary(key: previewKey, child: GaoVmApp()),
    );
    await tester.enterText(find.byType(TextField), api.socketPath);
    await tester.runAsync(() async => tester.tap(find.text('Connect')));
    await _until(tester, find.text('gaoos-nightly-network'));
    await tester.runAsync(
      () async => tester.tap(find.text('gaoos-nightly-network')),
    );
    await _until(tester, find.text('Desired state'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(previewKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/ui-catalog-preview.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a different VM returned by detail is rejected rather than displayed',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/vms'
                ? {
                    'items': [_vm()],
                    'next_cursor': null,
                  }
                : _vm(id: 'vm_01J00000000000000000000001', name: 'wrong-vm'),
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _connect(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.text('gaoos-nightly-network')),
      );
      await _until(
        tester,
        find.text('VM detail identity disagrees with selection.'),
      );
      expect(find.text('wrong-vm'), findsNothing);
      expect(find.text('Desired state'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'detail shows the freshly observed phase rather than the catalog snapshot',
    (tester) async {
      await _desktop(tester);
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) => _reply(
            request,
            request.uri.path == '/v1/vms'
                ? {
                    'items': [_vm()],
                    'next_cursor': null,
                  }
                : _vm(phase: 'stopping', desiredState: 'stopped'),
          ),
        ),
      ))!;
      addTearDown(api.close);
      await _connect(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.text('gaoos-nightly-network')),
      );
      await _until(tester, find.text('Desired state'));

      expect(find.text('Observed phase'), findsOneWidget);
      expect(find.text('stopping'), findsOneWidget);
      expect(find.text('stopped'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'start accepts a durable Operation without claiming the VM is running',
    (tester) async {
      await _desktop(tester);
      final keys = <String?>[];
      final bodies = <Object?>[];
      final api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
              request.response.statusCode = 202;
              await _reply(request, {
                'operation_id': 'op_01J00000000000000000000000',
                'state': 'pending',
                'resource_type': 'virtual_machine',
                'resource_id': 'vm_01J00000000000000000000000',
              });
            } else {
              final vm = _vm(
                phase: 'stopped',
                desiredState: 'stopped',
                restartRequired: false,
              );
              await _reply(
                request,
                request.uri.path == '/v1/vms'
                    ? {
                        'items': [vm],
                        'next_cursor': null,
                      }
                    : vm,
              );
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connect(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.text('gaoos-nightly-network')),
      );
      await _until(tester, find.text('Desired state'));
      await tester.runAsync(() async => tester.tap(find.text('Start')));
      await _until(tester, find.text('Accepted · pending'));

      expect(find.text('op_01J00000000000000000000000'), findsOneWidget);
      expect(find.text('running'), findsNothing);
      expect(keys.single, matches(RegExp(r'^ui-[0-9a-f]{32}$')));
      expect(bodies, [{}]);
      expect(api.requests, [
        'GET /v1/vms',
        'GET /v1/vms/vm_01J00000000000000000000000',
        'POST /v1/vms/vm_01J00000000000000000000000/actions/start',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a lost start response retries the same VM intent with the same key',
    (tester) async {
      await _desktop(tester);
      final keys = <String?>[];
      final bodies = <Object?>[];
      late _ApiFixture api;
      api = (await tester.runAsync(
        () => _ApiFixture.open(
          handler: (request) async {
            if (request.method == 'POST') {
              keys.add(request.headers.value('Idempotency-Key'));
              bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
              if (keys.length == 1) {
                // The daemon may have committed the intent before this EOF.
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                api.detached.add(socket);
                socket.destroy();
                return;
              }
              request.response.statusCode = 202;
              await _reply(request, {
                'operation_id': 'op_01J00000000000000000000000',
                'state': 'pending',
                'resource_type': 'virtual_machine',
                'resource_id': 'vm_01J00000000000000000000000',
              });
            } else {
              final vm = _vm(
                phase: 'stopped',
                desiredState: 'stopped',
                restartRequired: false,
              );
              await _reply(
                request,
                request.uri.path == '/v1/vms'
                    ? {
                        'items': [vm],
                        'next_cursor': null,
                      }
                    : vm,
              );
            }
          },
        ),
      ))!;
      addTearDown(api.close);
      await _connect(tester, api);
      await tester.runAsync(
        () async => tester.tap(find.text('gaoos-nightly-network')),
      );
      await _until(tester, find.text('Desired state'));
      await tester.runAsync(() async => tester.tap(find.text('Start')));
      await _until(tester, find.text('Retry Start'));
      expect(find.text('Outcome unknown'), findsOneWidget);
      await tester.runAsync(() async => tester.tap(find.text('Retry Start')));
      await _until(tester, find.text('Accepted · pending'));

      expect(keys, hasLength(2));
      expect(keys.first, matches(RegExp(r'^ui-[0-9a-f]{32}$')));
      expect(keys.last, keys.first);
      expect(bodies, [{}, {}]);
      expect(find.text('running'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(api.requests, [
        'GET /v1/vms',
        'GET /v1/vms/vm_01J00000000000000000000000',
        'POST /v1/vms/vm_01J00000000000000000000000/actions/start',
        'POST /v1/vms/vm_01J00000000000000000000000/actions/start',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _reply(HttpRequest request, Object body) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _desktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _connect(WidgetTester tester, _ApiFixture api) async {
  await tester.pumpWidget(const GaoVmApp());
  await tester.enterText(find.byType(TextField), api.socketPath);
  await tester.runAsync(() async => tester.tap(find.text('Connect')));
  await _until(tester, find.text('gaoos-nightly-network'));
}

Future<void> _until(WidgetTester tester, Finder visible) async {
  final elapsed = Stopwatch()..start();
  while (visible.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 3)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(visible, findsWidgets);
  await tester.pumpAndSettle();
}

class _ApiFixture {
  _ApiFixture(this.directory, this.listener, this.server);

  final Directory directory;
  final ServerSocket listener;
  final HttpServer server;
  final requests = <String>[];
  final detached = <Socket>[];
  String get socketPath => '${directory.path}/api.sock';

  static Future<_ApiFixture> open({
    Future<void> Function(HttpRequest)? handler,
  }) async {
    final directory = await Directory.systemTemp.createTemp('gvm-ui-');
    final listener = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/api.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final server = HttpServer.listenOn(listener);
    final api = _ApiFixture(directory, listener, server);
    server.listen((request) async {
      api.requests.add('${request.method} ${request.uri.path}');
      if (handler != null) {
        await handler(request);
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/v1/vms'
              ? {
                  'items': [_vm()],
                  'next_cursor': null,
                }
              : _vm(),
        ),
      );
      await request.response.close();
    });
    return api;
  }

  Future<void> close() async {
    for (final socket in detached) {
      socket.destroy();
    }
    await server.close(force: true);
    // HttpServer.listenOn does not take ownership of its listening socket.
    await listener.close();
    await directory.delete(recursive: true);
  }
}

Map<String, Object?> _vm({
  String id = 'vm_01J00000000000000000000000',
  String name = 'gaoos-nightly-network',
  String phase = 'running',
  String desiredState = 'running',
  bool restartRequired = true,
}) => {
  'api_version': 'gaovm.io/v1alpha1',
  'kind': 'VirtualMachine',
  'metadata': {
    'id': id,
    'name': name,
    'labels': {'gaoos.channel': 'nightly'},
    'revision': 7,
    'created_at': '2026-09-04T08:00:00Z',
    'updated_at': '2026-09-04T08:10:00Z',
  },
  'spec': {
    'backend': 'vz',
    'architecture': 'arm64',
    'guest_profile': 'gaoos',
    'cpu': 4,
    'memory_bytes': 4294967296,
    'boot': {
      'type': 'linux_kernel',
      'kernel_image_id': 'img_01J00000000000000000000001',
      'command_line': 'console=hvc0',
    },
    'disks': [
      {
        'id': 'root',
        'source': {
          'type': 'managed_image',
          'image_id': 'img_01J00000000000000000000003',
        },
        'writable': true,
      },
    ],
    'networks': [
      {'id': 'net0', 'mode': 'shared'},
    ],
    'graphics': {
      'enabled': true,
      'width': 1280,
      'height': 800,
      'pixels_per_inch': 144,
    },
    'serial': {'enabled': true, 'capture': true},
    'guest_agent': {
      'enabled': true,
      'required_for_ready': true,
      'vsock_port': 10777,
    },
    'restart_policy': 'on_failure',
  },
  'status': {
    'desired_state': desiredState,
    'phase': phase,
    'spec_generation': 3,
    'observed_generation': 2,
    'driver_generation': 8,
    'guest_agent': 'ready',
    'restart_required': restartRequired,
    'last_transition_at': '2026-09-04T08:10:00Z',
    'last_error': null,
  },
};
