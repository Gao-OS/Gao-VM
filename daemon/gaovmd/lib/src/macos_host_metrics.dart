import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'host_scheduler.dart';
import 'host_scheduler_models.dart';
import 'image_filesystem.dart';
import 'vm_controller.dart';

/// Native admission inputs, not a reservation or a guarantee of reclaimability.
/// The caller owns [storage] and must keep it open through each sample.
final class MacOsHostMetricsSource implements HostMetricsSource {
  MacOsHostMetricsSource({
    required this.storage,
    required FutureOr<int> Function() countUnmanagedDrivers,
  }) : _countUnmanagedDrivers = countUnmanagedDrivers;

  final OwnedImageDirectory storage;
  final FutureOr<int> Function() _countUnmanagedDrivers;

  @override
  Future<HostMetrics> sample() async {
    try {
      return await _sample().timeout(const Duration(seconds: 5));
    } catch (error) {
      throw VmEffectException(
        OperationError(
          code: ErrorCode.hostResourceExhausted,
          message: 'native host capacity metrics are unavailable',
          retryable: true,
          details: JsonObjectValue.fromJson({'component': 'host_metrics'}),
        ),
        cause: error,
      );
    }
  }

  Future<HostMetrics> _sample() async {
    if (!Platform.isMacOS)
      throw UnsupportedError('macOS host metrics required');
    final results = await Future.wait<Object>([
      Isolate.run(_sampleMemory),
      storage.availableBytes(),
      Future<int>.sync(_countUnmanagedDrivers),
    ]);
    final memory = results[0] as (int, int);
    final drivers = results[2] as int;
    if (drivers < 0)
      throw ArgumentError.value(drivers, 'unmanagedDriverProcesses');
    return HostMetrics(
      logicalCpuCount: Platform.numberOfProcessors,
      totalMemoryBytes: memory.$1,
      availableMemoryBytes: memory.$2,
      freeDiskBytes: results[1] as int,
      unmanagedDriverProcesses: drivers,
    );
  }
}

(int, int) _sampleMemory() {
  final library = DynamicLibrary.process();
  final sysctl = library
      .lookupFunction<
        Int32 Function(
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<UintPtr>,
          Pointer<Void>,
          UintPtr,
        ),
        int Function(
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<UintPtr>,
          Pointer<Void>,
          int,
        )
      >('sysctlbyname');
  final hostSelf = library.lookupFunction<Uint32 Function(), int Function()>(
    'mach_host_self',
  );
  final statistics = library
      .lookupFunction<
        Int32 Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint32>),
        int Function(int, int, Pointer<Int32>, Pointer<Uint32>)
      >('host_statistics64');
  final pageSize = library.lookupFunction<Int32 Function(), int Function()>(
    'getpagesize',
  );
  final deallocate = library
      .lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>(
        'mach_port_deallocate',
      );
  final task = library.lookup<Uint32>('mach_task_self_').value;
  final name = 'hw.memsize'.toNativeUtf8();
  final total = calloc<Uint64>();
  final size = calloc<UintPtr>()..value = sizeOf<Uint64>();
  // mach/host_info.h: HOST_VM_INFO64_REV0_COUNT is 24 natural_t words.
  // Only the stable free_count and inactive_count prefix is needed here.
  const words = 24;
  final info = calloc<Uint32>(words);
  final count = calloc<Uint32>()..value = words;
  var host = 0;
  try {
    if (sysctl(name, total.cast(), size, nullptr, 0) != 0 ||
        size.value != sizeOf<Uint64>() ||
        total.value <= 0) {
      throw StateError('cannot sample hw.memsize');
    }
    host = hostSelf();
    const hostVmInfo64 = 4;
    if (host == 0 ||
        statistics(host, hostVmInfo64, info.cast(), count) != 0 ||
        count.value < 3) {
      throw StateError('cannot sample host VM statistics');
    }
    final bytesPerPage = pageSize();
    if (bytesPerPage <= 0) throw StateError('invalid native page size');
    // vm_statistics.h explicitly includes speculative pages in free_count.
    // Inactive pages are an estimate of reclaimable memory, not guaranteed free.
    final available = (info[0] + info[2]) * bytesPerPage;
    return (total.value, available.clamp(0, total.value));
  } finally {
    if (host != 0) deallocate(task, host);
    malloc.free(name);
    calloc.free(total);
    calloc.free(size);
    calloc.free(info);
    calloc.free(count);
  }
}
