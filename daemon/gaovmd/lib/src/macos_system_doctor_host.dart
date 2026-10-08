import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'host_scheduler.dart';
import 'host_scheduler_models.dart';
import 'macos_driver_inventory.dart';
import 'system_doctor_host.dart';

/// Native observations run off the control isolate. Driver code is never run.
final class MacOsDoctorHost implements DoctorHost {
  MacOsDoctorHost({
    required this.driverBinary,
    required this.metrics,
    required this.processes,
  }) {
    if (!driverBinary.startsWith('/'))
      throw ArgumentError.value(driverBinary, 'driverBinary');
  }
  final String driverBinary;
  final HostMetricsSource metrics;
  final MacOsDriverInventory processes;

  @override
  Future<DoctorPlatformObservation> inspectPlatform() => Isolate.run(_platform);

  @override
  Future<DoctorDriverObservation> inspectDriver() {
    final path = driverBinary;
    return Isolate.run(() => _driver(path));
  }

  @override
  Future<HostMetrics> sampleResources() => metrics.sample();

  @override
  Future<DriverInventorySnapshot> inventory() => processes.snapshot();
}

DoctorPlatformObservation _platform() {
  if (!Platform.isMacOS)
    return (macOS: false, appleSilicon: false, majorVersion: 0);
  final sysctl = DynamicLibrary.process()
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
  final versionName = 'kern.osproductversion'.toNativeUtf8();
  final armName = 'hw.optional.arm64'.toNativeUtf8();
  final version = calloc<Uint8>(256);
  final arm = calloc<Int32>();
  final size = calloc<UintPtr>();
  try {
    size.value = 256;
    if (sysctl(versionName, version.cast(), size, nullptr, 0) != 0 ||
        size.value < 2 ||
        size.value > 256) {
      throw StateError('macOS product version is unavailable');
    }
    final text = utf8.decode(
      version.asTypedList(size.value).takeWhile((byte) => byte != 0).toList(),
    );
    final major = int.tryParse(text.split('.').first);
    if (major == null)
      throw const FormatException('invalid macOS product version');
    size.value = sizeOf<Int32>();
    final armResult = sysctl(armName, arm.cast(), size, nullptr, 0);
    return (
      macOS: true,
      appleSilicon:
          armResult == 0 && size.value == sizeOf<Int32>() && arm.value == 1,
      majorVersion: major,
    );
  } finally {
    malloc.free(versionName);
    malloc.free(armName);
    calloc.free(version);
    calloc.free(arm);
    calloc.free(size);
  }
}

Future<DoctorDriverObservation> _driver(String binary) async {
  if (!Platform.isMacOS)
    return _unavailable('macOS static signing inspection is required.');
  try {
    final path = await File(binary).resolveSymbolicLinks();
    final file = File(path);
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file || !_executable(path)) {
      return _unavailable('Driver is not an accessible executable file.');
    }
    final input = await file.open();
    final bool arm64;
    try {
      arm64 = await _hasArm64Executable(input);
    } finally {
      await input.close();
    }
    if (!arm64)
      return (
        executable: true,
        arm64: false,
        validSignature: false,
        virtualizationEntitlement: false,
        signatureMessage:
            'Driver does not contain an ARM64 Mach-O executable slice.',
      );
    final signing = _signing(path);
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.mode != after.mode) {
      return _unavailable(
        'Driver changed during static inspection; retry after publication finishes.',
      );
    }
    return (
      executable: true,
      arm64: true,
      validSignature: signing.valid,
      virtualizationEntitlement: signing.entitlement,
      signatureMessage: signing.message,
    );
  } on FileSystemException {
    return _unavailable('Driver file could not be read or resolved.');
  }
}

DoctorDriverObservation _unavailable(String message) => (
  executable: false,
  arm64: false,
  validSignature: false,
  virtualizationEntitlement: false,
  signatureMessage: message,
);

bool _executable(String path) {
  final access = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('access');
  final name = path.toNativeUtf8();
  try {
    return access(name, 1) == 0;
  } finally {
    malloc.free(name);
  }
}

Future<bool> _hasArm64Executable(RandomAccessFile file) async {
  final header = await file.read(32);
  if (_arm64Header(header)) return true;
  if (header.length < 8) return false;
  final data = ByteData.sublistView(header);
  final magic = data.getUint32(0, Endian.big);
  final Endian endian;
  final bool wide;
  switch (magic) {
    case 0xcafebabe:
      endian = Endian.big;
      wide = false;
    case 0xbebafeca:
      endian = Endian.little;
      wide = false;
    case 0xcafebabf:
      endian = Endian.big;
      wide = true;
    case 0xbfbafeca:
      endian = Endian.little;
      wide = true;
    default:
      return false;
  }
  final count = data.getUint32(4, endian), stride = wide ? 32 : 20;
  if (count == 0 || count > 64) return false;
  await file.setPosition(8);
  final bytes = await file.read(count * stride);
  if (bytes.length != count * stride) return false;
  final architectures = ByteData.sublistView(bytes);
  final length = await file.length();
  for (var index = 0; index < count; index++) {
    final entry = index * stride;
    if (architectures.getUint32(entry, endian) != 0x0100000c) continue;
    final offset = wide
        ? architectures.getUint64(entry + 8, endian)
        : architectures.getUint32(entry + 8, endian);
    if (offset < 8 + count * stride || offset > length - 32) return false;
    await file.setPosition(offset);
    if (_arm64Header(await file.read(32))) return true;
  }
  return false;
}

bool _arm64Header(Uint8List bytes) {
  if (bytes.length < 32) return false;
  final data = ByteData.sublistView(bytes);
  final magic = data.getUint32(0, Endian.little);
  final endian = magic == 0xfeedfacf
      ? Endian.little
      : magic == 0xcffaedfe
      ? Endian.big
      : null;
  return endian != null &&
      data.getUint32(4, endian) == 0x0100000c &&
      data.getUint32(12, endian) == 2;
}

// Security.framework static-code validation is an observation, never launch
// authorization. Validate all signatures, but read the target ARM64 entitlement,
// not the host's preferred slice (which may differ under Intel/Rosetta).
({bool valid, bool entitlement, String message}) _signing(String path) {
  final security = DynamicLibrary.open(
    '/System/Library/Frameworks/Security.framework/Security',
  );
  final core = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  final release = core
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  final createString = core
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
      >('CFStringCreateWithCString');
  final createUrl = core
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Uint8),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('CFURLCreateFromFileSystemRepresentation');
  final createDictionary = core
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          IntPtr,
          Pointer<Void>,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('CFDictionaryCreate');
  final dictionaryValue = core
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      >('CFDictionaryGetValue');
  final typeId = core
      .lookupFunction<
        UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFGetTypeID');
  final dictionaryType = core
      .lookupFunction<UintPtr Function(), int Function()>(
        'CFDictionaryGetTypeID',
      );
  final booleanType = core.lookupFunction<UintPtr Function(), int Function()>(
    'CFBooleanGetTypeID',
  );
  final booleanValue = core
      .lookupFunction<
        Uint8 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFBooleanGetValue');
  final createCode = security
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Void>>)
      >('SecStaticCodeCreateWithPathAndAttributes');
  final validate = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('SecStaticCodeCheckValidity');
  final information = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('SecCodeCopySigningInformation');
  final nativePath = path.toNativeUtf8(), armText = 'arm64'.toNativeUtf8();
  final entitlementText = 'com.apple.security.virtualization'.toNativeUtf8();
  final keys = calloc<Pointer<Void>>(1), values = calloc<Pointer<Void>>(1);
  final code = calloc<Pointer<Void>>(), info = calloc<Pointer<Void>>();
  final owned = <Pointer<Void>>[];
  Pointer<Void> own(Pointer<Void> value) {
    if (value == nullptr) throw StateError('CoreFoundation allocation failed');
    owned.add(value);
    return value;
  }

  ({bool valid, bool entitlement, String message}) failure(
    String step,
    int status,
  ) => (
    valid: false,
    entitlement: false,
    message:
        '$step failed (OSStatus=$status). Static ARM64 signing/entitlement proof is unavailable.',
  );
  try {
    final url = own(
      createUrl(nullptr, nativePath.cast(), utf8.encode(path).length, 0),
    );
    keys.value = security
        .lookup<Pointer<Void>>('kSecCodeAttributeArchitecture')
        .value;
    values.value = own(createString(nullptr, armText, 0x08000100));
    // NULL callbacks borrow these keys/values; keep their owners until release.
    final attributes = own(
      createDictionary(nullptr, keys, values, 1, nullptr, nullptr),
    );
    final created = createCode(url, 0, attributes, code);
    if (code.value != nullptr) own(code.value);
    if (created != 0) return failure('Static code lookup', created);
    const checkAllArchitectures = 1 << 0, strictValidate = 1 << 4;
    final verified = validate(
      code.value,
      checkAllArchitectures | strictValidate,
      nullptr,
    );
    if (verified != 0) return failure('Signature validation', verified);
    final copied = information(code.value, 1 << 1, info);
    if (info.value != nullptr) own(info.value);
    if (copied != 0) return failure('Signing information', copied);
    final entitlements = dictionaryValue(
      info.value,
      security.lookup<Pointer<Void>>('kSecCodeInfoEntitlementsDict').value,
    );
    var entitled = false;
    if (entitlements != nullptr && typeId(entitlements) == dictionaryType()) {
      final key = own(createString(nullptr, entitlementText, 0x08000100));
      final value = dictionaryValue(entitlements, key);
      entitled =
          value != nullptr &&
          typeId(value) == booleanType() &&
          booleanValue(value) != 0;
    }
    return (
      valid: true,
      entitlement: entitled,
      message: entitled
          ? 'ARM64 static signature and virtualization entitlement verified.'
          : 'Signature is valid but the ARM64 com.apple.security.virtualization boolean entitlement is absent or false.',
    );
  } finally {
    for (final value in owned.reversed) {
      release(value);
    }
    malloc.free(nativePath);
    malloc.free(armText);
    malloc.free(entitlementText);
    calloc.free(keys);
    calloc.free(values);
    calloc.free(code);
    calloc.free(info);
    security.close();
    core.close();
  }
}
