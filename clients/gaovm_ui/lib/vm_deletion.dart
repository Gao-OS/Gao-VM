part of 'main.dart';

// Confirmed local intent/correlation only. The daemon owns deletion and its files.
class _VmDeletion {
  _VmDeletion(this.client, VirtualMachine vm)
    : vmId = vm.metadata.id,
      name = vm.metadata.name,
      key =
          'ui-delete-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  final GaoVmApiClient client;
  final VmId vmId;
  final String name;
  final String key;
  ApiRequestCancellation request = ApiRequestCancellation();
  bool sending = true;
  Object? error;
  OperationId? operationId;
  String? acceptedState;
  RequestId? responseRequestId;
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

class _VmDeletions extends ChangeNotifier {
  final _intents = <(String, VmId), _VmDeletion>{};
  bool _closed = false;

  Iterable<_VmDeletion> forClient(GaoVmApiClient client) => _intents.values
      .where((intent) => intent.client.socketPath == client.socketPath);

  bool canSubmit(GaoVmApiClient client, VmId id) {
    final previous = _intents[(client.socketPath, id)];
    return !_closed &&
        (previous == null ||
            !previous.sending &&
                !previous.reading &&
                (previous.terminal ||
                    previous.operationId == null &&
                        previous.error is ApiProblemException));
  }

  Future<void> submit(GaoVmApiClient client, VirtualMachine vm) async {
    if (!canSubmit(client, vm.metadata.id)) return;
    final intent = _VmDeletion(client, vm);
    _intents[(client.socketPath, intent.vmId)] = intent;
    await _send(intent);
  }

  Future<void> replay(_VmDeletion intent) async {
    if (_closed ||
        intent.sending ||
        intent.operationId != null ||
        intent.error == null) {
      return;
    }
    await _send(intent);
  }

  Future<void> _send(_VmDeletion intent) async {
    final pending = intent.request = ApiRequestCancellation();
    intent.sending = true;
    intent.error = null;
    notifyListeners();
    try {
      final response = await intent.client.request(
        'DELETE',
        '/v1/vms/${intent.vmId.value}',
        idempotencyKey: intent.key,
        cancellation: pending,
      );
      final body = response.body.toJson();
      if (response.status != 202 ||
          body.length != 4 ||
          body['resource_type'] != 'virtual_machine' ||
          body['resource_id'] != intent.vmId.value ||
          !const ['pending', 'running', 'succeeded'].contains(body['state']) ||
          body['operation_id'] is! String ||
          response.requestId == null) {
        throw const ApiProtocolException('Invalid VM deletion acceptance.');
      }
      final operationId = OperationId(body['operation_id']! as String);
      final requestId = RequestId(response.requestId!);
      if (!_closed &&
          identical(intent.request, pending) &&
          !pending.isCancelled) {
        intent.operationId = operationId;
        intent.acceptedState = body['state']! as String;
        intent.responseRequestId = requestId;
      }
    } catch (error) {
      if (!_closed && identical(intent.request, pending)) {
        intent.error = error is FormatException || error is ArgumentError
            ? const ApiProtocolException('Invalid VM deletion acceptance.')
            : error;
      }
    } finally {
      if (!_closed && identical(intent.request, pending)) {
        intent.sending = false;
        notifyListeners();
      }
    }
  }

  Future<void> observe(_VmDeletion intent) async {
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
          operation.type != 'vm.delete' ||
          operation.resourceType != ResourceType.virtualMachine ||
          operation.resourceId != intent.vmId ||
          operation.idempotencyKey != intent.key ||
          intent.operation != null &&
              operation.requestId != intent.operation!.requestId) {
        throw const ApiProtocolException(
          'Deletion Operation identity disagrees with the confirmed intent.',
        );
      }
      final requestId = RequestId(response.requestId!);
      if (!_closed &&
          identical(intent.observation, pending) &&
          !pending.isCancelled) {
        intent.operation = operation;
        intent.readRequestId = requestId;
      }
    } on ApiRequestCancelledException {
      // A local read was released. The durable deletion is still daemon-owned.
    } catch (error) {
      if (!_closed &&
          identical(intent.observation, pending) &&
          !pending.isCancelled) {
        intent.readError = error is FormatException || error is ArgumentError
            ? const ApiProtocolException('Invalid deletion Operation response.')
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
    for (final intent in _intents.values) {
      intent.request.cancel();
      intent.observation?.cancel();
    }
    super.dispose();
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
    // Shelf disposal runs during layout. Cancellation futures notify after that
    // frame; do not synchronously rebuild a disposing ancestor here.
  }
}

extension _VmDeletionConsole on _ConsoleState {
  Widget _deleteButton(VirtualMachine vm) => ListenableBuilder(
    listenable: _deletions,
    builder: (context, _) => OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(100, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed:
          _client != null && _deletions.canSubmit(_client!, vm.metadata.id)
          ? () => _confirmDeletion(vm)
          : null,
      child: const Text('Delete'),
    ),
  );

  Future<void> _confirmDeletion(VirtualMachine vm) async {
    final client = _client;
    if (client == null || !_deletions.canSubmit(client, vm.metadata.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 520),
        backgroundColor: _paper,
        title: const Text(
          'Delete this VM?',
          style: TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(vm.metadata.name),
            const SizedBox(height: 8),
            SelectableText(
              vm.metadata.id.value,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 20),
            const Text(
              'The daemon stops this VM if needed and deletes its managed files asynchronously.',
            ),
            const SizedBox(height: 8),
            const Text('External disks are preserved.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep VM'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete VM'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !identical(_client, client) ||
        _selectedId != vm.metadata.id ||
        _view != _ConsoleView.vms) {
      return;
    }
    await _deletions.submit(client, vm);
  }
}

class _VmDeletionShelf extends StatefulWidget {
  const _VmDeletionShelf({
    super.key,
    required this.deletions,
    required this.client,
    required this.onReloadCatalog,
  });
  final _VmDeletions deletions;
  final GaoVmApiClient client;
  final VoidCallback onReloadCatalog;

  @override
  State<_VmDeletionShelf> createState() => _VmDeletionShelfState();
}

class _VmDeletionShelfState extends State<_VmDeletionShelf> {
  final _scroll = ScrollController();
  _VmDeletions get deletions => widget.deletions;
  GaoVmApiClient get client => widget.client;
  VoidCallback get onReloadCatalog => widget.onReloadCatalog;

  @override
  void dispose() {
    deletions.releaseLocal(client);
    _scroll.dispose();
    super.dispose();
  }

  Widget _operation(_VmDeletion intent) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: intent.reading ? null : () => deletions.observe(intent),
        child: const Text('Refresh deletion Operation'),
      ),
      if (intent.reading) const Text('Reading deletion Operation…'),
      if (intent.operation case final operation?) ...[
        Text('Deletion Operation · ${operation.state.name}'),
        if (operation.progress.step != null) Text(operation.progress.step!),
        if (operation.progress.percent != null)
          Text('${operation.progress.percent}%'),
        Text(
          'Original request · ${operation.requestId.value}',
          style: const TextStyle(fontSize: 11),
        ),
        Text(
          'Read request · ${intent.readRequestId!.value}',
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
              'Deletion Operation JSON',
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
        if (intent.terminal) ...[
          const Text(
            'Reload the catalog explicitly to observe resource presence.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
          TextButton(
            onPressed: onReloadCatalog,
            child: const Text('Reload VM catalog'),
          ),
        ],
      ],
      if (intent.readError != null) ...[
        _apiFailure(intent.readError!),
        if (intent.operation != null)
          const Text(
            'Deletion read failed · last validated Operation retained.',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: deletions,
    builder: (context, _) {
      final intents = deletions.forClient(client).toList();
      if (intents.isEmpty) return const SizedBox.shrink();
      return Container(
        constraints: const BoxConstraints(maxHeight: 300),
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
                        'DELETION INTENT',
                        style: TextStyle(fontSize: 10, letterSpacing: 1.5),
                      ),
                      Text(intent.name),
                      SelectableText(
                        intent.vmId.value,
                        style: const TextStyle(fontSize: 11),
                      ),
                      if (intent.sending) const Text('Submitting deletion…'),
                      if (intent.operationId != null) ...[
                        Text('Deletion accepted · ${intent.acceptedState}'),
                        SelectableText(
                          intent.operationId!.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                        SelectableText(
                          intent.responseRequestId!.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                        const Text(
                          'Acceptance does not prove VM deletion.',
                          style: TextStyle(fontSize: 11, color: _muted),
                        ),
                        _operation(intent),
                      ],
                      if (intent.error != null) ...[
                        if (intent.error is! ApiProblemException)
                          const Text('Deletion outcome unknown'),
                        _apiFailure(intent.error!),
                        TextButton(
                          onPressed: intent.sending
                              ? null
                              : () => deletions.replay(intent),
                          child: const Text('Replay deletion'),
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
