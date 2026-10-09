part of 'main.dart';

class _ArtifactDownload extends StatefulWidget {
  const _ArtifactDownload({
    super.key,
    required this.client,
    required this.artifact,
  });
  final GaoVmApiClient client;
  final Artifact artifact;

  @override
  State<_ArtifactDownload> createState() => _ArtifactDownloadState();
}

class _ArtifactDownloadState extends State<_ArtifactDownload> {
  static const _byteLimit = 256 * 1024 * 1024;
  ApiRequestCancellation? _pending;
  ApiArtifactDownload? _receipt;
  Object? _error;
  bool _busy = false;
  bool _transferring = false;
  bool _cancelled = false;

  Future<void> _download() async {
    if (_busy || widget.artifact.sizeBytes > _byteLimit) return;
    final pending = _pending = ApiRequestCancellation();
    setState(() {
      _busy = true;
      _error = null;
      _cancelled = false;
    });
    try {
      final path = await getDirectoryPath(
        confirmButtonText: 'Download here',
        canCreateDirectories: false,
      );
      if (!mounted || pending.isCancelled || path == null) return;
      if (!path.startsWith('/') || path.contains('\u0000')) {
        throw FileSystemException(
          'Choose an existing absolute directory.',
          path,
        );
      }
      setState(() => _transferring = true);
      final receipt = await widget.client.downloadArtifact(
        widget.artifact,
        directory: Directory(path),
        maxBytes: _byteLimit,
        cancellation: pending,
      );
      if (mounted && identical(_pending, pending)) {
        setState(() => _receipt = receipt);
      }
    } on ApiRequestCancelledException {
      // The SDK finishes partial-file cleanup before returning cancellation.
      if (mounted && identical(_pending, pending)) {
        setState(() => _cancelled = true);
      }
    } catch (error) {
      if (mounted && identical(_pending, pending)) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && identical(_pending, pending)) {
        setState(() {
          _busy = false;
          _transferring = false;
          _pending = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: _busy || widget.artifact.sizeBytes > _byteLimit
            ? null
            : _download,
        child: const Text('Download artifact'),
      ),
      const Text(
        'Choose a directory · streamed to a private child · no overwrites.',
        style: TextStyle(fontSize: 10, color: _muted),
      ),
      if (widget.artifact.sizeBytes > _byteLimit)
        const Text('Payload exceeds the 256 MiB download limit.'),
      if (_busy) ...[
        const LinearProgressIndicator(minHeight: 2),
        Text(
          !_transferring
              ? 'Choosing a download directory…'
              : _pending!.isCancelled
              ? 'Cancelling download…'
              : 'Downloading · awaiting complete verification…',
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
        if (_transferring)
          TextButton(
            onPressed: _pending!.isCancelled
                ? null
                : () => setState(() => _pending?.cancel()),
            child: const Text('Cancel download'),
          ),
      ],
      if (_cancelled)
        const Text('Download cancelled · partial output removed.'),
      if (_error != null) ...[
        _apiFailure(_error!),
        if (_receipt != null)
          const Text('Download failed · last verified file retained.'),
      ],
      if (_receipt case final receipt?) ...[
        const SizedBox(height: 12),
        Text('Verified download · ${receipt.artifact.sizeBytes} bytes'),
        SelectableText(receipt.file.path, style: const TextStyle(fontSize: 11)),
        Text(
          'Download request · ${receipt.requestId.value}',
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
        const Text(
          'Length and SHA-256 verified · local file is yours · contents are inert.',
          style: TextStyle(fontSize: 10, color: _muted),
        ),
      ],
      const SizedBox(height: 12),
    ],
  );
}
