import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native doctor verifies a signed ARM64 executable without running it',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'gvm-doctor-sign-',
      );
      try {
        final binary = await _compile(temporary, 'arm64', entitlement: true);
        final observed = await _host(binary.path).inspectDriver();
        expect(observed.executable, isTrue);
        expect(observed.arm64, isTrue);
        expect(
          observed.validSignature,
          isTrue,
          reason: observed.signatureMessage,
        );
        expect(
          observed.virtualizationEntitlement,
          isTrue,
          reason: observed.signatureMessage,
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'native entitlement check selects ARM64 rather than the host slice',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'gvm-doctor-fat-',
      );
      try {
        final arm = await _compile(temporary, 'arm64', entitlement: false);
        final intel = await _compile(temporary, 'x86_64', entitlement: true);
        final universal = File('${temporary.path}/universal');
        await _command('/usr/bin/lipo', [
          '-create',
          arm.path,
          intel.path,
          '-output',
          universal.path,
        ]);
        final observed = await _host(universal.path).inspectDriver();
        expect(observed.executable, isTrue);
        expect(observed.arm64, isTrue);
        expect(
          observed.validSignature,
          isTrue,
          reason: observed.signatureMessage,
        );
        expect(observed.virtualizationEntitlement, isFalse);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'native doctor rejects tampered code even when an entitlement blob remains',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'gvm-doctor-tamper-',
      );
      try {
        final binary = await _compile(temporary, 'arm64', entitlement: true);
        final file = await binary.open(mode: FileMode.append);
        try {
          await file.setPosition(1024);
          final byte = await file.readByte();
          await file.setPosition(1024);
          await file.writeByte(byte ^ 1);
        } finally {
          await file.close();
        }
        final observed = await _host(binary.path).inspectDriver();
        expect(observed.arm64, isTrue);
        expect(observed.validSignature, isFalse);
        expect(observed.virtualizationEntitlement, isFalse);
        expect(observed.signatureMessage, contains('OSStatus'));
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}

MacOsDoctorHost _host(String path) => MacOsDoctorHost(
  driverBinary: path,
  metrics: _Metrics(),
  processes: MacOsDriverInventory(executablePath: path),
);

Future<File> _compile(
  Directory directory,
  String architecture, {
  required bool entitlement,
}) async {
  final source = await File(
    '${directory.path}/fixture.c',
  ).writeAsString('int main(void) { return 0; }\n');
  final binary = File('${directory.path}/fixture-$architecture');
  await _command('/usr/bin/clang', [
    '-arch',
    architecture,
    '-o',
    binary.path,
    source.path,
  ]);
  final plist = await File('${directory.path}/entitlements-$architecture.plist')
      .writeAsString(
        '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.virtualization</key><${entitlement ? 'true' : 'false'}/></dict></plist>',
      );
  await _command('/usr/bin/codesign', [
    '--force',
    '--sign',
    '-',
    '--entitlements',
    plist.path,
    binary.path,
  ]);
  return binary;
}

Future<void> _command(String executable, List<String> arguments) async {
  final result = await Process.run(
    executable,
    arguments,
  ).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '$executable: ${result.stderr}');
}

final class _Metrics implements HostMetricsSource {
  @override
  Future<HostMetrics> sample() async =>
      throw UnsupportedError('not sampled by signing tests');
}
