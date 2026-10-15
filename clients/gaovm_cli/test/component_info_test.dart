import 'dart:convert';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'component probe reports the actual CLI role without HOME or a socket',
    () async {
      final output = StringBuffer(), error = StringBuffer();
      final result = await runCli(
        ['--component-info'],
        environment: const {},
        output: output.writeln,
        error: error.writeln,
      );
      expect(result, 0, reason: error.toString());
      expect(jsonDecode(output.toString()), {
        'format': 'gaovm.component.v1',
        'role': 'cli',
        'version': '0.1.0',
        'public_api': 'v1',
        'vm_spec': 'gaovm.io/v1alpha1',
        'driver_protocol': null,
        'catalog_schema': null,
        'capabilities': {'offered': [], 'required': [], 'development_only': []},
        'service_actions': [],
      });
    },
  );
}
