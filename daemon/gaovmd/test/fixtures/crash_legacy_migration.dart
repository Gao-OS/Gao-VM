import 'dart:io';

import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  final state = await OwnedImageDirectory.open(Directory(args[0]));
  final ownership = (await DaemonOwnership.tryAcquire(state))!;
  final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
  final bundles = state.directory('vms');
  final images = state.directory('images');
  try {
    await LegacyVmMigration(
      database: database,
      state: state,
      bundles: bundles,
      images: images,
      ownership: ownership,
      onCheckpoint: (point) {
        if (point.name == args[1]) exit(91);
      },
    ).migrate();
  } finally {
    database.close();
    images.close();
    bundles.close();
    ownership.close();
    state.close();
  }
}
