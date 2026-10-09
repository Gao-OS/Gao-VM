part of '../gaovm_cli.dart';

Future<ApiArtifactDownload?> _downloadTestArtifact(
  GaoVmApiClient client,
  TestRunId owner,
  ArtifactId id,
  Directory directory,
  Duration timeout,
  ApiRequestCancellation cancellation,
) async {
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final value = timeout - elapsed.elapsed;
    if (value <= Duration.zero) throw ApiTimeoutException(timeout);
    return value;
  }

  // Resolve the explicit caller-owned output location before any HTTP request.
  final parent = Directory(await directory.resolveSymbolicLinks());
  if (!await parent.exists())
    throw FileSystemException('Output directory does not exist.', parent.path);
  final seenCursors = <String>{};
  final seenIds = <ArtifactId>{};
  String? cursor;
  do {
    final response = await client.request(
      'GET',
      '/v1/test-runs/${owner.value}/artifacts',
      query: {'limit': '200', if (cursor != null) 'cursor': cursor},
      timeout: remaining(),
      cancellation: cancellation,
    );
    final page = response.body.toJson();
    final items = page['items'];
    final next = page['next_cursor'];
    if (response.status != HttpStatus.ok ||
        page.length != 2 ||
        !page.containsKey('next_cursor') ||
        items is! List ||
        items.length > 200 ||
        next != null &&
            (next is! String || next.isEmpty || next.length > 512) ||
        response.requestId == null) {
      throw const ApiProtocolException('Invalid Artifact list response.');
    }
    if (next is String && !seenCursors.add(next)) {
      throw const ApiProtocolException('Artifact list repeated its cursor.');
    }
    final List<Artifact> artifacts;
    try {
      RequestId(response.requestId!);
      artifacts = items.map(Artifact.fromJson).toList();
    } on FormatException {
      throw const ApiProtocolException('Invalid Artifact list response.');
    } on ArgumentError {
      throw const ApiProtocolException('Invalid Artifact list response.');
    }
    for (final artifact in artifacts) {
      if (artifact.testRunId != owner ||
          !seenIds.add(artifact.id) ||
          artifact.downloadUrl != '/v1/artifacts/${artifact.id.value}') {
        throw const ApiProtocolException(
          'Artifact list has mismatched or repeated records.',
        );
      }
    }
    for (final artifact in artifacts) {
      if (artifact.id == id) {
        return client.downloadArtifact(
          artifact,
          directory: parent,
          timeout: remaining(),
          cancellation: cancellation,
        );
      }
    }
    cursor = next as String?;
  } while (cursor != null);
  return null;
}
