import 'dart:async';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'durable_event_feed.dart';
import 'sqlite_database.dart';

/// Reads committed journal pages, independent of any subscriber's speed.
/// Idle subscriptions use a safety timer to observe commits from other
/// connections/processes. A paused subscription retains at most one page and
/// performs no further reads until resumed. Cancellation stops its timer.
final class SqliteDurableEventFeed implements DurableEventFeed {
  SqliteDurableEventFeed(
    this._database, {
    this.pollInterval = const Duration(milliseconds: 250),
    this.pageSize = 100,
  }) {
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(pollInterval, 'pollInterval');
    }
    if (pageSize < 1 || pageSize > 1000) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
  }

  final GaoVmDatabase _database;
  final Duration pollInterval;
  final int pageSize;

  void _requireCommittedReader() {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('durable event subscriptions cannot join a transaction');
    }
  }

  @override
  Future<int> latestSequence() {
    _requireCommittedReader();
    return _database.read(
      (db) =>
          db
                  .select(
                    'SELECT COALESCE(MAX(sequence), 0) AS sequence FROM events',
                  )
                  .single['sequence']
              as int,
    );
  }

  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) {
    _requireCommittedReader();
    if (after < 0) throw ArgumentError.value(after, 'after');
    final predicates = <String>['sequence > ?'];
    final filters = <Object?>[];
    for (final filter in <String, ResourceId?>{
      'vm_id': vmId,
      'operation_id': operationId,
      'test_run_id': testRunId,
    }.entries) {
      if (filter.value != null) {
        predicates.add('${filter.key} = ?');
        filters.add(filter.value!.value);
      }
    }
    final sql =
        'SELECT * FROM events WHERE ${predicates.join(' AND ')} '
        'ORDER BY sequence LIMIT ?';
    var cursor = after;
    var cancelled = false;
    var reading = false;
    var pending = <Event>[];
    var index = 0;
    Timer? timer;
    late StreamController<Event> controller;

    Future<void> pump() async {
      if (cancelled || reading || controller.isPaused) return;
      reading = true;
      var empty = false;
      try {
        _requireCommittedReader();
        if (index == pending.length) {
          pending = await _database.read(
            (db) => [
              for (final row in db.select(sql, [cursor, ...filters, pageSize]))
                Event.fromJson({
                  'sequence': row['sequence'],
                  'event_id': row['id'],
                  'type': row['type'],
                  'resource_type': row['resource_type'],
                  'resource_id': row['resource_id'],
                  'vm_id': row['vm_id'],
                  'operation_id': row['operation_id'],
                  'test_run_id': row['test_run_id'],
                  'payload': jsonDecode(row['payload_json'] as String),
                  'occurred_at': row['occurred_at'],
                }),
            ],
          );
          index = 0;
        }
        empty = pending.isEmpty;
        while (!cancelled && !controller.isPaused && index < pending.length) {
          final event = pending[index++];
          cursor = event.sequence;
          controller.add(event);
        }
      } catch (error, stack) {
        if (!cancelled) {
          cancelled = true;
          controller.addError(error, stack);
          unawaited(controller.close());
        }
      } finally {
        reading = false;
        if (!cancelled && !controller.isPaused) {
          timer = Timer(empty ? pollInterval : Duration.zero, pump);
        }
      }
    }

    controller = StreamController<Event>(
      sync: true,
      onListen: pump,
      onPause: () => timer?.cancel(),
      onResume: pump,
      onCancel: () {
        cancelled = true;
        timer?.cancel();
        pending = [];
      },
    );
    return controller.stream;
  }
}
