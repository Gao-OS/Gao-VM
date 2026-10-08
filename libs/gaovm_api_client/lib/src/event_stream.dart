part of '../gaovm_api_client.dart';

Stream<Event> _watchEvents(
  String socketPath,
  Map<String, String> query,
  String? lastEventId,
  int afterSequence,
  Duration timeout,
) {
  late StreamController<Event> output;
  HttpClient? client;
  StreamSubscription<Event>? subscription;
  Timer? deadline;
  var closed = false;

  Future<void> cancel() async {
    closed = true;
    deadline?.cancel();
    client?.close(force: true);
    await subscription?.cancel();
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (closed) return;
    closed = true;
    deadline?.cancel();
    client?.close(force: true);
    final failure = error is SocketException || error is HttpException
        ? ApiTransportException(error.toString())
        : error;
    output.addError(failure, stackTrace);
    unawaited(output.close());
  }

  Future<void> connect() async {
    try {
      final request = await client!.getUrl(
        Uri(
          scheme: 'http',
          host: 'localhost',
          path: '/v1/events',
          queryParameters: query,
        ),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (lastEventId != null)
        request.headers.set('Last-Event-ID', lastEventId);
      final response = await request.close();
      if (closed) return;
      if (response.statusCode >= 400) await _readPublicJson(response);
      if (response.statusCode != HttpStatus.ok ||
          response.headers.contentType?.mimeType != 'text/event-stream') {
        throw const ApiProtocolException('expected an SSE response');
      }
      subscription = _decodeEvents(response, afterSequence).listen(
        (event) {
          if (!closed) output.add(event);
        },
        onError: fail,
        onDone: () => fail(
          const ApiTransportException(
            'event stream closed; resume from the last consumed sequence',
          ),
        ),
        cancelOnError: true,
      );
      if (closed) {
        await subscription!.cancel();
      } else if (output.isPaused) {
        subscription!.pause();
      }
    } catch (error, stackTrace) {
      fail(error, stackTrace);
    }
  }

  output = StreamController<Event>(
    sync: true,
    onListen: () {
      client = _newHttpClient(socketPath, timeout);
      deadline = Timer(timeout, () => fail(ApiTimeoutException(timeout)));
      unawaited(connect());
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: cancel,
  );
  return output.stream;
}

Stream<Event> _decodeEvents(
  Stream<List<int>> source,
  int afterSequence,
) async* {
  final lineBytes = BytesBuilder(copy: false);
  var frameBytes = 0;
  String? id;
  final data = <String>[];
  var previous = afterSequence;
  try {
    await for (final chunk in source) {
      var start = 0;
      while (start < chunk.length) {
        final newline = chunk.indexOf(10, start);
        final end = newline < 0 ? chunk.length : newline + 1;
        frameBytes += end - start;
        if (frameBytes > 1024 * 1024)
          throw const ApiProtocolException('SSE frame exceeds 1 MiB');
        lineBytes.add(chunk.sublist(start, newline < 0 ? end : newline));
        start = end;
        if (newline < 0) continue;
        var line = utf8.decode(lineBytes.takeBytes());
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (line.isEmpty) {
          if (data.isNotEmpty || id != null) {
            final sequence = id == null || !RegExp(r'^[0-9]+$').hasMatch(id)
                ? null
                : int.tryParse(id);
            if (sequence == null)
              throw const ApiProtocolException(
                'SSE event requires a decimal sequence id',
              );
            final event = Event.fromJson(jsonDecode(data.join('\n')));
            if (event.sequence != sequence || sequence <= previous)
              throw const ApiProtocolException(
                'SSE sequence disagrees with its cursor or is not increasing',
              );
            previous = sequence;
            yield event;
          }
          frameBytes = 0;
          id = null;
          data.clear();
        } else if (!line.startsWith(':')) {
          final colon = line.indexOf(':');
          final field = colon < 0 ? line : line.substring(0, colon);
          var value = colon < 0 ? '' : line.substring(colon + 1);
          if (value.startsWith(' ')) value = value.substring(1);
          if (field == 'id') {
            if (id != null)
              throw const ApiProtocolException('duplicate SSE id field');
            id = value;
          } else if (field == 'data') {
            data.add(value);
          }
        }
      }
    }
    if (lineBytes.length != 0 || data.isNotEmpty || id != null)
      throw const ApiProtocolException('truncated SSE frame');
  } on FormatException {
    throw const ApiProtocolException(
      'SSE data does not match the Event contract',
    );
  } on ArgumentError {
    throw const ApiProtocolException(
      'SSE data does not match the Event contract',
    );
  }
}
