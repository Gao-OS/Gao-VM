import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// A read-only observation, never authorization to signal a PID later.
final class DriverProcessIdentity {
  const DriverProcessIdentity({
    required this.pid,
    required this.uid,
    required this.executablePath,
    required this.startedAtMicroseconds,
    this.pidVersion,
  });

  final int pid;
  final int uid;
  final String executablePath;
  final int startedAtMicroseconds;
  final int? pidVersion;

  @override
  bool operator ==(Object other) =>
      other is DriverProcessIdentity &&
      pid == other.pid &&
      uid == other.uid &&
      executablePath == other.executablePath &&
      pidVersion == other.pidVersion &&
      startedAtMicroseconds == other.startedAtMicroseconds;

  @override
  int get hashCode =>
      Object.hash(pid, uid, executablePath, startedAtMicroseconds, pidVersion);
}

final class DriverInventorySnapshot {
  DriverInventorySnapshot({
    required Iterable<DriverProcessIdentity> processes,
    required Iterable<int> unresolvedProcessIds,
  }) : processes = List.unmodifiable(processes),
       unresolvedProcessIds = List.unmodifiable(unresolvedProcessIds);

  final List<DriverProcessIdentity> processes;
  final List<int> unresolvedProcessIds;

  /// Unknown executables might be drivers. Never turn them into spare capacity.
  int countUnmanaged(Set<DriverProcessIdentity> managed) {
    if (unresolvedProcessIds.isNotEmpty) {
      throw StateError('process inventory contains unresolved executables');
    }
    return processes.where((process) => !managed.contains(process)).length;
  }
}

/// Same-effective-user processes matching an exact, caller-canonicalized binary.
/// No basename matching, command-line inspection, or process mutation occurs.
final class MacOsDriverInventory {
  MacOsDriverInventory({required this.executablePath}) {
    if (!executablePath.startsWith('/')) {
      throw ArgumentError.value(executablePath, 'executablePath');
    }
  }

  final String executablePath;

  Future<DriverInventorySnapshot> snapshot() async {
    if (!Platform.isMacOS) throw UnsupportedError('macOS inventory required');
    final path = executablePath;
    return Isolate.run(
      () => _snapshot(path),
    ).timeout(const Duration(seconds: 5));
  }

  /// Returns null for an exited process or a different executable/user.
  /// Inspection errors are not evidence that a process is absent.
  Future<DriverProcessIdentity?> inspect(int pid) async {
    if (pid <= 0 || pid > 0x7fffffff) throw ArgumentError.value(pid, 'pid');
    if (!Platform.isMacOS) throw UnsupportedError('macOS inventory required');
    final path = executablePath;
    return Isolate.run(
      () => _inspect(path, pid),
    ).timeout(const Duration(seconds: 5));
  }
}

/// Caller must establish generation ownership before invoking this primitive.
/// A successful signal is not confirmation that the process has exited.
final class MacOsDriverSignaler {
  static Future<bool> signal(
    DriverProcessIdentity identity,
    ProcessSignal signal,
  ) async {
    if (!Platform.isMacOS) throw UnsupportedError('macOS signaling required');
    if (identity.pid <= 0 ||
        identity.pid > 0x7fffffff ||
        identity.pidVersion == null ||
        identity.pidVersion! < 0 ||
        identity.pidVersion! > 0xffffffff ||
        (signal != ProcessSignal.sigterm && signal != ProcessSignal.sigkill)) {
      throw ArgumentError('versioned process identity and TERM/KILL required');
    }
    // Do not time out and abandon this mutating work: the caller retains its
    // ownership until the native operation has actually settled.
    return Isolate.run(() {
      if (_inspect(identity.executablePath, identity.pid) != identity)
        return false;
      final nativeSignal = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Uint32>, Int32),
            int Function(Pointer<Uint32>, int)
          >('proc_signal_with_audittoken');
      final token = calloc<Uint32>(8);
      try {
        // Audit token PID and pidversion slots, as used by Apple's libproc tests.
        token[5] = identity.pid;
        token[7] = identity.pidVersion!;
        final error = nativeSignal(token, signal.signalNumber);
        if (error == 3) return false; // ESRCH: target version no longer exists.
        if (error != 0)
          throw OSError('versioned process signaling failed', error);
        return true;
      } finally {
        calloc.free(token);
      }
    });
  }
}

enum DriverExitObservation { exited, timedOut, identityChanged }

final class MacOsDriverExit {
  /// Uses a native process-exit event, not pathname absence or a polling sleep.
  static Future<DriverExitObservation> waitForExit(
    DriverProcessIdentity identity,
    Duration timeout,
  ) async {
    if (!Platform.isMacOS)
      throw UnsupportedError('macOS exit observation required');
    if (identity.pid <= 0 ||
        identity.pid > 0x7fffffff ||
        identity.pidVersion == null ||
        identity.pidVersion! < 0 ||
        identity.pidVersion! > 0xffffffff ||
        timeout <= Duration.zero) {
      throw ArgumentError(
        'versioned process identity and positive timeout required',
      );
    }
    return Isolate.run(() => _waitForExit(identity, timeout));
  }
}

// sys/event.h: kevent64_s, independent of the packed legacy kevent structure.
final class _ProcessEvent extends Struct {
  @Uint64()
  external int ident;
  @Int16()
  external int filter;
  @Uint16()
  external int flags;
  @Uint32()
  external int notes;
  @Int64()
  external int data;
  @Uint64()
  external int userData;
  @Array(2)
  external Array<Uint64> extension;
}

final class _EventTimeout extends Struct {
  @Int64()
  external int seconds;
  @Int64()
  external int nanoseconds;
}

DriverExitObservation _waitForExit(
  DriverProcessIdentity identity,
  Duration timeout,
) {
  final elapsed = Stopwatch()..start();
  final library = DynamicLibrary.process();
  final queue = library.lookupFunction<Int32 Function(), int Function()>(
    'kqueue',
  );
  final close = library
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  final fcntl = library
      .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  final event = library
      .lookupFunction<
        Int32 Function(
          Int32,
          Pointer<_ProcessEvent>,
          Int32,
          Pointer<_ProcessEvent>,
          Int32,
          Uint32,
          Pointer<_EventTimeout>,
        ),
        int Function(
          int,
          Pointer<_ProcessEvent>,
          int,
          Pointer<_ProcessEvent>,
          int,
          int,
          Pointer<_EventTimeout>,
        )
      >('kevent64');
  final errno = library
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  final fd = queue();
  if (fd < 0) throw OSError('cannot create process exit queue', errno().value);
  final change = calloc<_ProcessEvent>();
  final result = calloc<_ProcessEvent>();
  final limit = calloc<_EventTimeout>();
  DriverExitObservation readEvent(int microseconds) {
    while (true) {
      final remaining = microseconds == 0
          ? 0
          : timeout.inMicroseconds - elapsed.elapsedMicroseconds;
      if (microseconds != 0 && remaining <= 0)
        return DriverExitObservation.timedOut;
      limit.ref.seconds = remaining ~/ 1000000;
      limit.ref.nanoseconds = (remaining % 1000000) * 1000;
      final count = event(fd, nullptr, 0, result, 1, 0, limit);
      if (count == 0) return DriverExitObservation.timedOut;
      if (count < 0) {
        final error = errno().value;
        if (error == 4) {
          if (elapsed.elapsed >= timeout) return DriverExitObservation.timedOut;
          continue; // EINTR, retaining the original deadline.
        }
        throw OSError('process exit wait failed', error);
      }
      if (result.ref.flags & 0x4000 != 0) {
        throw OSError('process exit event failed', result.ref.data);
      }
      if (result.ref.ident != identity.pid ||
          result.ref.filter != -5 ||
          result.ref.notes & 0x80000000 == 0) {
        throw StateError('unexpected process exit event');
      }
      return DriverExitObservation.exited;
    }
  }

  try {
    if (fcntl(fd, 2, 1) != 0)
      throw OSError('cannot protect exit queue descriptor', errno().value);
    change.ref.ident = identity.pid;
    change.ref.filter = -5; // EVFILT_PROC
    change.ref.flags = 0x1 | 0x10; // EV_ADD | EV_ONESHOT
    change.ref.notes = 0x80000000; // NOTE_EXIT
    while (event(fd, change, 1, nullptr, 0, 0, limit) < 0) {
      final error = errno().value;
      if (error == 3) return DriverExitObservation.exited; // ESRCH: absent PID.
      if (error == 4) {
        if (elapsed.elapsed >= timeout) return DriverExitObservation.timedOut;
        continue;
      }
      throw OSError('cannot register process exit event', error);
    }
    // Bind the registered process to the expected identity before trusting its
    // later exit event. A process that vanished during this read may already
    // have queued NOTE_EXIT; other mismatches remain unresolved.
    final observed = _inspect(identity.executablePath, identity.pid);
    if (observed != identity) {
      if (observed == null && readEvent(0) == DriverExitObservation.exited) {
        return DriverExitObservation.exited;
      }
      return DriverExitObservation.identityChanged;
    }
    return readEvent(timeout.inMicroseconds);
  } finally {
    close(fd);
    calloc.free(change);
    calloc.free(result);
    calloc.free(limit);
  }
}

DriverInventorySnapshot _snapshot(String executable) {
  final library = DynamicLibrary.process();
  final list = library
      .lookupFunction<
        Int32 Function(Uint32, Uint32, Pointer<Void>, Int32),
        int Function(int, int, Pointer<Void>, int)
      >('proc_listpids');
  final uid = library.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  )();
  const uidOnly = 4;
  final requiredBytes = list(uidOnly, uid, nullptr, 0);
  if (requiredBytes <= 0) throw StateError('cannot size process inventory');
  final capacity = requiredBytes + 4096;
  final pids = calloc<Int32>((capacity + 3) ~/ 4);
  try {
    final bytes = list(uidOnly, uid, pids.cast(), capacity);
    if (bytes <= 0 || bytes >= capacity || bytes % 4 != 0) {
      throw StateError('process inventory unavailable or truncated');
    }
    final processes = <DriverProcessIdentity>[];
    final unresolved = <int>{};
    final seen = <int>{};
    for (var index = 0; index < bytes ~/ 4; index++) {
      final pid = pids[index];
      if (pid <= 0 || !seen.add(pid)) continue;
      try {
        final identity = _inspect(executable, pid);
        if (identity != null) processes.add(identity);
      } on OSError {
        unresolved.add(pid);
      } on StateError {
        unresolved.add(pid);
      }
    }
    return DriverInventorySnapshot(
      processes: processes,
      unresolvedProcessIds: unresolved,
    );
  } finally {
    calloc.free(pids);
  }
}

// libproc.h / sys/proc_info.h, proc_bsdinfo. MAXCOMLEN is 16.
final class _BsdInfo extends Struct {
  @Array(12)
  external Array<Uint32> header;
  @Array(48)
  external Array<Uint8> names;
  @Array(6)
  external Array<Uint32> accounting;
  @Uint64()
  external int seconds;
  @Uint64()
  external int microseconds;
}

DriverProcessIdentity? _inspect(String executable, int pid) {
  final library = DynamicLibrary.process();
  final info = library
      .lookupFunction<
        Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
        int Function(int, int, int, Pointer<Void>, int)
      >('proc_pidinfo');
  final path = library
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('proc_pidpath');
  final uid = library.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  )();
  final errno = library
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  Never fail(String call) => throw OSError('$call failed', errno().value);
  final before = calloc<_BsdInfo>();
  final after = calloc<_BsdInfo>();
  final buffer = calloc<Uint8>(4096);
  // XNU proc_info_private.h: PROC_PIDUNIQIDENTIFIERINFO (17), 56 bytes;
  // p_idversion is the 32-bit field at byte offset 32.
  final unique = calloc<Uint64>(7);
  int? readVersion() {
    final count = info(pid, 17, 0, unique.cast(), 56);
    if (count == 56) return unique.cast<Uint32>()[8];
    if (count <= 0 && errno().value == 3) return null;
    fail('proc_pidinfo identity version');
  }

  int? version;
  bool read(int pid, Pointer<_BsdInfo> target) {
    final count = info(pid, 3, 0, target.cast(), sizeOf<_BsdInfo>());
    if (count == sizeOf<_BsdInfo>()) return true;
    if (count <= 0 && errno().value == 3) return false; // ESRCH
    fail('proc_pidinfo');
  }

  DriverProcessIdentity identity(int pid, _BsdInfo value, String binary) =>
      DriverProcessIdentity(
        pid: pid,
        uid: value.header[5],
        executablePath: binary,
        startedAtMicroseconds: value.seconds * 1000000 + value.microseconds,
        pidVersion: version,
      );
  try {
    version = readVersion();
    if (version == null) return null;
    if (!read(pid, before)) return null;
    if (before.ref.header[5] != uid) return null;
    if (before.ref.header[1] == 5) return null; // SZOMB: no live runtime.
    final length = path(pid, buffer.cast(), 4096);
    if (length <= 0) {
      if (errno().value == 3) return null;
      final pathError = errno().value;
      if (!read(pid, after) || after.ref.header[1] == 5) return null;
      throw OSError('proc_pidpath failed for PID $pid', pathError);
    }
    final binary = buffer.cast<Utf8>().toDartString(length: length);
    if (binary != executable) return null;
    final candidate = identity(pid, before.ref, binary);
    if (!read(pid, after) || after.ref.header[1] == 5) return null;
    if (candidate != identity(pid, after.ref, binary)) {
      throw StateError('process identity changed during inventory');
    }
    final finalVersion = readVersion();
    if (finalVersion == null) return null;
    if (finalVersion != version) {
      throw StateError('process PID version changed during inventory');
    }
    return candidate;
  } finally {
    calloc.free(before);
    calloc.free(after);
    calloc.free(buffer);
    calloc.free(unique);
  }
}
