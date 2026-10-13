part of '../gaovm_api_client.dart';

/// A complete verified download, not a stream of unverified payload chunks.
final class ApiArtifactDownload {
  const ApiArtifactDownload._(this.artifact, this.requestId, this.file);
  final Artifact artifact;
  final RequestId requestId;
  final File file;
}

final _artifactLibc = DynamicLibrary.process();
final _artifactMkdtemp = _artifactLibc
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)
    >('mkdtemp');
final _artifactChmod = _artifactLibc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');

Directory _createPrivateArtifactStage(Directory parent) {
  // Dart's Linux createTemp uses 0777 minus umask; mkdtemp is private at creation.
  final template =
      '${parent.path}${Platform.pathSeparator}gaovm-artifact-XXXXXX'
          .toNativeUtf8();
  try {
    if (_artifactMkdtemp(template) == nullptr) {
      throw FileSystemException(
        'cannot create private artifact staging directory',
        parent.path,
      );
    }
    return Directory(template.toDartString());
  } finally {
    malloc.free(template);
  }
}

void _setArtifactStageMode(Directory stage) {
  final path = stage.path.toNativeUtf8();
  try {
    // Restore owner bits if umask removed them, without exposing group/other bits.
    if (_artifactChmod(path, 0x1c0) != 0) {
      throw FileSystemException(
        'cannot set artifact staging permissions',
        stage.path,
      );
    }
  } finally {
    malloc.free(path);
  }
}

Future<ApiArtifactDownload> _downloadArtifact(
  String socketPath,
  Artifact artifact,
  Directory directory,
  int maxBytes,
  ApiRequestCancellation? cancellation,
  Duration timeout,
) async {
  _checkArtifactRead(artifact, maxBytes, cancellation, timeout);
  final client = _newHttpClient(socketPath, timeout)..autoUncompress = false;
  Object? stopped;
  void stop(Object reason) {
    stopped ??= reason;
    client.close(force: true);
  }

  void check() {
    if (stopped case final reason?) throw reason;
  }

  final timer = Timer(timeout, () => stop(ApiTimeoutException(timeout)));
  final unsubscribe = cancellation?._subscribe(
    () => stop(const ApiRequestCancelledException()),
  );
  Directory? stage;
  RandomAccessFile? file;
  var complete = false;
  try {
    final parent = Directory(await directory.resolveSymbolicLinks());
    check();
    stage = _createPrivateArtifactStage(parent);
    _setArtifactStageMode(stage);
    check();
    final partial = File('${stage.path}${Platform.pathSeparator}payload.part');
    file = await partial.open(mode: FileMode.write);
    check();
    final opened = await _openArtifact(client, artifact);
    check();
    var size = 0;
    final digest = await crypto.sha256
        .bind(
          opened.response.asyncMap((chunk) async {
            check();
            size += chunk.length;
            if (size > maxBytes || size > artifact.sizeBytes) {
              throw const ApiProtocolException(
                'Artifact response exceeds its byte limit.',
              );
            }
            await file!.writeFrom(chunk);
            check();
            return chunk;
          }),
        )
        .single;
    check();
    if (size != artifact.sizeBytes || 'sha256:$digest' != artifact.digest) {
      throw const ApiProtocolException(
        'Artifact payload failed length or SHA-256 verification.',
      );
    }
    await file.flush();
    check();
    final closing = file;
    file = null;
    await closing.close();
    check();
    final published = await partial.rename(
      '${stage.path}${Platform.pathSeparator}${artifact.id.value}',
    );
    check();
    complete = true;
    return ApiArtifactDownload._(artifact, opened.requestId, published);
  } catch (error, stack) {
    if (stopped case final reason?) Error.throwWithStackTrace(reason, stack);
    if (error is SocketException || error is HttpException) {
      throw ApiTransportException(error.toString());
    }
    rethrow;
  } finally {
    timer.cancel();
    unsubscribe?.call();
    client.close(force: true);
    try {
      await file?.close();
    } finally {
      if (!complete && stage != null) await stage.delete(recursive: true);
    }
  }
}
