part of 'main.dart';

class _HostStatus extends StatelessWidget {
  const _HostStatus({super.key, required this.client});
  final GaoVmApiClient client;

  Widget _health(SystemHealth health) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${health.probe == SystemHealthProbe.live ? 'Live' : 'Ready'} · ${health.healthy}',
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
      ),
      const SizedBox(height: 12),
      if (health.checks == null || health.checks!.properties.isEmpty)
        const Text('No checks reported')
      else
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(health.checks!.toJson()),
          style: const TextStyle(fontSize: 11),
        ),
    ],
  );

  Widget _capabilities(PublicCapabilities capabilities) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'API · v1',
        style: TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
      ),
      const SizedBox(height: 12),
      Text('Backends · ${capabilities.backends.join(' · ')}'),
      Text('Guest APIs · ${capabilities.guest.join(' · ')}'),
      const SizedBox(height: 12),
      Text('Maximum defined VMs · ${capabilities.maxDefinedVms}'),
      Text('Maximum running VMs · ${capabilities.maxRunningVms}'),
      Text('Maximum concurrent boots · ${capabilities.maxConcurrentBoots}'),
      const SizedBox(height: 12),
      const Text(
        'Advertisements are not negotiated driver capabilities or guest readiness.',
        style: TextStyle(fontSize: 11, color: _muted),
      ),
    ],
  );

  Widget _doctor(DoctorResult report) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        report.healthy
            ? 'Doctor reported healthy'
            : 'Doctor reported unhealthy',
        style: const TextStyle(fontFamily: 'InstrumentSerif', fontSize: 30),
      ),
      if (report.checks.isEmpty) const Text('No doctor checks reported'),
      for (final check in report.checks)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${check.name} · ${check.status.name}'),
              SelectableText(
                check.message,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('host-status-scroll'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _HostRead<SystemHealth>(
                client: client,
                path: '/v1/system/live',
                title: 'Daemon liveness',
                decode: (value) =>
                    SystemHealth.fromJson(value, probe: SystemHealthProbe.live),
                contents: _health,
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: _HostRead<SystemHealth>(
                client: client,
                path: '/v1/system/ready',
                title: 'Dependency readiness',
                decode: (value) => SystemHealth.fromJson(
                  value,
                  probe: SystemHealthProbe.ready,
                ),
                contents: _health,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _HostRead<PublicCapabilities>(
                client: client,
                path: '/v1/system/capabilities',
                title: 'Capabilities',
                decode: PublicCapabilities.fromJson,
                contents: _capabilities,
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: _HostRead<DoctorResult>(
                client: client,
                path: '/v1/system/doctor',
                title: 'Host doctor',
                decode: DoctorResult.fromJson,
                contents: _doctor,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _HostRead<T> extends StatefulWidget {
  const _HostRead({
    required this.client,
    required this.path,
    required this.title,
    required this.decode,
    required this.contents,
  });

  final GaoVmApiClient client;
  final String path;
  final String title;
  final T Function(Object?) decode;
  final Widget Function(T) contents;

  @override
  State<_HostRead<T>> createState() => _HostReadState<T>();
}

class _HostReadState<T> extends State<_HostRead<T>> {
  ApiRequestCancellation? _request;
  ({T value, int status, RequestId requestId, DateTime receivedAt})? _snapshot;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _request?.cancel();
    final pending = _request = ApiRequestCancellation();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.client.request(
        'GET',
        widget.path,
        cancellation: pending,
      );
      if (response.status != 200 &&
          !(response.status == 503 &&
              const {
                '/v1/system/live',
                '/v1/system/ready',
              }.contains(widget.path))) {
        throw const ApiProtocolException('Invalid host report HTTP status.');
      }
      final value = widget.decode(response.body.toJson());
      final id = response.requestId;
      if (id == null) {
        throw const ApiProtocolException('Host report has no request ID.');
      }
      final snapshot = (
        value: value,
        status: response.status,
        requestId: RequestId(id),
        receivedAt: DateTime.now().toUtc(),
      );
      if (mounted && !pending.isCancelled) {
        setState(() => _snapshot = snapshot);
      }
    } on ApiRequestCancelledException {
      // This releases a local read only; doctor and host state belong to the daemon.
    } catch (error) {
      if (mounted && !pending.isCancelled) {
        setState(() {
          _error = error is FormatException || error is ArgumentError
              ? ApiProtocolException('Invalid ${widget.title} response.')
              : error;
        });
      }
    } finally {
      if (mounted && !pending.isCancelled) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _line),
      borderRadius: BorderRadius.circular(10),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _load,
            child: Text('Refresh ${widget.title.toLowerCase()}'),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null) ...[
            _apiFailure(_error!),
            if (_snapshot != null)
              const Text(
                'Refresh failed · last validated snapshot retained.',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
          ],
          const SizedBox(height: 16),
          if (_snapshot case final snapshot?) ...[
            widget.contents(snapshot.value),
            const SizedBox(height: 16),
            Text(
              'HTTP ${snapshot.status}',
              style: const TextStyle(fontSize: 11),
            ),
            SelectableText(
              snapshot.requestId.value,
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
            Text(
              'Read at (client UTC) · ${snapshot.receivedAt.toIso8601String()}',
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ] else
            Text(_loading ? 'Reading report…' : 'No validated report'),
        ],
      ),
    ),
  );
}
