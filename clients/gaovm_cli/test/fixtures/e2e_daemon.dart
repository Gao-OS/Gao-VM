import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[1] == 'fail-start') {
    stderr.writeln('fixture census rejected');
    exitCode = 7;
    return;
  }
  final stopped = Completer<void>();
  final keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {});
  final signal = ProcessSignal.sigterm.watch().listen((_) {
    if (!stopped.isCompleted) stopped.complete();
  });
  stdout.writeln('gaovmd listening on unix:${args.first}');
  await stopped.future;
  if (args.length == 2 && args[1] == 'fail-stop') exitCode = 9;
  keepAlive.cancel();
  await signal.cancel();
}
