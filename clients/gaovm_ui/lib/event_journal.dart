part of 'main.dart';

typedef _EventScope = ({
  VmId? vmId,
  OperationId? operationId,
  TestRunId? testRunId,
});

class _EventJournal extends StatefulWidget {
  const _EventJournal({super.key, required this.client});
  final GaoVmApiClient client;

  @override
  State<_EventJournal> createState() => _EventJournalState();
}

class _EventJournalState extends State<_EventJournal> {
  final _vmFilter = TextEditingController();
  final _operationFilter = TextEditingController();
  final _testRunFilter = TextEditingController();
  final _afterFilter = TextEditingController(text: '0');
  final _events = <({Event event, int bytes})>[];
  int _retainedBytes = 0;
  Event? _selected;
  StreamSubscription<Event>? _subscription;
  int _generation = 0;
  int _cursor = 0;
  bool _watching = false;
  bool _started = false;
  int _omitted = 0;
  bool _selectionEvicted = false;
  Object? _error;
  String? _draftError;
  _EventScope? _scope;

  Future<void> _pause() async {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    if (mounted) {
      setState(() => _watching = false);
    }
    await subscription?.cancel();
  }

  void _interrupt(Object error) {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    setState(() {
      _watching = false;
      _error = error;
    });
    unawaited(subscription?.cancel());
  }

  Future<void> _start({bool resume = false}) async {
    if (_watching || resume && !_started) return;
    _EventScope scope;
    int cursor;
    try {
      if (resume) {
        scope = _scope!;
        cursor = _cursor;
      } else {
        final after = _afterFilter.text.trim();
        final parsed = int.tryParse(after);
        if (!RegExp(r'^[0-9]+$').hasMatch(after) || parsed == null) {
          throw const FormatException(
            'Use a nonnegative 64-bit decimal cursor.',
          );
        }
        cursor = parsed;
        final vm = _vmFilter.text.trim();
        final operation = _operationFilter.text.trim();
        final testRun = _testRunFilter.text.trim();
        scope = (
          vmId: vm.isEmpty ? null : VmId(vm),
          operationId: operation.isEmpty ? null : OperationId(operation),
          testRunId: testRun.isEmpty ? null : TestRunId(testRun),
        );
      }
    } on FormatException catch (error) {
      setState(() => _draftError = 'Invalid event scope: ${error.message}');
      return;
    } on ArgumentError catch (error) {
      setState(() => _draftError = 'Invalid event scope: ${error.message}');
      return;
    }
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    setState(() {
      _watching = true;
      _started = true;
      _error = null;
      _draftError = null;
      if (!resume) {
        _events.clear();
        _retainedBytes = 0;
        _selected = null;
        _omitted = 0;
        _selectionEvicted = false;
        _scope = scope;
        _cursor = cursor;
      }
    });
    await previous?.cancel();
    if (!mounted || generation != _generation) return;
    _subscription = widget.client
        .watchEvents(
          afterSequence: cursor,
          lastEventId: resume ? '$cursor' : null,
          vmId: scope.vmId,
          operationId: scope.operationId,
          testRunId: scope.testRunId,
        )
        .listen(
          (event) {
            if (!mounted || generation != _generation) return;
            if (scope.vmId != null && scope.vmId != event.vmId ||
                scope.operationId != null &&
                    scope.operationId != event.operationId ||
                scope.testRunId != null && scope.testRunId != event.testRunId) {
              _interrupt(
                const ApiProtocolException(
                  'event does not match the active scope',
                ),
              );
              return;
            }
            if (_events.any((entry) => entry.event.eventId == event.eventId)) {
              _interrupt(
                const ApiProtocolException('reused a retained event ID'),
              );
              return;
            }
            setState(() {
              final bytes = utf8.encode(jsonEncode(event.toJson())).length;
              _events.add((event: event, bytes: bytes));
              _retainedBytes += bytes;
              _cursor = event.sequence;
              while (_events.length > 200 || _retainedBytes > 2 * 1024 * 1024) {
                final evicted = _events.removeAt(0);
                _retainedBytes -= evicted.bytes;
                _omitted++;
                if (_selected?.eventId == evicted.event.eventId) {
                  _selected = null;
                  _selectionEvicted = true;
                }
              }
            });
          },
          onError: (Object error) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _error = error;
              _watching = false;
            });
          },
          onDone: () {
            if (mounted && generation == _generation) {
              setState(() => _watching = false);
            }
          },
          cancelOnError: true,
        );
  }

  Widget _row(Event event) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: _selected?.eventId == event.eventId
          ? const Color(0xffeef5df)
          : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() {
          _selected = event;
          _selectionEvicted = false;
        }),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(event.type, style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 8),
              Text(event.eventId.value, style: const TextStyle(fontSize: 11)),
              const SizedBox(height: 12),
              Text(
                'Sequence ${event.sequence}',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _detail(Event event) => ListView(
    key: const ValueKey('event-detail-scroll'),
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'EVENT DETAIL',
        style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: _muted),
      ),
      const SizedBox(height: 12),
      Text(
        event.type,
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 34),
      ),
      const SizedBox(height: 8),
      SelectableText(event.eventId.value, style: const TextStyle(fontSize: 11)),
      const SizedBox(height: 20),
      Text('Event · ${event.sequence}'),
      for (final entry in {
        'Resource type': event.toJson()['resource_type']! as String,
        'Resource ID': event.resourceId?.value ?? 'No resource ID',
        'VM ID': event.vmId?.value ?? 'No VM correlation',
        'Operation ID': event.operationId?.value ?? 'No Operation correlation',
        'TestRun ID': event.testRunId?.value ?? 'No TestRun correlation',
        'Occurred at': event.occurredAt.toIso8601String(),
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
      SelectableText(
        const JsonEncoder.withIndent('  ').convert(event.payload.toJson()),
        style: const TextStyle(fontSize: 11),
      ),
    ],
  );

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    _vmFilter.dispose();
    _operationFilter.dispose();
    _testRunFilter.dispose();
    _afterFilter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          for (final field in [
            ('event-vm-filter', 'VM ID (optional)', _vmFilter),
            (
              'event-operation-filter',
              'Operation ID (optional)',
              _operationFilter,
            ),
            ('event-test-run-filter', 'TestRun ID (optional)', _testRunFilter),
          ]) ...[
            Expanded(
              child: TextField(
                key: ValueKey(field.$1),
                controller: field.$3,
                style: const TextStyle(fontSize: 11),
                decoration: InputDecoration(labelText: field.$2),
              ),
            ),
            const SizedBox(width: 12),
          ],
          SizedBox(
            width: 150,
            child: TextField(
              key: const ValueKey('event-after-filter'),
              controller: _afterFilter,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(labelText: 'After sequence'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        'Start applies a new scope and clears this view. Resume keeps the active scope and cursor.',
        style: TextStyle(fontSize: 11, color: _muted),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton(
            onPressed: _watching ? null : () => _start(),
            child: const Text('Start stream'),
          ),
          TextButton(
            onPressed: _started && !_watching
                ? () => _start(resume: true)
                : null,
            child: const Text('Resume stream'),
          ),
          TextButton(
            onPressed: _watching ? _pause : null,
            child: const Text('Pause stream'),
          ),
          Text(
            'Resume cursor · $_cursor',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        _watching
            ? 'Watching · 30 s window'
            : _error != null
            ? 'Stream interrupted'
            : 'Stream paused',
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      if (_scope != null)
        Text(
          _scope!.vmId == null &&
                  _scope!.operationId == null &&
                  _scope!.testRunId == null
              ? 'Scope · all resources'
              : 'Active scope · ${[if (_scope!.vmId != null) 'VM ${_scope!.vmId!.value}', if (_scope!.operationId != null) 'Operation ${_scope!.operationId!.value}', if (_scope!.testRunId != null) 'TestRun ${_scope!.testRunId!.value}'].join(' · ')}',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      if (_draftError != null) Text(_draftError!),
      if (_error != null) _apiFailure(_error!),
      if (_started)
        Text(
          'Retained · ${_events.length} events · $_omitted omitted from this view',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      const SizedBox(height: 16),
      Expanded(
        child: Row(
          children: [
            Expanded(
              flex: 6,
              child: _events.isEmpty
                  ? Center(
                      child: Text(
                        _watching
                            ? 'Waiting for committed events'
                            : _started
                            ? 'No events consumed in this scope'
                            : 'Start the event stream',
                      ),
                    )
                  : ListView(
                      children: [
                        for (final entry in _events) _row(entry.event),
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
                child: _selected == null
                    ? Center(
                        child: Text(
                          _selectionEvicted
                              ? 'Selected event left the retained window.'
                              : 'Select an event',
                          style: const TextStyle(
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
