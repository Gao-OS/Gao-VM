import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  final state = await OwnedImageDirectory.open(Directory(args.single));
  final owner = (await DaemonOwnership.tryAcquire(state))!;
  final paths = await DriverRuntimeLayout('${state.path}/run').create(
    DriverCorrelation(
      vmId: VmId('vm_01J00000000000000000000000'),
      driverGeneration: 1,
      operationId: null,
    ),
  );
  await File(
    '${paths.metadataPath}.tmp.$pid.1',
  ).writeAsString('{', flush: true);
  final socket = await ServerSocket.bind(
    InternetAddress(paths.socketPath, type: InternetAddressType.unix),
    0,
  );
  await owner.verify();
  stdout.writeln('ready');
  await stdout.flush();
  await Completer<void>().future;
  await socket.close();
  owner.close();
  state.close();
}
