part of 'main.dart';

// Immutable local request/correlation, never a replacement VM repository.
class _VmWrite {
  _VmWrite.create(this.client, VmCreateRequest input)
    : isCreate = true,
      targetVmId = null,
      ifMatch = null,
      name = input.name,
      body = JsonObjectValue.fromJson(input.toJson()),
      key =
          'ui-write-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  _VmWrite.patch(
    this.client,
    VirtualMachine vm,
    VmPatchRequest input,
    this.ifMatch,
  ) : isCreate = false,
      targetVmId = vm.metadata.id,
      name = vm.metadata.name,
      body = JsonObjectValue.fromJson(input.toJson()),
      key =
          'ui-write-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  final GaoVmApiClient client;
  final bool isCreate;
  final VmId? targetVmId;
  final String? ifMatch;
  final String name;
  final JsonObjectValue body;
  final String key;
  ApiRequestCancellation request = ApiRequestCancellation();
  bool sending = true;
  Object? error;
  VmId? vmId;
  OperationId? operationId;
  String? acceptedState;
  RequestId? requestId;
  ApiRequestCancellation? observation;
  bool reading = false;
  Operation? operation;
  RequestId? readRequestId;
  Object? readError;

  bool get terminal => const {
    OperationState.succeeded,
    OperationState.failed,
    OperationState.cancelled,
  }.contains(operation?.state);
}

class _VmWrites extends ChangeNotifier {
  final _intents = <_VmWrite>[];
  bool _closed = false;

  Iterable<_VmWrite> forClient(GaoVmApiClient client) =>
      _intents.where((intent) => intent.client.socketPath == client.socketPath);

  Future<void> create(GaoVmApiClient client, VmCreateRequest input) async {
    if (_closed) return;
    final intent = _VmWrite.create(client, input);
    _intents.add(intent);
    await _send(intent);
  }

  Future<void> _send(_VmWrite intent) async {
    final pending = intent.request = ApiRequestCancellation();
    intent.sending = true;
    intent.error = null;
    notifyListeners();
    try {
      final response = await intent.client.request(
        intent.isCreate ? 'POST' : 'PATCH',
        intent.isCreate ? '/v1/vms' : '/v1/vms/${intent.targetVmId!.value}',
        body: intent.body,
        ifMatch: intent.ifMatch,
        idempotencyKey: intent.key,
        cancellation: pending,
      );
      final body = response.body.toJson();
      if (response.status != 202 ||
          body.length != 4 ||
          body['resource_type'] != 'virtual_machine' ||
          body['resource_id'] is! String ||
          body['operation_id'] is! String ||
          !const ['pending', 'running', 'succeeded'].contains(body['state']) ||
          response.requestId == null) {
        throw const ApiProtocolException('Invalid VM write acceptance.');
      }
      final vmId = VmId(body['resource_id']! as String);
      final operationId = OperationId(body['operation_id']! as String);
      final requestId = RequestId(response.requestId!);
      if (intent.targetVmId != null && vmId != intent.targetVmId) {
        throw const ApiProtocolException(
          'VM write target disagrees with the confirmed input.',
        );
      }
      if (!_closed &&
          identical(intent.request, pending) &&
          !pending.isCancelled) {
        intent.vmId = vmId;
        intent.operationId = operationId;
        intent.acceptedState = body['state']! as String;
        intent.requestId = requestId;
      }
    } catch (error) {
      if (!_closed && identical(intent.request, pending)) {
        intent.error = error is FormatException || error is ArgumentError
            ? const ApiProtocolException('Invalid VM write acceptance.')
            : error;
      }
    } finally {
      if (!_closed && identical(intent.request, pending)) {
        intent.sending = false;
        notifyListeners();
      }
    }
  }

  Future<void> replay(_VmWrite intent) async {
    if (_closed ||
        intent.sending ||
        intent.operationId != null ||
        intent.error == null) {
      return;
    }
    await _send(intent);
  }

  Future<void> observe(_VmWrite intent) async {
    final id = intent.operationId;
    if (_closed || id == null || intent.reading) return;
    final pending = intent.observation = ApiRequestCancellation();
    intent.reading = true;
    intent.readError = null;
    notifyListeners();
    try {
      final response = await intent.client.request(
        'GET',
        '/v1/operations/${id.value}',
        cancellation: pending,
      );
      final operation = Operation.fromJson(response.body.toJson());
      if (response.status != 200 ||
          response.requestId == null ||
          operation.id != id ||
          operation.type != (intent.isCreate ? 'vm.create' : 'vm.patch') ||
          operation.resourceType != ResourceType.virtualMachine ||
          operation.resourceId != intent.vmId ||
          operation.idempotencyKey != intent.key ||
          intent.operation != null &&
              operation.requestId != intent.operation!.requestId) {
        throw const ApiProtocolException(
          'Write Operation identity disagrees with the accepted input.',
        );
      }
      final readRequestId = RequestId(response.requestId!);
      if (!_closed &&
          identical(intent.observation, pending) &&
          !pending.isCancelled) {
        intent.operation = operation;
        intent.readRequestId = readRequestId;
      }
    } on ApiRequestCancelledException {
      // Only the local observation was released, not the durable write.
    } catch (error) {
      if (!_closed &&
          identical(intent.observation, pending) &&
          !pending.isCancelled) {
        intent.readError = error is FormatException || error is ArgumentError
            ? const ApiProtocolException('Invalid VM write Operation.')
            : error;
      }
    } finally {
      if (!_closed && identical(intent.observation, pending)) {
        intent.reading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    for (final intent in _intents) {
      intent.request.cancel();
      intent.observation?.cancel();
    }
    super.dispose();
  }

  bool canEdit(GaoVmApiClient client, VmId id) {
    _VmWrite? previous;
    for (final intent in forClient(client)) {
      if (intent.targetVmId == id) previous = intent;
    }
    return !_closed &&
        (previous == null ||
            !previous.sending &&
                !previous.reading &&
                (previous.terminal ||
                    previous.operationId == null &&
                        previous.error is ApiProblemException));
  }

  void releaseLocal(GaoVmApiClient client) {
    if (_closed) return;
    for (final intent in forClient(client)) {
      if (intent.sending) {
        intent.request.cancel();
        intent.sending = false;
        intent.error = const ApiRequestCancelledException();
      }
      if (intent.reading) {
        intent.observation?.cancel();
        intent.reading = false;
      }
    }
    // Called during shelf disposal. The cancelled futures notify after layout.
  }

  Future<void> patch(
    GaoVmApiClient client,
    VirtualMachine vm,
    VmPatchRequest input,
    String etag,
  ) async {
    if (!canEdit(client, vm.metadata.id)) return;
    final intent = _VmWrite.patch(client, vm, input, etag);
    _intents.add(intent);
    await _send(intent);
  }
}

class _VmWriteEditor<T> extends StatefulWidget {
  const _VmWriteEditor({
    required this.title,
    required this.explanation,
    required this.submit,
    required this.initial,
    required this.parse,
    this.revision,
  });
  final String title;
  final String explanation;
  final String submit;
  final String initial;
  final T Function(String) parse;
  final String? revision;

  @override
  State<_VmWriteEditor<T>> createState() => _VmWriteEditorState<T>();
}

class _VmWriteEditorState<T> extends State<_VmWriteEditor<T>> {
  late final _json = TextEditingController(text: widget.initial);
  Object? _error;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 800),
    backgroundColor: _paper,
    title: Text(
      widget.title,
      style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
    ),
    content: SizedBox(
      width: 740,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.explanation),
            if (widget.revision != null)
              Text('Revision precondition · ${widget.revision}'),
            const SizedBox(height: 16),
            TextField(
              key: const Key('vm-write-json'),
              controller: _json,
              minLines: 8,
              maxLines: 14,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(labelText: 'VM request JSON'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _apiFailure(_error!),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Discard draft'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(context, widget.parse(_json.text));
          } on FormatException catch (error) {
            setState(() => _error = error);
          } on ArgumentError catch (error) {
            setState(() => _error = error);
          }
        },
        child: Text(widget.submit),
      ),
    ],
  );
}

class _VmWriteShelf extends StatefulWidget {
  const _VmWriteShelf({
    super.key,
    required this.writes,
    required this.client,
    required this.onReloadCatalog,
  });
  final _VmWrites writes;
  final GaoVmApiClient client;
  final VoidCallback onReloadCatalog;

  @override
  State<_VmWriteShelf> createState() => _VmWriteShelfState();
}

class _VmWriteShelfState extends State<_VmWriteShelf> {
  final _scroll = ScrollController();
  _VmWrites get writes => widget.writes;
  GaoVmApiClient get client => widget.client;
  VoidCallback get onReloadCatalog => widget.onReloadCatalog;

  @override
  void dispose() {
    writes.releaseLocal(client);
    _scroll.dispose();
    super.dispose();
  }

  Widget _operation(_VmWrite intent) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: intent.reading ? null : () => writes.observe(intent),
        child: const Text('Refresh write Operation'),
      ),
      if (intent.reading) const Text('Reading write Operation…'),
      if (intent.operation case final operation?) ...[
        Text('Write Operation · ${operation.state.name}'),
        if (operation.progress.step != null) Text(operation.progress.step!),
        if (operation.progress.percent != null)
          Text('${operation.progress.percent}%'),
        Text(
          'Write original request · ${operation.requestId.value}',
          style: const TextStyle(fontSize: 11),
        ),
        Text(
          'Write read request · ${intent.readRequestId!.value}',
          style: const TextStyle(fontSize: 11),
        ),
        if (operation.error != null) ...[
          Text(operation.error!.toJson()['code']! as String),
          Text(operation.error!.message),
          Text(operation.error!.retryable ? 'Retryable' : 'Not retryable'),
        ],
        Material(
          color: _paper,
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Write Operation JSON',
              style: TextStyle(fontSize: 11),
            ),
            children: [
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(operation.toJson()),
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        if (intent.terminal)
          TextButton(
            onPressed: onReloadCatalog,
            child: const Text('Reload written VM catalog'),
          ),
      ],
      if (intent.readError != null) ...[
        _apiFailure(intent.readError!),
        if (intent.operation != null)
          const Text(
            'Write read failed · last validated Operation retained.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: writes,
    builder: (context, _) {
      final intents = writes.forClient(client).toList();
      if (intents.isEmpty) return const SizedBox.shrink();
      return Container(
        constraints: const BoxConstraints(maxHeight: 260),
        margin: const EdgeInsets.only(bottom: 16),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            primary: false,
            shrinkWrap: true,
            children: [
              for (final intent in intents)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _paper,
                    border: Border.all(color: _line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'VM WRITE INTENT',
                        style: TextStyle(fontSize: 10, letterSpacing: 1.5),
                      ),
                      Text(intent.name),
                      if (intent.sending) const Text('Submitting VM write…'),
                      if (intent.operationId != null) ...[
                        Text(
                          'VM ${intent.isCreate ? 'create' : 'patch'} accepted · ${intent.acceptedState}',
                        ),
                        SelectableText(
                          intent.vmId!.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                        SelectableText(
                          intent.operationId!.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                        SelectableText(
                          intent.requestId!.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                        const Text(
                          'Acceptance does not prove provisioning or applied configuration.',
                          style: TextStyle(fontSize: 11, color: _muted),
                        ),
                        _operation(intent),
                      ],
                      if (intent.error != null) ...[
                        if (intent.error is! ApiProblemException)
                          const Text('VM write outcome unknown'),
                        _apiFailure(intent.error!),
                        TextButton(
                          onPressed: intent.sending
                              ? null
                              : () => writes.replay(intent),
                          child: const Text('Replay VM write'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
