import 'package:crypto/crypto.dart';

import 'image_filesystem.dart';

typedef ManagedDiskClone =
    Future<bool> Function(
      OwnedImageFile source,
      OwnedImageDirectory destination,
      String name,
    );

final class ManagedDiskCancelled implements Exception {
  const ManagedDiskCancelled();
}

final class ManagedDiskInsufficientSpace implements Exception {
  const ManagedDiskInsufficientSpace(this.requiredBytes);
  final int requiredBytes;
}

final class ManagedDiskMaterialization {
  const ManagedDiskMaterialization({required this.bytes, required this.cloned});
  final int bytes;
  final bool cloned;
}

/// Materializes one new disk inside the caller's private staging namespace.
/// The caller owns/serializes that namespace and keeps both descriptors open
/// until completion. This never publishes a VM bundle or completes an Operation.
/// Capacity is a preflight, not a reservation: the bundle worker must coordinate
/// concurrent reservations, and actual write failures still clean this child.
final class ManagedDiskMaterializer {
  ManagedDiskMaterializer({
    ManagedDiskClone? clone,
    Future<int> Function(OwnedImageDirectory)? availableBytes,
  }) : _clone = clone ?? _nativeClone,
       _availableBytes = availableBytes ?? _diskAvailableBytes;

  final ManagedDiskClone _clone;
  final Future<int> Function(OwnedImageDirectory) _availableBytes;
  static const _headroom = 1024 * 1024;

  Future<ManagedDiskMaterialization> materialize({
    required OwnedImageFile source,
    required OwnedImageDirectory destination,
    required String name,
    required int expectedSize,
    required String expectedDigest,
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) async {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\x00'))
      throw ArgumentError.value(name, 'name');
    if (expectedSize < 1 || expectedSize > 0x7fffffffffffffff - _headroom) {
      throw ArgumentError.value(expectedSize, 'expectedSize');
    }
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(expectedDigest)) {
      throw ArgumentError.value(expectedDigest, 'expectedDigest');
    }
    _checkCancelled(isCancelled);
    if (source.size != expectedSize) {
      throw const FormatException(
        'managed image size differs from pinned manifest',
      );
    }
    final requiredBytes = expectedSize + _headroom;
    if (await _availableBytes(destination) < requiredBytes) {
      throw ManagedDiskInsufficientSpace(requiredBytes);
    }
    _checkCancelled(isCancelled);
    var created = false;
    try {
      final cloned = await _clone(source, destination, name);
      if (cloned) {
        created = true;
      } else {
        final output = destination.createFile(name);
        created = true;
        try {
          final writer = await output.openWrite();
          try {
            var copied = 0;
            await for (final chunk in source.openRead()) {
              _checkCancelled(isCancelled);
              if (copied + chunk.length > expectedSize) {
                throw const FormatException('managed image grew while copying');
              }
              await writer.writeFrom(chunk);
              copied += chunk.length;
              onProgress?.call(copied);
            }
            if (copied != expectedSize) {
              throw const FormatException('managed image shrank while copying');
            }
            _checkCancelled(isCancelled);
            await writer.flush();
          } finally {
            await writer.close();
          }
        } finally {
          output.close();
        }
      }
      _checkCancelled(isCancelled);
      final materialized = destination.file(name);
      try {
        if (materialized.size != expectedSize) {
          throw const FormatException('materialized disk size mismatch');
        }
        var verified = 0;
        final digest = await sha256
            .bind(
              materialized.openRead().map((chunk) {
                _checkCancelled(isCancelled);
                verified += chunk.length;
                if (verified > expectedSize) {
                  throw const FormatException(
                    'materialized disk grew during verification',
                  );
                }
                return chunk;
              }),
            )
            .first;
        if (verified != expectedSize || 'sha256:$digest' != expectedDigest) {
          throw const FormatException('materialized disk digest mismatch');
        }
      } finally {
        materialized.close();
      }
      _checkCancelled(isCancelled);
      await destination.sync();
      _checkCancelled(isCancelled);
      if (cloned) onProgress?.call(expectedSize);
      _checkCancelled(isCancelled);
      return ManagedDiskMaterialization(bytes: expectedSize, cloned: cloned);
    } catch (_) {
      if (created) {
        destination.removeFile(name);
        await destination.sync();
      }
      rethrow;
    }
  }
}

Future<bool> _nativeClone(
  OwnedImageFile source,
  OwnedImageDirectory destination,
  String name,
) => source.tryCloneTo(destination, name);

void _checkCancelled(bool Function()? cancelled) {
  if (cancelled?.call() ?? false) throw const ManagedDiskCancelled();
}

Future<int> _diskAvailableBytes(OwnedImageDirectory directory) =>
    directory.availableBytes();
