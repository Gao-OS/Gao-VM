/// The frozen B1 tools are explicit public API routes, not a passthrough.
const toolBindings = [
  (name: 'vm_list', method: 'get', path: '/v1/vms'),
  (name: 'vm_get', method: 'get', path: '/v1/vms/{vm_id}'),
  (name: 'vm_create', method: 'post', path: '/v1/vms'),
  (name: 'vm_clone', method: 'post', path: '/v1/vms/{vm_id}/actions/clone'),
  (name: 'vm_start', method: 'post', path: '/v1/vms/{vm_id}/actions/start'),
  (name: 'vm_stop', method: 'post', path: '/v1/vms/{vm_id}/actions/stop'),
  (name: 'vm_wait', method: 'post', path: '/v1/vms/{vm_id}/wait'),
  (name: 'vm_logs', method: 'get', path: '/v1/vms/{vm_id}/logs'),
  (name: 'image_list', method: 'get', path: '/v1/images'),
  (name: 'image_import', method: 'post', path: '/v1/images/import'),
  (name: 'guest_exec', method: 'post', path: '/v1/vms/{vm_id}/guest/exec'),
  (name: 'operation_get', method: 'get', path: '/v1/operations/{operation_id}'),
  (
    name: 'operation_cancel',
    method: 'post',
    path: '/v1/operations/{operation_id}/cancel',
  ),
  (name: 'test_run', method: 'post', path: '/v1/test-runs'),
  (name: 'test_status', method: 'get', path: '/v1/test-runs/{test_run_id}'),
  (
    name: 'test_artifacts',
    method: 'get',
    path: '/v1/test-runs/{test_run_id}/artifacts',
  ),
];
