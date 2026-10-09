part of 'main.dart';

class _OperationHistory extends StatefulWidget {
  const _OperationHistory({
    super.key,
    required this.client,
    required this.cancellations,
  });

  final GaoVmApiClient client;
  final _OperationCancellations cancellations;

  @override
  State<_OperationHistory> createState() => _OperationHistoryState();
}

class _OperationHistoryState extends State<_OperationHistory> {
  ApiRequestCancellation? _catalogRequest;
  List<Operation> _operations = [];
  String? _nextCursor;
  final _seenCursors = <String>{};
  bool _loading = false;
  Object? _error;
  Operation? _selection;
  Operation? _detail;
  Object? _detailError;
  ApiRequestCancellation? _detailRequest;

  @override
  void initState() {
    super.initState();
    widget.cancellations.addListener(_cancellationChanged);
    _load();
  }

  void _cancellationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshCancellation(_OperationCancellation intent) async {
    final terminal = await widget.cancellations.observe(intent);
    if (terminal &&
        mounted &&
        _selection?.id == intent.target &&
        identical(
          widget.cancellations.get(widget.client, intent.target),
          intent,
        )) {
      await _select(_selection!);
    }
  }

  Future<void> _requestCancellation(Operation target) async {
    final intent = widget.cancellations.get(widget.client, target.id);
    if (intent?.sending == true ||
        intent?.operationId != null && !intent!.terminal) {
      return;
    }
    if (intent == null || intent.terminal) {
      if (!target.cancellable ||
          !const {
            OperationState.pending,
            OperationState.running,
          }.contains(target.state)) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          backgroundColor: _paper,
          title: const Text(
            'Cancel this Operation?',
            style: TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(target.type),
              SelectableText(
                target.id.value,
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 12),
              SelectableText(
                target.resourceId.value,
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 20),
              const Text(
                'Request cancellation through the daemon. Acceptance is not completed cleanup; the target Operation reports its outcome.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep running'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Cancel Operation'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || !identical(_detail, target)) return;
    }
    await widget.cancellations.request(widget.client, target);
  }

  Widget _cancellationView(Operation target) {
    final intent = widget.cancellations.get(widget.client, target.id);
    final eligible =
        target.cancellable &&
        const {
          OperationState.pending,
          OperationState.running,
        }.contains(target.state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed:
              intent?.sending == true ||
                  intent?.operationId != null && !intent!.terminal ||
                  !eligible && intent?.error == null
              ? null
              : () => _requestCancellation(target),
          child: Text(
            intent?.error != null
                ? 'Retry cancellation'
                : intent?.terminal == true
                ? 'Request cancellation again'
                : 'Request cancellation',
          ),
        ),
        if (intent?.sending == true) const Text('Submitting cancellation…'),
        if (intent?.operationId != null) ...[
          Text('Cancellation accepted · ${intent!.acceptedState!.name}'),
          SelectableText(
            intent.operationId!.value,
            style: const TextStyle(fontSize: 11),
          ),
          TextButton(
            onPressed: intent.reading
                ? null
                : () => _refreshCancellation(intent),
            child: const Text('Refresh cancellation'),
          ),
          if (intent.reading) const Text('Reading cancellation…'),
          if (intent.operation != null) ...[
            Text('Cancellation · ${intent.operation!.state.name}'),
            if (intent.operation!.progress.step != null)
              Text(intent.operation!.progress.step!),
            if (intent.operation!.progress.percent != null)
              Text('${intent.operation!.progress.percent}%'),
            SelectableText(
              intent.operation!.requestId.value,
              style: const TextStyle(fontSize: 11),
            ),
            if (intent.operation!.error != null) ...[
              Text(intent.operation!.error!.toJson()['code']! as String),
              Text(intent.operation!.error!.message),
              Text(
                intent.operation!.error!.retryable
                    ? 'Retryable'
                    : 'Not retryable',
              ),
            ],
            if (intent.operation!.result != null)
              SelectableText(
                const JsonEncoder.withIndent('  ')
                    .convert(intent.operation!.result!.toJson()),
                style: const TextStyle(fontSize: 11),
              ),
          ],
          if (intent.observationError != null)
            _apiFailure(intent.observationError!),
        ],
        if (intent?.error != null) ...[
          if (intent!.error is! ApiProblemException)
            const Text('Cancellation outcome unknown'),
          const Text(
            'Retry sends the same target, body, and idempotency key.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
          _apiFailure(intent.error!),
        ],
      ],
    );
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _nextCursor == null)) return;
    final cursor = more ? _nextCursor : null;
    _catalogRequest?.cancel();
    final pending = _catalogRequest = ApiRequestCancellation();
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _operations = [];
        _nextCursor = null;
        _seenCursors.clear();
        _detailRequest?.cancel();
        _selection = null;
        _detail = null;
        _detailError = null;
      }
    });
    try {
      final response = await widget.client.request(
        'GET',
        '/v1/operations',
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
        throw const ApiProtocolException('Invalid Operation history response.');
      }
      if (next is String && (next == cursor || _seenCursors.contains(next))) {
        throw const ApiProtocolException(
          'Operation history repeated its cursor.',
        );
      }
      final operations = [
        if (more) ..._operations,
        ...items.map(Operation.fromJson),
      ];
      if (operations.map((operation) => operation.id).toSet().length !=
          operations.length) {
        throw const ApiProtocolException(
          'Operation history repeated a resource ID.',
        );
      }
      if (mounted && !pending.isCancelled) {
        setState(() {
          _operations = operations;
          _nextCursor = next as String?;
          if (cursor != null) _seenCursors.add(cursor);
        });
      }
    } on ApiRequestCancelledException {
      // This releases a local read, not a durable Operation.
    } catch (error) {
      if (mounted && !pending.isCancelled) setState(() => _error = error);
    } finally {
      if (mounted && !pending.isCancelled) setState(() => _loading = false);
    }
  }

  Future<void> _select(Operation snapshot) async {
    widget.cancellations.closeObservations(widget.client);
    _detailRequest?.cancel();
    final pending = _detailRequest = ApiRequestCancellation();
    setState(() {
      _selection = snapshot;
      _detail = null;
      _detailError = null;
    });
    try {
      final response = await widget.client.request(
        'GET',
        '/v1/operations/${snapshot.id.value}',
        cancellation: pending,
      );
      final detail = Operation.fromJson(response.body.toJson());
      if (response.status != 200 ||
          detail.id != snapshot.id ||
          detail.type != snapshot.type ||
          detail.resourceType != snapshot.resourceType ||
          detail.resourceId != snapshot.resourceId ||
          detail.requestId != snapshot.requestId ||
          detail.idempotencyKey != snapshot.idempotencyKey) {
        throw const ApiProtocolException(
          'Operation detail identity disagrees with selection.',
        );
      }
      if (mounted && !pending.isCancelled) setState(() => _detail = detail);
    } on ApiRequestCancelledException {
      // Only the newest explicit selection owns this detail pane.
    } catch (error) {
      if (mounted && !pending.isCancelled) setState(() => _detailError = error);
    }
  }

  Widget _row(Operation operation) {
    final selected = operation.id == _selection?.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: selected ? const Color(0xffeef5df) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? const Color(0xff819b5c) : _line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _select(operation),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        operation.type,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: operation.state == OperationState.running
                            ? _lime
                            : _paper,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        operation.state.name,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(operation.id.value, style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 16),
                Text(
                  operation.resourceId.value,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _operationDetail(Operation operation) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'OPERATION DETAIL',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 12),
      Text(
        operation.type,
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 34),
      ),
      const SizedBox(height: 8),
      SelectableText(
        operation.id.value,
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      TextButton(
        onPressed: () => _select(_selection!),
        child: const Text('Refresh detail'),
      ),
      const SizedBox(height: 16),
      Text('Operation · ${operation.state.name}'),
      if (operation.progress.step != null) Text(operation.progress.step!),
      if (operation.progress.percent != null)
        Text('${operation.progress.percent}%'),
      const SizedBox(height: 12),
      Text(operation.cancellable ? 'Cancellable' : 'Not cancellable'),
      const SizedBox(height: 8),
      _cancellationView(operation),
      const SizedBox(height: 16),
      SelectableText(
        operation.requestId.value,
        style: const TextStyle(fontSize: 11),
      ),
      if (operation.error != null) ...[
        const SizedBox(height: 16),
        Text(operation.error!.toJson()['code']! as String),
        Text(operation.error!.message),
        Text(operation.error!.retryable ? 'Retryable' : 'Not retryable'),
        SelectableText(
          const JsonEncoder.withIndent('  ')
              .convert(operation.error!.details.toJson()),
        ),
      ],
      const SizedBox(height: 20),
      for (final entry in {
        'Resource type': operation.toJson()['resource_type']! as String,
        'Resource ID': operation.resourceId.value,
        'Idempotency key': operation.idempotencyKey ?? 'Not supplied',
        'Created at': operation.createdAt.toIso8601String(),
        'Started at': operation.startedAt?.toIso8601String() ?? 'Not started',
        'Completed at':
            operation.completedAt?.toIso8601String() ?? 'Not completed',
        'Deadline': operation.deadlineAt?.toIso8601String() ?? 'No deadline',
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
      if (operation.result != null)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Result'),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ')
                  .convert(operation.result!.toJson()),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Original request'),
        children: [
          SelectableText(
            const JsonEncoder.withIndent('  ')
                .convert(operation.request.toJson()),
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    ],
  );

  @override
  void dispose() {
    widget.cancellations.removeListener(_cancellationChanged);
    widget.cancellations.closeRequests(widget.client);
    _catalogRequest?.cancel();
    _detailRequest?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        flex: 6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'OPERATION SNAPSHOT',
              style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: _muted),
            ),
            const SizedBox(height: 12),
            if (_error != null) _apiFailure(_error!),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _operations.isEmpty
                  ? Center(
                      child: Text(
                        _error == null
                            ? 'No Operations'
                            : 'History snapshot unavailable',
                      ),
                    )
                  : ListView(
                      children: [
                        for (final operation in _operations) _row(operation),
                      ],
                    ),
            ),
            if (_nextCursor != null)
              TextButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('Load more'),
              ),
          ],
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
          child: _selection == null
              ? const Center(
                  child: Text(
                    'Select an Operation',
                    style: TextStyle(
                      fontFamily: 'InstrumentSerif',
                      fontSize: 30,
                    ),
                  ),
                )
              : _detailError != null
              ? Center(child: _apiFailure(_detailError!))
              : _detail == null
              ? const Center(child: CircularProgressIndicator())
              : _operationDetail(_detail!),
        ),
      ),
    ],
  );
}
