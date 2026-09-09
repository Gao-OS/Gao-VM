import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  final database = await GaoVmDatabase.open(args[0]);
  final bundles = await OwnedImageDirectory.open(Directory(args[1]));
  final images = await OwnedImageDirectory.open(Directory(args[2]));
  final plan = (await SqliteVmProvisioningRepository(
    database,
  ).get(VmId(args[3])))!.plan;
  await VmBundleStore(
    database: database,
    bundles: bundles,
    images: images,
    onCheckpoint: (point) {
      if (point.name == args[4]) exit(91);
    },
  ).withBundle(plan, (bundle) async {
    await bundle.publish();
    if (args[4] == 'cleanupContentsRemoved') await bundle.removeUncommitted();
  });
  throw StateError('crash checkpoint was not reached');
}
