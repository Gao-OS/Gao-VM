import 'common.dart';
import 'json_value.dart';
import 'resource_id.dart';

final _eventTypePattern = RegExp(r'^[a-z][a-z0-9_.-]*$');

final class Event extends ValueObject {
  Event({
    required this.sequence,
    required this.eventId,
    required this.type,
    required this.resourceType,
    this.resourceId,
    this.vmId,
    this.operationId,
    this.testRunId,
    required this.payload,
    required DateTime occurredAt,
  }) : occurredAt = occurredAt.toUtc() {
    if (sequence < 1) {
      throw ArgumentError.value(sequence, 'sequence', 'must be at least 1');
    }
    requirePattern(type, _eventTypePattern, 'type');
    if (resourceId != null && !resourceId!.matchesResourceType(resourceType)) {
      throw ArgumentError('resourceType does not match resourceId');
    }
    if (resourceType == ResourceType.system && resourceId != null) {
      throw ArgumentError('system events cannot identify a resource');
    }
  }

  factory Event.fromJson(Object? value) {
    final json = readJsonObject(value, 'Event');
    expectJsonKeys(
      json,
      required: const {
        'sequence',
        'event_id',
        'type',
        'resource_type',
        'resource_id',
        'vm_id',
        'operation_id',
        'test_run_id',
        'payload',
        'occurred_at',
      },
      optional: const {},
      name: 'Event',
    );
    final resourceId = nullableJson<String>(json, 'resource_id');
    final vmId = nullableJson<String>(json, 'vm_id');
    final operationId = nullableJson<String>(json, 'operation_id');
    final testRunId = nullableJson<String>(json, 'test_run_id');
    return Event(
      sequence: requireJson<int>(json, 'sequence'),
      eventId: EventId(requireJson<String>(json, 'event_id')),
      type: requireJson<String>(json, 'type'),
      resourceType: parseResourceType(json['resource_type']),
      resourceId: resourceId == null ? null : ResourceId.parse(resourceId),
      vmId: vmId == null ? null : VmId(vmId),
      operationId: operationId == null ? null : OperationId(operationId),
      testRunId: testRunId == null ? null : TestRunId(testRunId),
      payload: JsonObjectValue.fromJson(json['payload']),
      occurredAt: requireDateTime(json, 'occurred_at'),
    );
  }

  final int sequence;
  final EventId eventId;
  final String type;
  final ResourceType resourceType;
  final ResourceId? resourceId;
  final VmId? vmId;
  final OperationId? operationId;
  final TestRunId? testRunId;
  final JsonObjectValue payload;
  final DateTime occurredAt;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'event_id': eventId.value,
    'type': type,
    'resource_type': resourceTypeToJson(resourceType),
    'resource_id': resourceId?.value,
    'vm_id': vmId?.value,
    'operation_id': operationId?.value,
    'test_run_id': testRunId?.value,
    'payload': payload.toJson(),
    'occurred_at': formatDateTime(occurredAt),
  };

  @override
  List<Object?> get equalityFields => [
    sequence,
    eventId,
    type,
    resourceType,
    resourceId,
    vmId,
    operationId,
    testRunId,
    payload,
    occurredAt,
  ];
}
