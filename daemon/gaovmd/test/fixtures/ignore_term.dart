import 'dart:io';

Future<void> main() async {
  ProcessSignal.sigterm.watch().listen((_) => stdout.writeln('term'));
  stdout.writeln('ready');
  await stdin.drain<void>();
}
