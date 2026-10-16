import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'macos_driver_inventory.dart';
import 'maintenance_command.dart';

/// A private, one-launch stdin handshake, not an ordinary startup permission.
/// Only its digest is persisted. Never include the nonce in arguments or logs.
final class ValidationLaunchGrant {
  ValidationLaunchGrant({required this.nonce, required this.process}) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(nonce) ||
        process.pid <= 0 ||
        process.pid > 0x7fffffff ||
        process.uid < 0 ||
        process.uid > 0xffffffff ||
        process.startedAtMicroseconds <= 0 ||
        process.pidVersion == null ||
        process.pidVersion! < 0 ||
        process.pidVersion! > 0xffffffff ||
        !process.executablePath.startsWith('/')) {
      throw const FormatException('invalid private validation launch grant');
    }
  }
  final String nonce;
  final DriverProcessIdentity process;
  Map<String, Object?> get processJson => {
    'pid': process.pid,
    'uid': process.uid,
    'executable_path': process.executablePath,
    'started_at_microseconds': process.startedAtMicroseconds,
    'pid_version': process.pidVersion,
  };
  Map<String, Object?> toJson() => {
    'format': 'gaovm.validation-launch-grant.v1',
    'nonce': nonce,
    'process': processJson,
  };
  String get digest =>
      'sha256:${sha256.convert(utf8.encode('${jsonEncode(toJson())}\n'))}';

  void verifyProcess(Object? actual) {
    if (JsonValue.fromJson(actual) != JsonValue.fromJson(processJson)) {
      throw const FormatException('validation launch process binding changed');
    }
  }

  factory ValidationLaunchGrant.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value.length != 3 ||
        value['format'] != 'gaovm.validation-launch-grant.v1' ||
        value['nonce'] is! String ||
        value['process'] is! Map<String, Object?>) {
      throw const FormatException('invalid private validation launch grant');
    }
    final process = value['process'] as Map<String, Object?>;
    if (process.length != 5 ||
        process['pid'] is! int ||
        process['uid'] is! int ||
        process['executable_path'] is! String ||
        process['started_at_microseconds'] is! int ||
        process['pid_version'] is! int) {
      throw const FormatException('invalid private validation launch grant');
    }
    return ValidationLaunchGrant(
      nonce: value['nonce'] as String,
      process: DriverProcessIdentity(
        pid: process['pid'] as int,
        uid: process['uid'] as int,
        executablePath: process['executable_path'] as String,
        startedAtMicroseconds: process['started_at_microseconds'] as int,
        pidVersion: process['pid_version'] as int,
      ),
    );
  }
}

Future<ValidationLaunchGrant> readValidationLaunchGrant(
  Stream<List<int>> input,
) async {
  final bytes = BytesBuilder(copy: false);
  var exceeded = false;
  await for (final chunk in input) {
    if (exceeded || bytes.length + chunk.length > 8192) {
      exceeded = true;
    } else {
      bytes.add(chunk);
    }
  }
  try {
    if (exceeded) throw const FormatException();
    return ValidationLaunchGrant.fromJson(
      jsonDecode(utf8.decode(bytes.takeBytes())),
    );
  } on FormatException {
    // JSON decoder errors can contain input, including the private nonce.
    throw const FormatException('invalid private validation launch grant');
  }
}

final class OwnedCandidateValidationResult {
  const OwnedCandidateValidationResult(this.result, this.grant);
  final ProcessResult result;
  final ValidationLaunchGrant grant;
}

typedef CandidateValidationLauncher =
    Future<OwnedCandidateValidationResult> Function(
      String executable,
      List<String> arguments,
      String nonce,
    );

/// Wait for this original child and drain both pipes, including on failure.
/// Unlike short native probes, controlled migration has no observation timeout.
Future<OwnedCandidateValidationResult> launchOwnedCandidateValidation(
  String executable,
  List<String> arguments,
  String nonce, {
  Future<DriverProcessIdentity?> Function(int)? inspect,
}) async {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(nonce)) {
    throw const FormatException('invalid private validation launch grant');
  }
  final child = await Process.start(
    executable,
    arguments,
    includeParentEnvironment: false,
    environment: const {'PATH': '/usr/bin:/bin'},
  );
  final exit = child.exitCode;
  final output = _ValidationOutput(64 * 1024 * 1024);
  final errors = _ValidationOutput(16384);
  final drained = Future.wait([
    output.drain(child.stdout),
    errors.drain(child.stderr),
  ]);
  ValidationLaunchGrant? grant;
  var refused = false;
  try {
    final identity =
        await (inspect ??
            MacOsDriverInventory(
              executablePath: executable,
            ).inspectForMaintenance)(child.pid);
    if (identity == null ||
        identity.pid != child.pid ||
        identity.executablePath != executable) {
      throw const FormatException(
        'owned validation child identity unavailable',
      );
    }
    grant = ValidationLaunchGrant(nonce: nonce, process: identity);
    child.stdin.add(utf8.encode('${jsonEncode(grant.toJson())}\n'));
    await child.stdin.flush();
  } catch (_) {
    refused = true;
  } finally {
    try {
      await child.stdin.close();
    } catch (_) {
      refused = true;
    }
  }
  final code = await exit;
  await drained;
  if (refused || output.failed || errors.failed) {
    throw MaintenanceCommandFailure(
      'validation launch or bounded output failed; retain all inputs',
      child.pid,
      exitConfirmed: true,
    );
  }
  try {
    return OwnedCandidateValidationResult(
      ProcessResult(
        child.pid,
        code,
        utf8.decode(output.bytes.takeBytes()),
        utf8.decode(errors.bytes.takeBytes()),
      ),
      grant!,
    );
  } on FormatException {
    throw MaintenanceCommandFailure(
      'invalid validation child output; retain all inputs',
      child.pid,
      exitConfirmed: true,
    );
  }
}

final class _ValidationOutput {
  _ValidationOutput(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  var failed = false;
  Future<void> drain(Stream<List<int>> stream) async {
    try {
      await for (final chunk in stream) {
        if (failed || bytes.length + chunk.length > limit) {
          failed = true;
        } else {
          bytes.add(chunk);
        }
      }
    } catch (_) {
      failed = true;
    }
  }
}

/// Additional constraints when recovering immediately after our owned launch.
/// These narrow sealed recovery; they never confer state/fence ownership.
final class ValidationLaunchExpectation {
  const ValidationLaunchExpectation({
    required this.grant,
    required this.preparationDigest,
    required this.publication,
    required this.record,
  });
  final ValidationLaunchGrant grant;
  final String preparationDigest;
  final Map<String, Object?> publication, record;

  void verify(Map<String, Object?> intent, Map<String, Object?> sealed) {
    final actualPublication = intent['publication'];
    if (actualPublication is! Map<String, Object?>) {
      throw const FormatException('validation launch publication unavailable');
    }
    final stable = Map<String, Object?>.from(actualPublication);
    grant.verifyProcess(stable.remove('executing_process'));
    if (intent['format'] != 'gaovm.candidate-validation-intent.v3' ||
        intent['launch_grant_digest'] != grant.digest ||
        intent['preparation_digest'] != preparationDigest ||
        JsonValue.fromJson(stable) != JsonValue.fromJson(publication) ||
        JsonValue.fromJson(sealed) != JsonValue.fromJson(record)) {
      throw const FormatException(
        'sealed validation does not match owned launch',
      );
    }
  }
}
