part of 'main.dart';

class _TestRuns extends StatefulWidget {
  const _TestRuns({super.key, required this.client});
  final GaoVmApiClient client;

  @override
  State<_TestRuns> createState() => _TestRunsState();
}

class _TestRunsState extends State<_TestRuns> {
  static const _previewByteLimit = 64 * 1024;
  final _id = TextEditingController();
  TestRunId? _target;
  TestRun? _run;
  RequestId? _responseId;
  ApiRequestCancellation? _request;
  bool _reading = false;
  Object? _error;
  Object? _inputError;
  final _seenCursors = <String>{};
  List<Artifact> _artifacts = [];
  Artifact? _artifact;
  String? _nextCursor;
  ApiRequestCancellation? _artifactRequest;
  bool _loadingArtifacts = false;
  bool _artifactsLoaded = false;
  Object? _artifactError;
  ApiArtifactResponse? _payload;
  String? _payloadText;
  ApiRequestCancellation? _payloadRequest;
  bool _readingPayload = false;
  Object? _payloadError;

  void _clearPayload() {
    _payloadRequest?.cancel();
    _payloadRequest = null;
    _payload = null;
    _payloadText = null;
    _payloadError = null;
    _readingPayload = false;
  }

  void _selectArtifact(Artifact artifact) {
    if (_artifact == artifact) {
      return;
    }
    setState(() {
      _clearPayload();
      _artifact = artifact;
    });
  }

  Future<void> _readPayload() async {
    final artifact = _artifact;
    if (artifact == null ||
        _readingPayload ||
        artifact.sizeBytes > _previewByteLimit) {
      return;
    }
    _payloadRequest?.cancel();
    final pending = _payloadRequest = ApiRequestCancellation();
    setState(() {
      _readingPayload = true;
      _payloadError = null;
    });
    try {
      final payload = await widget.client.readArtifact(
        artifact,
        maxBytes: _previewByteLimit,
        cancellation: pending,
      );
      final text = _previewText(payload);
      if (mounted &&
          !pending.isCancelled &&
          identical(_payloadRequest, pending) &&
          _artifact == artifact) {
        setState(() {
          _payload = payload;
          _payloadText = text;
        });
      }
    } on ApiRequestCancelledException {
      // Release only this payload read, never its TestRun or VM.
    } catch (error) {
      if (mounted &&
          !pending.isCancelled &&
          identical(_payloadRequest, pending)) {
        setState(() => _payloadError = error);
      }
    } finally {
      if (mounted &&
          !pending.isCancelled &&
          identical(_payloadRequest, pending)) {
        setState(() => _readingPayload = false);
      }
    }
  }

  String? _previewText(ApiArtifactResponse payload) {
    try {
      final type = ContentType.parse(payload.artifact.contentType);
      final mime = type.mimeType.toLowerCase();
      if (!mime.startsWith('text/') &&
          mime != 'application/json' &&
          mime != 'application/xml' &&
          !mime.endsWith('+json') &&
          !mime.endsWith('+xml')) {
        return null;
      }
      final charset = type.charset?.toLowerCase();
      if (charset == 'us-ascii') {
        return ascii.decode(payload.bytes);
      }
      if (charset != null && charset != 'utf-8' && charset != 'utf8') {
        return null;
      }
      return utf8.decode(payload.bytes);
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  String _previewHex(List<int> bytes) {
    final lines = <String>[];
    for (var offset = 0; offset < bytes.length && offset < 256; offset += 16) {
      final end = offset + 16 < bytes.length ? offset + 16 : bytes.length;
      final hex = bytes
          .sublist(offset, end)
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      lines.add('${offset.toRadixString(16).padLeft(6, '0')}  $hex');
    }
    return lines.join('\n');
  }

  Widget _payloadView(Artifact artifact) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      TextButton(
        onPressed: _readingPayload || artifact.sizeBytes > _previewByteLimit
            ? null
            : _readPayload,
        child: const Text('Read artifact bytes'),
      ),
      if (artifact.sizeBytes > _previewByteLimit)
        const Text(
          'Payload exceeds the 64 KiB preview limit.',
          style: TextStyle(fontSize: 11, color: _muted),
        ),
      if (_readingPayload) const LinearProgressIndicator(minHeight: 2),
      if (_payloadError != null) ...[
        _apiFailure(_payloadError!),
        if (_payload != null)
          const Text(
            'Payload read failed · last verified bytes retained.',
            style: TextStyle(fontSize: 11),
          ),
      ],
      if (_payload case final payload?) ...[
        const SizedBox(height: 12),
        Text('Verified payload · ${payload.bytes.length} bytes'),
        Text(
          'Payload request · ${payload.requestId.value}',
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
        const Text(
          'Complete length and SHA-256 verified · contents are inert.',
          style: TextStyle(fontSize: 10, color: _muted),
        ),
        const SizedBox(height: 12),
        if (payload.bytes.isEmpty)
          const Text('Empty artifact')
        else if (_payloadText != null)
          SelectableText(_payloadText!, style: const TextStyle(fontSize: 11))
        else ...[
          Text(
            'Binary preview · ${payload.bytes.length < 256 ? payload.bytes.length : 256} of ${payload.bytes.length} verified bytes',
          ),
          SelectableText(
            _previewHex(payload.bytes),
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ],
      const SizedBox(height: 12),
    ],
  );

  void _lookup() {
    try {
      final target = TestRunId(_id.text.trim());
      setState(() => _inputError = null);
      _observe(target);
    } on FormatException catch (error) {
      setState(() => _inputError = error);
    }
  }

  Future<void> _observe(TestRunId target) async {
    final previous = _run?.id == target ? _run : null;
    _request?.cancel();
    final pending = _request = ApiRequestCancellation();
    setState(() {
      _target = target;
      _reading = true;
      _error = null;
      if (previous == null) {
        _run = null;
        _responseId = null;
        _artifactRequest?.cancel();
        _clearPayload();
        _artifacts = [];
        _artifact = null;
        _nextCursor = null;
        _seenCursors.clear();
        _artifactsLoaded = false;
        _loadingArtifacts = false;
        _artifactError = null;
      }
    });
    try {
      final response = await widget.client.request(
        'GET',
        '/v1/test-runs/${target.value}',
        cancellation: pending,
      );
      final run = TestRun.fromJson(response.body.toJson());
      if (response.status != 200 ||
          response.requestId == null ||
          run.id != target ||
          previous != null &&
              (run.spec != previous.spec ||
                  run.operationId != previous.operationId ||
                  run.createdAt != previous.createdAt ||
                  previous.vmId != null && run.vmId != previous.vmId)) {
        throw const ApiProtocolException(
          'Invalid TestRun identity or immutable input.',
        );
      }
      final requestId = RequestId(response.requestId!);
      if (mounted && !pending.isCancelled && identical(_request, pending)) {
        setState(() {
          _run = run;
          _responseId = requestId;
        });
      }
    } on ApiRequestCancelledException {
      // Release only this observation, not the TestRun or its durable work.
    } catch (error) {
      if (mounted && !pending.isCancelled && identical(_request, pending)) {
        setState(
          () => _error = error is FormatException || error is ArgumentError
              ? const ApiProtocolException('Invalid TestRun response.')
              : error,
        );
      }
    } finally {
      if (mounted && !pending.isCancelled && identical(_request, pending)) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _loadArtifacts({bool more = false}) async {
    final target = _run?.id;
    if (target == null || _loadingArtifacts || more && _nextCursor == null) {
      return;
    }
    final cursor = more ? _nextCursor : null;
    _artifactRequest?.cancel();
    final pending = _artifactRequest = ApiRequestCancellation();
    setState(() {
      _loadingArtifacts = true;
      _artifactError = null;
    });
    try {
      final response = await widget.client.request(
        'GET',
        '/v1/test-runs/${target.value}/artifacts',
        query: {'cursor': ?cursor},
        cancellation: pending,
      );
      final page = response.body.toJson();
      final items = page['items'];
      final next = page['next_cursor'];
      if (response.status != 200 ||
          response.requestId == null ||
          page.length != 2 ||
          !page.containsKey('next_cursor') ||
          items is! List ||
          next != null &&
              (next is! String || next.isEmpty || next.length > 512)) {
        throw const ApiProtocolException('Invalid TestRun artifact page.');
      }
      RequestId(response.requestId!);
      if (next is String &&
          (next == cursor || more && _seenCursors.contains(next))) {
        throw const ApiProtocolException(
          'TestRun artifacts repeated a cursor.',
        );
      }
      final artifacts = [
        if (more) ..._artifacts,
        ...items.map(Artifact.fromJson),
      ];
      if (artifacts.map((value) => value.id).toSet().length !=
              artifacts.length ||
          artifacts.any(
            (value) =>
                value.testRunId != target ||
                value.downloadUrl != '/v1/artifacts/${value.id.value}',
          )) {
        throw const ApiProtocolException(
          'Invalid TestRun artifact association or identity.',
        );
      }
      if (mounted &&
          !pending.isCancelled &&
          identical(_artifactRequest, pending) &&
          _run?.id == target) {
        setState(() {
          _artifacts = artifacts;
          _nextCursor = next as String?;
          _artifactsLoaded = true;
          if (!more) {
            _clearPayload();
            _seenCursors.clear();
            _artifact = null;
          }
          if (cursor != null) _seenCursors.add(cursor);
        });
      }
    } on ApiRequestCancelledException {
      // Only this catalog read is released; artifacts remain owned by the daemon.
    } catch (error) {
      if (mounted &&
          !pending.isCancelled &&
          identical(_artifactRequest, pending)) {
        setState(
          () => _artifactError =
              error is FormatException || error is ArgumentError
              ? const ApiProtocolException('Invalid TestRun artifact record.')
              : error,
        );
      }
    } finally {
      if (mounted &&
          !pending.isCancelled &&
          identical(_artifactRequest, pending)) {
        setState(() => _loadingArtifacts = false);
      }
    }
  }

  Widget _artifactDetail(Artifact artifact) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      const Text(
        'ARTIFACT SNAPSHOT',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 12),
      Text(
        artifact.toJson()['kind']! as String,
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
      ),
      _payloadView(artifact),
      for (final entry in {
        'ID': artifact.id.value,
        'Content type': artifact.contentType,
        'Size': '${artifact.sizeBytes} bytes',
        'Declared SHA-256': artifact.digest,
        'Download URL': artifact.downloadUrl,
        'VM': artifact.vmId?.value ?? 'Not associated',
        'Operation': artifact.operationId?.value ?? 'Not associated',
        'TestRun': artifact.testRunId?.value ?? 'Not associated',
        'Created': artifact.createdAt.toIso8601String(),
        'Retention until':
            artifact.retentionUntil?.toIso8601String() ?? 'Not provided',
      }.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
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
      Text(
        _payload == null
            ? 'Declared metadata, not a downloaded or verified payload.'
            : 'Metadata snapshot · verification belongs to the last explicit payload read.',
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      _json('Full artifact JSON', artifact.toJson()),
    ],
  );

  Widget _artifactPanel() => SingleChildScrollView(
    key: const Key('test-run-artifact-scroll'),
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SAVED EVIDENCE',
          style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _run == null || _loadingArtifacts ? null : _loadArtifacts,
          child: const Text('Load TestRun artifacts'),
        ),
        if (_loadingArtifacts) const LinearProgressIndicator(minHeight: 2),
        if (_artifactError != null) ...[
          _apiFailure(_artifactError!),
          if (_artifactsLoaded)
            const Text(
              'Artifact read failed · last validated page retained.',
              style: TextStyle(fontSize: 11),
            ),
        ],
        if (!_artifactsLoaded)
          const Text(
            'Load the artifact catalog explicitly. TestRun state does not prove payload availability.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
        if (_artifactsLoaded && _artifacts.isEmpty)
          const Text('No TestRun artifacts'),
        for (final artifact in _artifacts)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: InkWell(
              key: ValueKey('artifact-${artifact.id.value}'),
              onTap: () => _selectArtifact(artifact),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _artifact?.id == artifact.id
                      ? const Color(0xffeef5df)
                      : _paper,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${artifact.toJson()['kind']} · ${artifact.sizeBytes} bytes',
                    ),
                    Text(
                      artifact.id.value,
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_nextCursor != null)
          TextButton(
            onPressed: _loadingArtifacts
                ? null
                : () => _loadArtifacts(more: true),
            child: const Text('Load more artifacts'),
          ),
        if (_artifact != null) _artifactDetail(_artifact!),
      ],
    ),
  );

  Widget _json(String title, Map<String, Object?> value) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 11)),
    children: [
      SelectableText(
        const JsonEncoder.withIndent('  ').convert(value),
        style: const TextStyle(fontSize: 11),
      ),
    ],
  );

  Widget _detail(TestRun run) => SingleChildScrollView(
    key: const Key('test-run-detail-scroll'),
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DURABLE TEST RUN',
          style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
        ),
        const SizedBox(height: 12),
        Text(
          'TestRun · ${run.toJson()['state']}',
          style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 34),
        ),
        SelectableText(run.id.value, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 16),
        const Text(
          'Public resource snapshot · A retained VM reference is not its current runtime state.',
          style: TextStyle(fontSize: 11, color: _muted),
        ),
        const SizedBox(height: 16),
        SelectableText('VM · ${run.vmId?.value ?? 'Not allocated'}'),
        SelectableText('Operation · ${run.operationId.value}'),
        SelectableText(
          'Read request · ${_responseId!.value}',
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 12),
        Text('Cleanup requested · ${run.spec.toJson()['cleanup']}'),
        Text('Cleanup decision · ${run.cleanupDecision ?? 'Not recorded'}'),
        Text('Retain on failure · ${run.spec.retainOnFailure}'),
        Text(
          'Created · ${run.createdAt.toIso8601String()}',
          style: const TextStyle(fontSize: 11),
        ),
        Text(
          'Completed · ${run.completedAt?.toIso8601String() ?? 'Not completed'}',
          style: const TextStyle(fontSize: 11),
        ),
        if (run.error case final error?) ...[
          const SizedBox(height: 16),
          Text(error.toJson()['code']! as String),
          Text(error.message),
          Text(error.retryable ? 'Retryable' : 'Not retryable'),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(error.details.toJson()),
            style: const TextStyle(fontSize: 11),
          ),
        ],
        if (run.result != null) ...[
          const SizedBox(height: 12),
          const Text('TestRun result'),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(run.result!.toJson()),
            style: const TextStyle(fontSize: 11),
          ),
        ],
        const SizedBox(height: 20),
        TextButton(
          onPressed: _reading ? null : () => _observe(run.id),
          child: const Text('Refresh TestRun'),
        ),
        const SizedBox(height: 12),
        const Text(
          'ORDERED STEPS',
          style: TextStyle(fontSize: 11, letterSpacing: 1.4, color: _muted),
        ),
        if (run.steps.isEmpty) const Text('No step results recorded'),
        for (final step in run.steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${step.index + 1} / ${step.request.name ?? 'guest.exec'} · ${step.state.name}',
                ),
                SelectableText(
                  jsonEncode(step.request.argv),
                  style: const TextStyle(fontSize: 11),
                ),
                if (step.result != null)
                  SelectableText(
                    const JsonEncoder.withIndent('  ')
                        .convert(step.result!.toJson()),
                    style: const TextStyle(fontSize: 11),
                  ),
                if (step.error != null) ...[
                  Text(step.error!.toJson()['code']! as String),
                  Text(step.error!.message),
                ],
                _json('Step request and result JSON', step.toJson()),
              ],
            ),
          ),
        _json('Immutable TestRun specification', run.spec.toJson()),
        _json('Full TestRun JSON', run.toJson()),
      ],
    ),
  );

  Widget _panel(Widget child) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _line),
      borderRadius: BorderRadius.circular(10),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  @override
  void dispose() {
    _request?.cancel();
    _artifactRequest?.cancel();
    _payloadRequest?.cancel();
    _id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('test-run-id'),
              controller: _id,
              decoration: const InputDecoration(
                labelText: 'TestRun ID',
                hintText: 'tr_<ULID>',
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 16),
          FilledButton(
            onPressed: _lookup,
            child: const Text('Observe TestRun'),
          ),
        ],
      ),
      if (_reading)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (_inputError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _apiFailure(_inputError!),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _apiFailure(_error!),
              if (_run != null)
                const Text(
                  'TestRun read failed · last validated snapshot retained.',
                  style: TextStyle(fontSize: 11),
                ),
              TextButton(
                onPressed: _reading || _target == null
                    ? null
                    : () => _observe(_target!),
                child: const Text('Retry TestRun read'),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 6,
              child: _panel(
                _run == null
                    ? const Center(child: Text('Enter a TestRun ID'))
                    : _detail(_run!),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(flex: 5, child: _panel(_artifactPanel())),
          ],
        ),
      ),
    ],
  );
}
