import 'package:gaovmd/src/public_api_server.dart';
import 'package:test/test.dart';

void main() {
  Future<PublicApiResponse> resource(PublicApiRequest _) async =>
      PublicApiResponse.json(status: 200, body: const {});
  Future<PublicApiResponse> exact(PublicApiRequest _) async =>
      PublicApiResponse.json(status: 200, body: const {});

  test(
    'resource templates extract one segment and preserve exact precedence',
    () {
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms/{vm_id}', resource)
        ..add('POST', '/v1/vms/{vm_id}/start', resource)
        ..add('GET', '/v1/vms/catalog', exact);

      expect(router.handler('GET', '/v1/vms/vm_123'), same(resource));
      expect(router.pathParameters('/v1/vms/vm_123'), {'vm_id': 'vm_123'});
      expect(router.allowedMethods('/v1/vms/vm_123/start'), {'POST'});
      expect(router.handler('GET', '/v1/vms/catalog'), same(exact));
      expect(router.pathParameters('/v1/vms/catalog'), isEmpty);
      expect(router.containsPath('/v1/vms/'), isFalse);
      expect(router.containsPath('/v1/vms/vm_123/extra'), isFalse);
    },
  );

  test('rejects ambiguous and malformed resource templates', () {
    final router = PublicApiRouter()..add('GET', '/v1/vms/{vm_id}', resource);
    expect(
      () => router.add('GET', '/v1/vms/{id}', resource),
      throwsArgumentError,
    );
    for (final path in ['/v1/vms/{id', '/v1/{id}/{id}', '/v1/vms/prefix{id}']) {
      expect(() => router.add('GET', path, resource), throwsArgumentError);
    }
  });
}
