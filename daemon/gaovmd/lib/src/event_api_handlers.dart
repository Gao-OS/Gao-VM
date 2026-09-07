import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'durable_event_feed.dart';
import 'public_api_server.dart';

final class EventApiHandlers {
  EventApiHandlers({
    required DurableEventFeed feed,
    this.heartbeatInterval = const Duration(seconds: 15),
  }) : _feed = feed {
    if (heartbeatInterval <= Duration.zero) {
      throw ArgumentError.value(heartbeatInterval, 'heartbeatInterval');
    }
  }

  final DurableEventFeed _feed;
  final Duration heartbeatInterval;

  void register(PublicApiRouter router) =>
      router.add('GET', '/v1/events', _watch);

  Future<PublicApiResponse> _watch(PublicApiRequest request) async {
    late int after;
    VmId? vmId;
    OperationId? operationId;
    TestRunId? testRunId;
    try {
      final query = request.uri.queryParametersAll;
      const allowed = {
        'after_sequence',
        'after',
        'vm_id',
        'operation_id',
        'test_run_id',
      };
      for (final entry in query.entries) {
        if (!allowed.contains(entry.key) || entry.value.length != 1) {
          throw const FormatException(
            'unknown or repeated event query parameter',
          );
        }
      }
      final canonical = query['after_sequence']?.single;
      final alias = query['after']?.single;
      final canonicalCursor = canonical == null ? null : _cursor(canonical);
      final aliasCursor = alias == null ? null : _cursor(alias);
      if (canonicalCursor != null &&
          aliasCursor != null &&
          canonicalCursor != aliasCursor) {
        throw const FormatException('after and after_sequence disagree');
      }
      final header = request.headers['last-event-id'];
      if (header != null && header.length != 1) {
        throw const FormatException('Last-Event-ID must appear once');
      }
      after = header == null
          ? canonicalCursor ?? aliasCursor ?? 0
          : _cursor(header.single);
      if (query['vm_id'] case final value?) vmId = VmId(value.single);
      if (query['operation_id'] case final value?)
        operationId = OperationId(value.single);
      if (query['test_run_id'] case final value?)
        testRunId = TestRunId(value.single);
    } on FormatException catch (error) {
      return _invalid(error.message);
    } on ArgumentError catch (error) {
      return _invalid(error.message?.toString() ?? 'invalid event filter');
    }
    return PublicApiResponse.stream(
      body: _encode(
        _feed.watch(
          after: after,
          vmId: vmId,
          operationId: operationId,
          testRunId: testRunId,
        ),
      ),
      contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
      headers: const {'Cache-Control': 'no-cache'},
    );
  }

  Stream<List<int>> _encode(Stream<Event> events) {
    late StreamController<List<int>> output;
    StreamSubscription<Event>? subscription;
    Timer? heartbeat;
    var closed = false;

    void armHeartbeat() {
      heartbeat?.cancel();
      if (closed || output.isPaused) return;
      heartbeat = Timer(heartbeatInterval, () {
        if (closed || output.isPaused) return;
        output.add(utf8.encode(': heartbeat\n\n'));
        armHeartbeat();
      });
    }

    output = StreamController<List<int>>(
      sync: true,
      onListen: () => scheduleMicrotask(() {
        if (closed) return;
        output.add(utf8.encode(': connected\n\n'));
        if (closed) return;
        subscription = events.listen(
          (event) {
            if (closed) return;
            // Omit the optional event-name line: arbitrary durable event types
            // must never become SSE control fields. JSON escapes embedded CR/LF.
            output.add(
              utf8.encode(
                'id: ${event.sequence}\ndata: ${jsonEncode(event.toJson())}\n\n',
              ),
            );
            armHeartbeat();
          },
          onError: (Object error, StackTrace stackTrace) {
            heartbeat?.cancel();
            closed = true;
            output.addError(error, stackTrace);
            unawaited(output.close());
          },
          onDone: () {
            heartbeat?.cancel();
            closed = true;
            unawaited(output.close());
          },
          cancelOnError: true,
        );
        if (closed) {
          unawaited(subscription!.cancel());
        } else if (output.isPaused) {
          subscription!.pause();
        }
        armHeartbeat();
      }),
      onPause: () {
        heartbeat?.cancel();
        subscription?.pause();
      },
      onResume: () {
        subscription?.resume();
        armHeartbeat();
      },
      onCancel: () async {
        closed = true;
        heartbeat?.cancel();
        await subscription?.cancel();
      },
    );
    return output.stream;
  }
}

int _cursor(String value) {
  final parsed = int.tryParse(value);
  if (!RegExp(r'^[0-9]+$').hasMatch(value) || parsed == null || parsed < 0) {
    throw const FormatException(
      'event cursor must be a nonnegative decimal integer',
    );
  }
  return parsed;
}

PublicApiResponse _invalid(String detail) => PublicApiResponse.problem(
  status: HttpStatus.badRequest,
  code: ErrorCode.invalidRequest,
  type: 'invalid-request',
  title: 'Invalid request',
  detail: detail,
  retryable: false,
);
