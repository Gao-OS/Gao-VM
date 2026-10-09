import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

part 'src/event_stream.dart';

/// A transport boundary only: no SQLite, VM controller, or driver dependency.
/// Each request owns its connection, which is closed even on a local deadline.
final class GaoVmApiClient {
  GaoVmApiClient({required String socketPath})
    : socketPath = File(socketPath).absolute.path;
  final String socketPath;

  /// Resume explicitly after the last consumed sequence. No automatic retry.
  /// The deadline bounds the entire subscription, including idle heartbeats.
  Stream<Event> watchEvents({
    int afterSequence = 0,
    String? lastEventId,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final cursor = lastEventId == null
        ? afterSequence
        : int.tryParse(lastEventId);
    if (afterSequence < 0 ||
        timeout <= Duration.zero ||
        cursor == null ||
        cursor < 0 ||
        lastEventId != null && !RegExp(r'^[0-9]+$').hasMatch(lastEventId)) {
      throw ArgumentError(
        'nonnegative cursors and a positive timeout are required',
      );
    }
    return _watchEvents(
      socketPath,
      {
        'after_sequence': '$afterSequence',
        if (vmId != null) 'vm_id': vmId.value,
        if (operationId != null) 'operation_id': operationId.value,
        if (testRunId != null) 'test_run_id': testRunId.value,
      },
      lastEventId,
      cursor,
      timeout,
    );
  }

  /// [cancellation] releases the local connection, not a durable Operation.
  Future<ApiResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    JsonObjectValue? body,
    String? idempotencyKey,
    String? ifMatch,
    ApiRequestCancellation? cancellation,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!path.startsWith('/v1/') || timeout <= Duration.zero) {
      throw ArgumentError(
        'a public /v1 path and positive timeout are required',
      );
    }
    if (cancellation?.isCancelled == true) {
      throw const ApiRequestCancelledException();
    }
    final client = _newHttpClient(socketPath, timeout);
    final cancelled = cancellation == null ? null : Completer<ApiResponse>();
    final unsubscribe = cancellation?._subscribe(() {
      if (!cancelled!.isCompleted) {
        cancelled.completeError(const ApiRequestCancelledException());
      }
      client.close(force: true);
    });
    try {
      final response = _send(
        client,
        method,
        path,
        query,
        body,
        idempotencyKey,
        ifMatch,
      ).timeout(timeout, onTimeout: () => throw ApiTimeoutException(timeout));
      return await (cancelled == null
          ? response
          : Future.any([response, cancelled.future]));
    } on SocketException catch (error) {
      throw ApiTransportException(error.toString());
    } on HttpException catch (error) {
      throw ApiTransportException(error.toString());
    } finally {
      unsubscribe?.call();
      client.close(force: true);
    }
  }

  Future<ApiResponse> _send(
    HttpClient client,
    String method,
    String path,
    Map<String, String>? query,
    JsonObjectValue? body,
    String? idempotencyKey,
    String? ifMatch,
  ) async {
    final request = await client.openUrl(
      method,
      Uri(
        scheme: 'http',
        host: 'localhost',
        path: path,
        queryParameters: query,
      ),
    );
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, application/problem+json',
    );
    if (idempotencyKey != null)
      request.headers.set('Idempotency-Key', idempotencyKey);
    if (ifMatch != null)
      request.headers.set(HttpHeaders.ifMatchHeader, ifMatch);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body.toJson())));
    }
    final response = await request.close();
    final json = await _readPublicJson(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const ApiProtocolException('unexpected HTTP response status');
    }
    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name] = values.join(', '),
    );
    return ApiResponse(response.statusCode, json, Map.unmodifiable(headers));
  }
}

/// One-way local cancellation; completed requests detach their listeners.
final class ApiRequestCancellation {
  var _cancelled = false;
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() _subscribe(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

final class ApiRequestCancelledException implements Exception {
  const ApiRequestCancelledException();

  @override
  String toString() => 'public API request was cancelled';
}

HttpClient _newHttpClient(String socketPath, Duration timeout) => HttpClient()
  ..findProxy = ((_) => 'DIRECT')
  ..connectionTimeout = timeout
  ..connectionFactory = (_, _, _) => Socket.startConnect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );

Future<JsonObjectValue> _readPublicJson(HttpClientResponse response) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (bytes.length + chunk.length > 1024 * 1024)
      throw const ApiProtocolException('JSON response exceeds 1 MiB');
    bytes.add(chunk);
  }
  final type = response.headers.contentType?.mimeType;
  if (type != 'application/json' && type != 'application/problem+json')
    throw const ApiProtocolException('response is not JSON');
  try {
    final json = JsonObjectValue.fromJson(
      jsonDecode(utf8.decode(bytes.takeBytes())),
    );
    if (response.statusCode >= 400) {
      final problem = Problem.fromJson(json.toJson());
      if (problem.status != response.statusCode)
        throw const ApiProtocolException('problem status disagrees with HTTP');
      throw ApiProblemException(problem);
    }
    return json;
  } on FormatException {
    throw const ApiProtocolException(
      'response does not match the JSON contract',
    );
  } on ArgumentError {
    throw const ApiProtocolException(
      'response does not match the JSON contract',
    );
  }
}

final class ApiResponse {
  const ApiResponse(this.status, this.body, this.headers);
  final int status;
  final JsonObjectValue body;
  final Map<String, String> headers;
  String? get requestId => headers['x-request-id'];
  String? get etag => headers['etag'];
}

final class ApiProblemException implements Exception {
  const ApiProblemException(this.problem);
  final Problem problem;
  @override
  String toString() => problem.detail;
}

final class ApiTimeoutException implements Exception {
  const ApiTimeoutException(this.timeout);
  final Duration timeout;
  @override
  String toString() =>
      'public API request exceeded ${timeout.inMilliseconds} ms';
}

final class ApiTransportException implements Exception {
  const ApiTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class ApiProtocolException implements Exception {
  const ApiProtocolException(this.message);
  final String message;
  @override
  String toString() => message;
}
