part of '../gaovm_cli.dart';

({List<Artifact> items, String? nextCursor}) _decodeArtifactPage(
  ApiResponse response,
  ResourceId owner, {
  int limit = 200,
}) {
  final page = response.body.toJson();
  final items = page['items'];
  final next = page['next_cursor'];
  if (response.status != HttpStatus.ok ||
      page.length != 2 ||
      !page.containsKey('next_cursor') ||
      items is! List ||
      items.length > limit ||
      next != null && (next is! String || next.isEmpty || next.length > 512) ||
      response.requestId == null) {
    throw const ApiProtocolException('Invalid Artifact list response.');
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
  final seenIds = <ArtifactId>{};
  for (final artifact in artifacts) {
    final owned = switch (owner) {
      VmId() => artifact.vmId == owner,
      TestRunId() => artifact.testRunId == owner,
      _ => false,
    };
    if (!owned ||
        !seenIds.add(artifact.id) ||
        artifact.downloadUrl != '/v1/artifacts/${artifact.id.value}') {
      throw const ApiProtocolException(
        'Artifact list has mismatched or repeated records.',
      );
    }
  }
  return (items: artifacts, nextCursor: next as String?);
}

Future<ApiArtifactDownload?> _downloadOwnedArtifact(
  GaoVmApiClient client,
  ResourceId owner,
  ArtifactId id,
  Directory directory,
  Duration timeout,
  ApiRequestCancellation cancellation,
) async {
  final listPath = switch (owner) {
    VmId() => '/v1/vms/${owner.value}/artifacts',
    TestRunId() => '/v1/test-runs/${owner.value}/artifacts',
    _ => throw ArgumentError('artifact owner must be a VM or TestRun'),
  };
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
      listPath,
      query: {'limit': '200', if (cursor != null) 'cursor': cursor},
      timeout: remaining(),
      cancellation: cancellation,
    );
    final page = _decodeArtifactPage(response, owner);
    final next = page.nextCursor;
    if (next != null && !seenCursors.add(next)) {
      throw const ApiProtocolException('Artifact list repeated its cursor.');
    }
    for (final artifact in page.items) {
      if (!seenIds.add(artifact.id)) {
        throw const ApiProtocolException(
          'Artifact list has mismatched or repeated records.',
        );
      }
    }
    for (final artifact in page.items) {
      if (artifact.id == id) {
        return client.downloadArtifact(
          artifact,
          directory: parent,
          timeout: remaining(),
          cancellation: cancellation,
        );
      }
    }
    cursor = next;
  } while (cursor != null);
  return null;
}
