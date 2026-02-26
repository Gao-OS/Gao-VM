import 'dart:convert';
import 'dart:io';

class AtomicJsonFile {
  AtomicJsonFile(this.path);

  final String path;

  Future<void> write(Map<String, Object?> jsonMap) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp.${pid}.${DateTime.now().microsecondsSinceEpoch}');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(jsonMap));
      await raf.writeFrom(bytes);
      await raf.writeString('\n');
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(target.path);
  }
}
