part of 'main.dart';

// UI-local intent and receipts only; durable state is always read from the daemon.
class _OperationCancellation {
  _OperationCancellation(this.client, this.target)
    : key =
          'ui-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  final GaoVmApiClient client;
  final OperationId target;
  final String key;
  ApiRequestCancellation? request;
  bool sending = false;
  OperationId? operationId;
  OperationState? acceptedState;
  Object? error;
  ApiRequestCancellation? observation;
  bool reading = false;
  Operation? operation;
  Object? observationError;

  bool get terminal => const {
    OperationState.succeeded,
    OperationState.failed,
    OperationState.cancelled,
  }.contains(operation?.state);
}

class _OperationCancellations extends ChangeNotifier {
  final _intents = <(String, OperationId), _OperationCancellation>{};
  bool _disposed = false;

  _OperationCancellation? get(GaoVmApiClient client, OperationId target) =>
      _intents[(client.socketPath, target)];

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> request(GaoVmApiClient client, Operation target) async {
    final scope = (client.socketPath, target.id);
    final previous = _intents[scope];
    if (previous?.sending == true ||
        previous?.operationId != null && !previous!.terminal) {
      return;
    }
    final intent = previous != null && !previous.terminal
        ? previous
        : _OperationCancellation(client, target.id);
    if (!identical(previous, intent)) previous?.observation?.cancel();
    _intents[scope] = intent;
    final pending = intent.request = ApiRequestCancellation();
    intent.sending = true;
    intent.error = null;
    _changed();
    try {
      final response = await intent.client.request(
        'POST',
        '/v1/operations/${intent.target.value}/cancel',
        body: JsonObjectValue.empty,
        idempotencyKey: intent.key,
        cancellation: pending,
      );
      final ack = response.body.toJson();
      if (response.status != 202 ||
          ack.length != 4 ||
          ack['resource_type'] != 'operation' ||
          ack['resource_id'] != intent.target.value ||
          !['pending', 'running', 'succeeded'].contains(ack['state']) ||
          ack['operation_id'] is! String) {
        throw const ApiProtocolException('Invalid cancellation acceptance.');
      }
      final id = OperationId(ack['operation_id']! as String);
      if (id == intent.target) {
        throw const ApiProtocolException('Invalid cancellation acceptance.');
      }
      intent.operationId = id;
      intent.acceptedState = OperationState.values.byName(
        ack['state']! as String,
      );
    } catch (error) {
      intent.error = error;
    } finally {
      intent.sending = false;
      _changed();
    }
  }

  Future<bool> observe(_OperationCancellation intent) async {
    final id = intent.operationId;
    if (id == null || intent.reading) return false;
    final pending = intent.observation = ApiRequestCancellation();
    intent.reading = true;
    intent.observationError = null;
    _changed();
    try {
      final response = await intent.client.request(
        'GET',
        '/v1/operations/${id.value}',
        cancellation: pending,
      );
      final operation = Operation.fromJson(response.body.toJson());
      if (response.status != 200 ||
          operation.id != id ||
          operation.type != 'operation.cancel' ||
          operation.resourceType != ResourceType.operation ||
          operation.resourceId != intent.target ||
          operation.idempotencyKey != intent.key ||
          intent.operation != null &&
              operation.requestId != intent.operation!.requestId) {
        throw const ApiProtocolException(
          'Cancellation Operation identity disagrees with its receipt.',
        );
      }
      if (pending.isCancelled) return false;
      intent.operation = operation;
      return const {
        OperationState.succeeded,
        OperationState.failed,
        OperationState.cancelled,
      }.contains(operation.state);
    } on ApiRequestCancelledException {
      return false;
    } catch (error) {
      if (!pending.isCancelled) intent.observationError = error;
      return false;
    } finally {
      intent.reading = false;
      _changed();
    }
  }

  void closeObservations(GaoVmApiClient client) {
    for (final intent in _intents.values) {
      if (intent.client.socketPath == client.socketPath) {
        intent.observation?.cancel();
      }
    }
  }

  void closeRequests(GaoVmApiClient client) {
    for (final intent in _intents.values) {
      if (intent.client.socketPath == client.socketPath) {
        intent.request?.cancel();
        intent.observation?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final intent in _intents.values) {
      intent.request?.cancel();
      intent.observation?.cancel();
    }
    super.dispose();
  }
}
