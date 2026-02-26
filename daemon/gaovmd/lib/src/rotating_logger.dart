import 'dart:io';

enum LogLevel {
  error,
  warn,
  info,
  debug,
}

class RotatingLogger {
  RotatingLogger({
    required this.path,
    this.maxBytes = 10 * 1024 * 1024,
    this.maxRotations = 3,
    this.minLevel = LogLevel.info,
  });

  final String path;
  final int maxBytes;
  final int maxRotations;
  final LogLevel minLevel;

  Future<void> error(String message) => log(LogLevel.error, message);
  Future<void> warn(String message) => log(LogLevel.warn, message);
  Future<void> info(String message) => log(LogLevel.info, message);
  Future<void> debug(String message) => log(LogLevel.debug, message);

  Future<void> log(LogLevel level, String message) async {
    if (level.index > minLevel.index) {
      return;
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await _rotateIfNeeded(file);
    final line = '[${DateTime.now().toUtc().toIso8601String()}] '
        '[${level.name}] $message\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) {
      return;
    }
    final stat = await file.stat();
    if (stat.size < maxBytes) {
      return;
    }

    final oldest = File('$path.$maxRotations');
    if (await oldest.exists()) {
      await oldest.delete();
    }
    for (var i = maxRotations - 1; i >= 1; i--) {
      final src = File('$path.$i');
      if (await src.exists()) {
        await src.rename('$path.${i + 1}');
      }
    }
    await file.rename('$path.1');
  }
}
