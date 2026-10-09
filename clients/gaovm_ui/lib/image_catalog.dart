part of 'main.dart';

class _ImageCatalog extends StatefulWidget {
  const _ImageCatalog({super.key, required this.client});
  final GaoVmApiClient client;

  @override
  State<_ImageCatalog> createState() => _ImageCatalogState();
}

class _ImageCatalogState extends State<_ImageCatalog> {
  List<Image> _images = [];
  ApiRequestCancellation? _request;
  bool _loading = false;
  Object? _error;
  Image? _selected;
  String? _nextCursor;
  final _seenCursors = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _nextCursor == null)) return;
    final cursor = more ? _nextCursor : null;
    _request?.cancel();
    final pending = _request = ApiRequestCancellation();
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _images = [];
        _selected = null;
        _nextCursor = null;
        _seenCursors.clear();
      }
    });
    try {
      final response = await widget.client.request(
        'GET',
        '/v1/images',
        cancellation: pending,
        query: {'cursor': ?cursor},
      );
      final page = response.body.toJson();
      final items = page['items'];
      final next = page['next_cursor'];
      if (response.status != 200 ||
          page.length != 2 ||
          !page.containsKey('next_cursor') ||
          items is! List ||
          next != null &&
              (next is! String || next.isEmpty || next.length > 512)) {
        throw const ApiProtocolException('Invalid image catalog response.');
      }
      final List<Image> images;
      try {
        images = [if (more) ..._images, ...items.map(Image.fromJson)];
      } on FormatException {
        throw const ApiProtocolException('Invalid image record.');
      } on ArgumentError {
        throw const ApiProtocolException('Invalid image record.');
      }
      if (next is String && (next == cursor || _seenCursors.contains(next))) {
        throw const ApiProtocolException('Image catalog repeated its cursor.');
      }
      if (images.map((image) => image.id).toSet().length != images.length) {
        throw const ApiProtocolException(
          'Image catalog repeated a resource ID.',
        );
      }
      if (mounted && !pending.isCancelled) {
        setState(() {
          _images = images;
          _nextCursor = next as String?;
          if (cursor != null) _seenCursors.add(cursor);
        });
      }
    } on ApiRequestCancelledException {
      // Release only this local read; images and VM state belong to the daemon.
    } catch (error) {
      if (mounted && !pending.isCancelled) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && !pending.isCancelled) {
        setState(() => _loading = false);
      }
    }
  }

  Widget _row(Image image) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: _selected?.id == image.id ? const Color(0xffeef5df) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _selected = image),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                image.toJson()['type']! as String,
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 8),
              Text(image.id.value, style: const TextStyle(fontSize: 11)),
              const SizedBox(height: 12),
              Text(
                '${image.version ?? 'No version'} · ${image.channel ?? 'No channel'}',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              for (final label in image.labels.entries)
                Text(
                  '${label.key} = ${label.value}',
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _detail(Image image) => ListView(
    key: const ValueKey('image-detail-scroll'),
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'IMAGE MANIFEST',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 12),
      Text(
        image.toJson()['type']! as String,
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 34),
      ),
      const SizedBox(height: 8),
      SelectableText(image.id.value, style: const TextStyle(fontSize: 11)),
      const SizedBox(height: 20),
      const Text(
        'Catalog snapshot · The daemon owns image integrity and availability.',
        style: TextStyle(fontSize: 11, color: _muted),
      ),
      for (final entry in {
        'Digest': image.digest,
        'Architecture': image.toJson()['architecture']! as String,
        'Guest profile': image.guestProfile ?? 'Not provided',
        'Version': image.version ?? 'Not provided',
        'Build ID': image.buildId ?? 'Not provided',
        'Channel': image.channel ?? 'Not provided',
        'Created at': image.createdAt.toIso8601String(),
      }.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.key,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              SelectableText(entry.value, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      const SizedBox(height: 12),
      const Text('Labels', style: TextStyle(fontSize: 11, color: _muted)),
      if (image.labels.isEmpty) const Text('No labels'),
      for (final label in image.labels.entries)
        SelectableText(
          '${label.key} = ${label.value}',
          style: const TextStyle(fontSize: 11),
        ),
      const SizedBox(height: 20),
      const Text(
        'Immutable manifest',
        style: TextStyle(fontSize: 11, color: _muted),
      ),
      const SizedBox(height: 8),
      SelectableText(
        const JsonEncoder.withIndent('  ').convert(image.manifest.toJson()),
        style: const TextStyle(fontSize: 11),
      ),
    ],
  );

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: _loading ? null : () => _load(),
            child: const Text('Reload images'),
          ),
          Text(
            '${_images.length} images · catalog snapshot',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (_nextCursor != null)
            TextButton(
              onPressed: _loading ? null : () => _load(more: true),
              child: const Text('Load more'),
            ),
        ],
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (_error != null) _apiFailure(_error!),
      const SizedBox(height: 16),
      Expanded(
        child: Row(
          children: [
            Expanded(
              flex: 6,
              child: _images.isEmpty
                  ? Center(
                      child: Text(
                        _loading
                            ? 'Reading image catalog…'
                            : _error == null
                            ? 'No images'
                            : 'Image catalog read failed',
                      ),
                    )
                  : ListView(
                      children: [for (final image in _images) _row(image)],
                    ),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 5,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  side: const BorderSide(color: _line),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: _selected == null
                    ? const Center(
                        child: Text(
                          'Select an image',
                          style: TextStyle(
                            fontFamily: 'InstrumentSerif',
                            fontSize: 30,
                          ),
                        ),
                      )
                    : _detail(_selected!),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
