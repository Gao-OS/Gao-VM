import 'package:gaovmd/src/guest_exec_request.dart';
import 'package:test/test.dart';

void main() {
  test('argv, cwd and environment remain immutable guest data', () {
    final argv = ['gaoos-test', 'a b', r'$(literal)', '中文'];
    final env = {'MODE': 'smoke'};
    final capture = <String, Object?>{
      'stdout': true,
      'stderr': true,
      'max_inline_bytes': 4.0,
    };
    final request = GuestExecRequest.fromJson({
      ..._request,
      'argv': argv,
      'cwd': '/guest/tests',
      'env': env,
      'capture': capture,
    });
    argv[0] = 'modified';
    env['MODE'] = 'modified';
    capture['max_inline_bytes'] = 100;
    final exported = request.toJson();
    (exported['argv'] as List)[0] = 'another modification';
    try {
      (exported['env'] as Map)['MODE'] = 'another modification';
    } on UnsupportedError {
      // Immutable nested maps also preserve the request's original data.
    }
    expect(request.toJson()['argv'], [
      'gaoos-test',
      'a b',
      r'$(literal)',
      '中文',
    ]);
    expect(request.toJson()['env'], {'MODE': 'smoke'});
    expect(request.toJson()['cwd'], '/guest/tests');
    expect(request.maxInlineBytes, 4);
  });

  test('public environment has no invented property-count restriction', () {
    final request = GuestExecRequest.fromJson({
      ..._request,
      'env': {for (var index = 0; index < 1025; index++) 'KEY_$index': ''},
    });
    expect((request.toJson()['env'] as Map).length, 1025);
  });

  test('a positive sub-microsecond timeout cannot become a zero budget', () {
    final request = GuestExecRequest.fromJson({
      ..._request,
      'timeout_seconds': 0.0000000001,
    });
    expect(request.timeout, const Duration(microseconds: 1));
  });

  for (final (name, patch) in <(String, Map<String, Object?>)>[
    ('empty argv', {'argv': <String>[]}),
    ('too many arguments', {'argv': List.filled(1025, '')}),
    (
      'oversized argument',
      {
        'argv': ['x' * 131073],
      },
    ),
    (
      'non-string argument',
      {
        'argv': [1],
      },
    ),
    ('empty cwd', {'cwd': ''}),
    (
      'invalid environment key',
      {
        'env': {'BAD-KEY': ''},
      },
    ),
    (
      'non-string environment value',
      {
        'env': {'MODE': 1},
      },
    ),
    ('zero timeout', {'timeout_seconds': 0}),
    ('non-finite timeout', {'timeout_seconds': double.infinity}),
    ('oversized timeout', {'timeout_seconds': 86401}),
    (
      'fractional capture bound',
      {
        'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 1.5},
      },
    ),
    ('unknown property', {'host_command': 'never executed'}),
  ]) {
    test('public exec request rejects $name', () {
      expect(
        () => GuestExecRequest.fromJson({..._request, ...patch}),
        throwsFormatException,
      );
    });
  }
}

const _request = <String, Object?>{
  'argv': ['gaoos-test'],
  'cwd': '/',
  'env': <String, String>{},
  'timeout_seconds': 30,
  'capture': {'stdout': true, 'stderr': true, 'max_inline_bytes': 65536},
};
