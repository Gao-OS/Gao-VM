part of '../gaovm_api_client.dart';

/// Complete, verified bytes. A partial or mismatched response is never returned.
final class ApiArtifactResponse {
  ApiArtifactResponse._(this.artifact, this.requestId, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();

  final Artifact artifact;
  final RequestId requestId;
  final Uint8List bytes;
}

/// Local admission failure, not a daemon error or evidence of payload damage.
final class ApiArtifactSizeLimitException implements Exception {
  const ApiArtifactSizeLimitException(this.sizeBytes, this.maxBytes);
  final int sizeBytes;
  final int maxBytes;

  @override
  String toString() =>
      'artifact is $sizeBytes bytes; this read is limited to $maxBytes bytes';
}

Future<ApiArtifactResponse> _readArtifact(
  String socketPath,
  Artifact artifact,
  int maxBytes,
  ApiRequestCancellation? cancellation,
  Duration timeout,
) async {
  _checkArtifactRead(artifact, maxBytes, cancellation, timeout);
  final client = _newHttpClient(socketPath, timeout)..autoUncompress = false;
  final cancelled = cancellation == null
      ? null
      : Completer<ApiArtifactResponse>();
  final unsubscribe = cancellation?._subscribe(() {
    if (!cancelled!.isCompleted) {
      cancelled.completeError(const ApiRequestCancelledException());
    }
    client.close(force: true);
  });
  try {
    final response = _receiveArtifact(
      client,
      artifact,
      maxBytes,
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

void _checkArtifactRead(
  Artifact artifact,
  int maxBytes,
  ApiRequestCancellation? cancellation,
  Duration timeout,
) {
  if (maxBytes <= 0 || timeout <= Duration.zero) {
    throw ArgumentError('a positive byte budget and timeout are required');
  }
  if (cancellation?.isCancelled == true) {
    throw const ApiRequestCancelledException();
  }
  if (artifact.downloadUrl != '/v1/artifacts/${artifact.id.value}') {
    throw const ApiProtocolException(
      'Artifact download URL disagrees with its ID.',
    );
  }
  if (artifact.sizeBytes > maxBytes) {
    throw ApiArtifactSizeLimitException(artifact.sizeBytes, maxBytes);
  }
}

Future<ApiArtifactResponse> _receiveArtifact(
  HttpClient client,
  Artifact artifact,
  int maxBytes,
) async {
  final opened = await _openArtifact(client, artifact);
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in opened.response) {
    if (bytes.length + chunk.length > maxBytes ||
        bytes.length + chunk.length > artifact.sizeBytes) {
      throw const ApiProtocolException(
        'Artifact response exceeds its byte limit.',
      );
    }
    bytes.add(chunk);
  }
  final payload = bytes.takeBytes();
  if (payload.length != artifact.sizeBytes ||
      'sha256:${crypto.sha256.convert(payload)}' != artifact.digest) {
    throw const ApiProtocolException(
      'Artifact payload failed length or SHA-256 verification.',
    );
  }
  return ApiArtifactResponse._(artifact, opened.requestId, payload);
}

Future<({HttpClientResponse response, RequestId requestId})> _openArtifact(
  HttpClient client,
  Artifact artifact,
) async {
  final request = await client.getUrl(
    Uri(scheme: 'http', host: 'localhost', path: artifact.downloadUrl),
  );
  request.followRedirects = false;
  request.headers.set(
    'Accept',
    'application/octet-stream, application/problem+json',
  );
  request.headers.set('Accept-Encoding', 'identity');
  final response = await request.close();
  if (response.statusCode >= 400) {
    await _readPublicJson(response);
  }
  final encoding = response.headers[HttpHeaders.contentEncodingHeader];
  if (response.statusCode != HttpStatus.ok ||
      response.headers.contentType?.mimeType != 'application/octet-stream' ||
      encoding != null &&
          (encoding.length != 1 || encoding.single != 'identity') ||
      response.contentLength != artifact.sizeBytes) {
    throw const ApiProtocolException(
      'Invalid artifact response status, type, encoding, or length.',
    );
  }
  final requestIds = response.headers['x-request-id'];
  if (requestIds == null || requestIds.length != 1) {
    throw const ApiProtocolException('Invalid artifact response request ID.');
  }
  RequestId requestId;
  try {
    requestId = RequestId(requestIds.single);
  } on FormatException {
    throw const ApiProtocolException('Invalid artifact response request ID.');
  }
  final hex = artifact.digest.substring(7);
  final expected = List<int>.generate(
    32,
    (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
  );
  final digests = response.headers['digest'];
  if (digests == null ||
      digests.length != 1 ||
      digests.single != 'sha-256=${base64.encode(expected)}') {
    throw const ApiProtocolException(
      'Artifact response digest disagrees with its metadata.',
    );
  }
  return (response: response, requestId: requestId);
}
