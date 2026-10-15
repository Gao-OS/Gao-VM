import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

void main(List<String> args) {
  if (args.length != 1 || args.single != '--component-info') exit(2);
  final name = File(Platform.resolvedExecutable).uri.pathSegments.last;
  if (name == 'legacy') {
    stdout.writeln('prototype fixture, no component info');
    return;
  }
  if (name == 'noisy') stderr.writeln('unexpected diagnostic');
  stdout.writeln(
    jsonEncode(
      ComponentInfo(
        role: name == 'foreign' ? ComponentRole.daemon : ComponentRole.cli,
        version: gaovmImplementationVersion,
        publicApi: 'v1',
        vmSpec: vmApiVersion,
      ).toJson(),
    ),
  );
}
