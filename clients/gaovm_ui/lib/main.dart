import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';

part 'operation_history.dart';
part 'operation_cancellation.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    for (final family in ['InstrumentSerif', 'JetBrainsMono']) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString('assets/fonts/$family-OFL.txt'));
    }
  });
  runApp(const GaoVmApp());
}

const _ink = Color(0xff203029);
const _paper = Color(0xfff1f0e9);
const _muted = Color(0xff52635a);
const _line = Color(0xffd6dcd1);
const _lime = Color(0xffc8e490);

Widget _apiFailure(Object error) {
  final children = <Widget>[];
  if (error is ApiProblemException) {
    final problem = error.problem;
    children.addAll([
      Text(problem.title),
      Text(problem.toJson()['code']! as String),
      Text(problem.detail),
      SelectableText(problem.requestId.value),
      Text(problem.retryable ? 'Retryable' : 'Not retryable'),
      if (problem.operationId != null)
        SelectableText(problem.operationId!.value),
    ]);
  } else {
    children.add(Text(error.toString()));
  }
  return Container(
    constraints: const BoxConstraints(maxHeight: 180),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xfffff0d5),
      border: Border.all(color: const Color(0xffd5bd83)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
}

enum _VmVerb {
  start('Start'),
  stop('Stop'),
  restart('Restart');

  const _VmVerb(this.label);
  final String label;
}

// Local intent/correlation only. The daemon remains the source of VM/Operation state.
class _VmAction {
  _VmAction(this.client, this.vmId, this.verb)
    : key =
          'ui-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  final GaoVmApiClient client;
  final VmId vmId;
  final _VmVerb verb;
  final String key;
  final request = ApiRequestCancellation();
  bool sending = true;
  OperationId? operationId;
  String? acceptedState;
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

class GaoVmApp extends StatelessWidget {
  const GaoVmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GaoVM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'JetBrainsMono',
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _ink,
          surface: Colors.white,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 13, height: 1.5, color: _ink),
          bodySmall: TextStyle(fontSize: 11, height: 1.5, color: _muted),
          labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _line),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _ink,
            foregroundColor: _lime,
            minimumSize: const Size(120, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
      home: const _Console(),
    );
  }
}

class _Console extends StatefulWidget {
  const _Console();

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  final _socket = TextEditingController();
  List<VirtualMachine> _vms = [];
  GaoVmApiClient? _client;
  ApiRequestCancellation? _catalogRequest;
  ApiRequestCancellation? _detailRequest;
  String? _nextCursor;
  final _seenCursors = <String>{};
  VmId? _selectedId;
  VirtualMachine? _selected;
  Object? _detailError;
  bool _loading = false;
  Object? _error;
  bool _operationsView = false;
  final _actions = <(String, VmId), _VmAction>{};
  final _cancellations = _OperationCancellations();

  bool _canSubmit(_VmAction? action, _VmVerb verb) =>
      action?.sending != true &&
      (action?.verb != verb ||
          action?.operationId == null ||
          action?.terminal == true);

  Future<void> _requestAction(VirtualMachine vm, _VmVerb verb) async {
    final client = _client;
    if (client == null) return;
    final scope = (client.socketPath, vm.metadata.id);
    var previous = _actions[scope];
    if (!_canSubmit(previous, verb)) return;
    final replay = previous?.verb == verb && previous?.operationId == null;
    if (verb != _VmVerb.start && !replay) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          backgroundColor: _paper,
          title: Text(
            '${verb.label} this VM?',
            style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
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
              Text(
                verb == _VmVerb.stop
                    ? 'Request graceful shutdown through the daemon. The Operation reports the outcome.'
                    : 'Request a restart through the daemon to apply the saved spec. The Operation reports the outcome.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text('${verb.label} VM'),
            ),
          ],
        ),
      );
      if (!mounted ||
          confirmed != true ||
          _client?.socketPath != client.socketPath ||
          _selectedId != vm.metadata.id) {
        return;
      }
      previous = _actions[scope];
      if (!_canSubmit(previous, verb)) return;
    }
    final action = previous?.verb == verb && previous?.operationId == null
        ? previous!
        : _VmAction(client, vm.metadata.id, verb);
    if (!identical(previous, action)) previous?.observation?.cancel();
    setState(() {
      _actions[scope] = action;
      action.sending = true;
      action.error = null;
    });
    try {
      final response = await action.client.request(
        'POST',
        '/v1/vms/${action.vmId.value}/actions/${action.verb.name}',
        body: JsonObjectValue.fromJson({}),
        idempotencyKey: action.key,
        cancellation: action.request,
      );
      final ack = response.body.toJson();
      if (response.status != 202 ||
          ack.length != 4 ||
          ack['resource_type'] != 'virtual_machine' ||
          ack['resource_id'] != vm.metadata.id.value ||
          !['pending', 'running', 'succeeded'].contains(ack['state']) ||
          ack['operation_id'] is! String) {
        throw const ApiProtocolException('Invalid VM action acceptance.');
      }
      final id = OperationId(ack['operation_id']! as String);
      if (mounted) {
        setState(() {
          action.operationId = id;
          action.acceptedState = ack['state']! as String;
        });
      }
    } catch (error) {
      if (mounted) setState(() => action.error = error);
    } finally {
      if (mounted) setState(() => action.sending = false);
    }
  }

  Future<void> _refreshOperation(_VmAction action) async {
    final id = action.operationId;
    if (id == null || action.reading) return;
    final pending = action.observation = ApiRequestCancellation();
    setState(() {
      action.reading = true;
      action.observationError = null;
    });
    try {
      final response = await action.client.request(
        'GET',
        '/v1/operations/${id.value}',
        cancellation: pending,
      );
      final operation = Operation.fromJson(response.body.toJson());
      if (response.status != 200 ||
          operation.id != id ||
          operation.type != 'vm.${action.verb.name}' ||
          operation.resourceType != ResourceType.virtualMachine ||
          operation.resourceId != action.vmId ||
          operation.idempotencyKey != action.key) {
        throw const ApiProtocolException(
          'Operation identity disagrees with the submitted VM action.',
        );
      }
      if (mounted && !pending.isCancelled) {
        setState(() => action.operation = operation);
        // Operation success is not proof of the VM's current observed phase.
        if (action.terminal &&
            identical(
              _actions[(action.client.socketPath, action.vmId)],
              action,
            ) &&
            _client?.socketPath == action.client.socketPath &&
            _selectedId == action.vmId &&
            _selected != null) {
          await _select(_selected!);
        }
      }
    } on ApiRequestCancelledException {
      // Closing the UI releases a local read, never the durable Operation.
    } catch (error) {
      if (mounted && !pending.isCancelled) {
        setState(() => action.observationError = error);
      }
    } finally {
      if (mounted && !pending.isCancelled) {
        setState(() => action.reading = false);
      }
    }
  }

  Widget _operationView(_VmAction action) {
    final operation = action.operation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(
          onPressed: action.reading ? null : () => _refreshOperation(action),
          child: const Text('Refresh Operation'),
        ),
        if (action.reading) const Text('Reading Operation…'),
        if (operation != null) ...[
          Text('Operation · ${operation.state.name}'),
          if (operation.progress.step != null) Text(operation.progress.step!),
          if (operation.progress.percent != null)
            Text('${operation.progress.percent}%'),
          SelectableText(
            operation.requestId.value,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          Text(operation.cancellable ? 'Cancellable' : 'Not cancellable'),
          if (operation.error != null) ...[
            Text(operation.error!.toJson()['code']! as String),
            Text(operation.error!.message),
            Text(operation.error!.retryable ? 'Retryable' : 'Not retryable'),
          ],
          if (operation.result != null)
            SelectableText(
              const JsonEncoder.withIndent('  ')
                  .convert(operation.result!.toJson()),
            ),
        ],
        if (action.observationError != null)
          _apiFailure(action.observationError!),
      ],
    );
  }

  Widget _actionView(VirtualMachine vm) {
    final action = _actions[(_client?.socketPath, vm.metadata.id)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final verb in _VmVerb.values)
              if (verb == _VmVerb.start)
                FilledButton(
                  onPressed: _canSubmit(action, verb)
                      ? () => _requestAction(vm, verb)
                      : null,
                  child: Text(
                    action?.verb == verb && action?.error != null
                        ? 'Retry ${verb.label}'
                        : verb.label,
                  ),
                )
              else
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(100, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: _canSubmit(action, verb)
                      ? () => _requestAction(vm, verb)
                      : null,
                  child: Text(
                    action?.verb == verb && action?.error != null
                        ? 'Retry ${verb.label}'
                        : verb.label,
                  ),
                ),
          ],
        ),
        if (action != null) ...[
          const SizedBox(height: 12),
          Text(
            'Last action · ${action.verb.label}',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (action.sending) const Text('Submitting action…'),
          if (action.operationId != null) ...[
            Text('Accepted · ${action.acceptedState}'),
            SelectableText(
              action.operationId!.value,
              style: const TextStyle(fontSize: 11),
            ),
            _operationView(action),
          ],
          if (action.error != null) ...[
            if (action.error is! ApiProblemException) ...[
              const Text('Outcome unknown'),
              const SizedBox(height: 4),
            ],
            const Text(
              'Retry sends the same VM intent and idempotency key.',
              style: TextStyle(fontSize: 11, color: _muted),
            ),
            const SizedBox(height: 8),
            _apiFailure(action.error!),
          ],
        ],
      ],
    );
  }

  Future<void> _connect({bool more = false, GaoVmApiClient? client}) async {
    if (more && (_client == null || _nextCursor == null)) return;
    final connection = more ? _client! : client;
    final cursor = more ? _nextCursor : null;
    final path = connection?.socketPath ?? _socket.text.trim();
    if (!path.startsWith('/') || path.contains('\u0000')) {
      setState(() => _error = 'Enter an absolute daemon socket path.');
      return;
    }
    final connectedClient = connection ?? GaoVmApiClient(socketPath: path);
    _catalogRequest?.cancel();
    if (!more) {
      _detailRequest?.cancel();
    }
    if (!more && _operationsView) {
      setState(() {
        _client = connectedClient;
        _loading = false;
        _error = null;
        _vms = [];
        _selectedId = null;
        _selected = null;
        _detailError = null;
        _nextCursor = null;
        _seenCursors.clear();
      });
      return;
    }
    final pending = _catalogRequest = ApiRequestCancellation();
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _vms = [];
        _selectedId = null;
        _selected = null;
        _client = connectedClient;
        _nextCursor = null;
        _seenCursors.clear();
      }
    });
    try {
      final response = await connectedClient.request(
        'GET',
        '/v1/vms',
        cancellation: pending,
        query: {'cursor': ?cursor},
      );
      final page = response.body.toJson();
      final items = page['items'];
      final next = page['next_cursor'];
      if (page.length != 2 ||
          !page.containsKey('next_cursor') ||
          items is! List ||
          next != null &&
              (next is! String || next.isEmpty || next.length > 512)) {
        throw const ApiProtocolException('Invalid VM catalog response.');
      }
      if (next is String && (next == cursor || _seenCursors.contains(next))) {
        throw const ApiProtocolException('VM catalog repeated its cursor.');
      }
      final vms = [if (more) ..._vms, ...items.map(VirtualMachine.fromJson)];
      if (vms.map((vm) => vm.metadata.id).toSet().length != vms.length) {
        throw const ApiProtocolException('VM catalog repeated a resource ID.');
      }
      if (mounted && !pending.isCancelled) {
        setState(() {
          _vms = vms;
          _client = connectedClient;
          _nextCursor = next as String?;
          if (cursor != null) _seenCursors.add(cursor);
        });
      }
    } on ApiRequestCancelledException {
      // Local teardown/supersession is not a daemon error or an Operation cancel.
    } catch (error) {
      if (mounted && !pending.isCancelled) setState(() => _error = error);
    } finally {
      if (mounted && !pending.isCancelled) setState(() => _loading = false);
    }
  }

  Future<void> _select(VirtualMachine vm) async {
    final client = _client;
    if (client == null) return;
    _detailRequest?.cancel();
    final pending = _detailRequest = ApiRequestCancellation();
    setState(() {
      _selectedId = vm.metadata.id;
      _selected = null;
      _detailError = null;
    });
    try {
      final response = await client.request(
        'GET',
        '/v1/vms/${vm.metadata.id.value}',
        cancellation: pending,
      );
      final detail = VirtualMachine.fromJson(response.body.toJson());
      if (detail.metadata.id != vm.metadata.id) {
        throw const ApiProtocolException(
          'VM detail identity disagrees with selection.',
        );
      }
      if (mounted && !pending.isCancelled) setState(() => _selected = detail);
    } on ApiRequestCancelledException {
      // A new explicit selection owns the detail pane.
    } catch (error) {
      if (mounted && !pending.isCancelled) setState(() => _detailError = error);
    }
  }

  Widget _detail(VirtualMachine vm) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'VM DETAIL',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 12),
      Text(
        vm.metadata.name,
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 34),
      ),
      const SizedBox(height: 8),
      SelectableText(
        vm.metadata.id.value,
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      const SizedBox(height: 24),
      Text('${vm.spec.cpu} vCPU · ${vm.spec.memoryBytes ~/ 1048576} MiB'),
      const SizedBox(height: 16),
      _actionView(vm),
      const SizedBox(height: 24),
      for (final entry in {
        'Desired state': vm.status.desiredState.name,
        'Observed phase': vm.status.toJson()['phase']! as String,
        'Spec generation': '${vm.status.specGeneration}',
        'Applied generation': '${vm.status.observedGeneration}',
        'Driver generation': '${vm.status.driverGeneration}',
        'Guest agent': vm.status.guestAgent.name,
      }.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(entry.key, style: const TextStyle(color: _muted)),
              ),
              Text(entry.value),
            ],
          ),
        ),
      if (vm.status.restartRequired)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xfffff0d5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Restart required'),
              SizedBox(height: 4),
              Text(
                'The persisted spec has not been applied to this driver generation.',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      const SizedBox(height: 24),
      const Text(
        'LABELS',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 8),
      if (vm.metadata.labels.isEmpty) const Text('No labels') else _labels(vm),
      const SizedBox(height: 20),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Specification', style: TextStyle(fontSize: 13)),
        children: [
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(vm.spec.toJson()),
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
      if (vm.status.lastError != null) ...[
        const SizedBox(height: 16),
        const Text('Last runtime error'),
        SelectableText(
          const JsonEncoder.withIndent('  ')
              .convert(vm.status.lastError!.toJson()),
        ),
      ],
    ],
  );

  Widget _labels(VirtualMachine vm) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final label in vm.metadata.labels.entries)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _paper,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${label.key} = ${label.value}',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
        ),
    ],
  );

  Widget _row(VirtualMachine vm) {
    final selected = vm.metadata.id == _selectedId;
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
          onTap: () => _select(vm),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: vm.metadata.name,
                        child: Text(
                          vm.metadata.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: vm.status.phase == VmPhase.running
                            ? _lime
                            : _paper,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        vm.status.toJson()['phase']! as String,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  vm.metadata.id.value,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Text(
                      '${vm.spec.cpu} vCPU · ${vm.spec.memoryBytes ~/ 1048576} MiB',
                    ),
                    Text('revision ${vm.metadata.revision}'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'spec ${vm.status.specGeneration} / applied ${vm.status.observedGeneration}',
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
                if (vm.metadata.labels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _labels(vm),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(Widget child) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _line),
      borderRadius: BorderRadius.circular(10),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  void _navigate(bool operations) {
    if (_operationsView == operations) return;
    final connection = _client;
    _catalogRequest?.cancel();
    _detailRequest?.cancel();
    setState(() {
      _operationsView = operations;
      _loading = false;
      _error = null;
      _selectedId = null;
      _selected = null;
      _detailError = null;
    });
    if (!operations && connection != null) _connect(client: connection);
  }

  Widget _navigation(String label, {required bool operations}) => TextButton(
    onPressed: () => _navigate(operations),
    style: TextButton.styleFrom(
      alignment: Alignment.centerLeft,
      foregroundColor: _operationsView == operations ? _lime : Colors.white,
      backgroundColor: _operationsView == operations
          ? const Color(0xff35463b)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(label, style: const TextStyle(fontSize: 11)),
  );

  @override
  void dispose() {
    _catalogRequest?.cancel();
    _detailRequest?.cancel();
    _cancellations.dispose();
    for (final action in _actions.values) {
      action.request.cancel();
      action.observation?.cancel();
    }
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 192,
            color: _ink,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'GaoVM.',
                  style: TextStyle(
                    fontFamily: 'InstrumentSerif',
                    fontSize: 38,
                    color: _lime,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'DESKTOP CONSOLE',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1,
                    color: Color(0xffc0c9c0),
                  ),
                ),
                const SizedBox(height: 48),
                const Text(
                  '01 / RESOURCES',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.4,
                    color: _lime,
                  ),
                ),
                const SizedBox(height: 16),
                _navigation('Virtual machines', operations: false),
                const SizedBox(height: 8),
                _navigation('Operations', operations: true),
                const Spacer(),
                const Icon(Icons.hub_outlined, color: _lime, size: 22),
                const SizedBox(height: 16),
                const Text(
                  'PUBLIC API\n/v1 · Unix socket',
                  style: TextStyle(fontSize: 11, color: Color(0xffc0c9c0)),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Closing this window\ndoes not stop VMs.',
                  style: TextStyle(fontSize: 10, color: Color(0xffc0c9c0)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _operationsView
                                  ? 'CONTROL PLANE / HISTORY'
                                  : 'CONTROL PLANE / CATALOG',
                              style: const TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.8,
                                color: _muted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _operationsView
                                  ? 'Operations'
                                  : 'Virtual machines',
                              style: const TextStyle(
                                fontFamily: 'InstrumentSerif',
                                fontSize: 46,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _operationsView
                                  ? 'Durable intents from every client. Select an Operation to fetch its current detail.'
                                  : 'The daemon’s shared catalog. Select a VM to fetch its current detail.',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _client == null
                            ? 'DISCONNECTED'
                            : _operationsView || _loading || _error != null
                            ? 'API CONFIGURED'
                            : '${_vms.length} loaded',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _socket,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'Daemon socket',
                            hintText: '/absolute/path/to/api.sock',
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      FilledButton(
                        onPressed: _loading ? null : _connect,
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _apiFailure(_error!),
                    ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: _operationsView
                        ? _client == null
                              ? _panel(
                                  const Center(
                                    child: Text(
                                      'Connect to read Operation history',
                                    ),
                                  ),
                                )
                              : _OperationHistory(
                                  key: ObjectKey(_client),
                                  client: _client!,
                                  cancellations: _cancellations,
                                )
                        : Row(
                            children: [
                              Expanded(
                                flex: 6,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text(
                                      'CATALOG SNAPSHOT',
                                      style: TextStyle(
                                        fontSize: 10,
                                        letterSpacing: 1.5,
                                        color: _muted,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Expanded(
                                      child: _vms.isEmpty
                                          ? Center(
                                              child: Text(
                                                _loading
                                                    ? 'Loading VM catalog…'
                                                    : _error != null
                                                    ? 'VM catalog snapshot unavailable'
                                                    : _client == null
                                                    ? 'Connect to a daemon'
                                                    : 'No virtual machines',
                                              ),
                                            )
                                          : ListView(
                                              children: [
                                                for (final vm in _vms) _row(vm),
                                              ],
                                            ),
                                    ),
                                    if (_nextCursor != null)
                                      TextButton(
                                        onPressed: _loading
                                            ? null
                                            : () => _connect(more: true),
                                        child: const Text('Load more'),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 5,
                                child: _panel(
                                  _selectedId == null
                                      ? const Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.dns_outlined,
                                                size: 40,
                                                color: _muted,
                                              ),
                                              SizedBox(height: 20),
                                              Text(
                                                'Select a VM',
                                                style: TextStyle(
                                                  fontFamily: 'InstrumentSerif',
                                                  fontSize: 30,
                                                ),
                                              ),
                                              SizedBox(height: 10),
                                              Text(
                                                'No default VM. Every selection is explicit.',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: _muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                      : _detailError != null
                                      ? Center(
                                          child: _apiFailure(_detailError!),
                                        )
                                      : _selected == null
                                      ? const Center(
                                          child: CircularProgressIndicator(),
                                        )
                                      : _detail(_selected!),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _operationsView
                        ? 'OPERATION SNAPSHOT · History reads do not select a VM or submit commands.'
                        : 'CATALOG SNAPSHOT · Actions submit durable Operations. Acceptance is not VM completion.',
                    style: const TextStyle(fontSize: 10, color: _muted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
