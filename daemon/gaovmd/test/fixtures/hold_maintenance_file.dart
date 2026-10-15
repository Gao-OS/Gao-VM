import 'dart:io';

Future<void> main(List<String> arguments) async {
  final file = await File(arguments.single).open();
  try {
    stdout.writeln('held');
    await stdin.drain<void>();
  } finally {
    await file.close();
  }
}
