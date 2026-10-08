# Guest exec CLI adapter

This is the client boundary for development-plan M7 and PRD `CLI-005`, `CLI-007`,
`CLI-008`, and `API-012`. It does not complete those requirements' installed or
GaoOS acceptance. The installed daemon does not yet register the Guest exec
endpoint, and its per-VM Guest sessions, durable exec worker, and binary artifact
transport remain M6 work. An unavailable route/agent is an API failure, never a
reason to run a command on the host.

## Request and acceptance

Use the VM ID returned by the public catalog. For example, with an API that
implements the frozen [Guest exec endpoint](../schemas/openapi/gaovm-v1.yaml):

```sh
cd clients/gaovm_cli
mise exec dart@3.9 -- dart run bin/gaovm_cli.dart \
  --socket-path /absolute/state/run/api.sock \
  guest exec vm_01J00000000000000000000000 \
  --body-json '{"argv":["gaoos-test","network"],"cwd":"/","env":{},"timeout_seconds":600,"capture":{"stdout":true,"stderr":true,"max_inline_bytes":65536}}' \
  --idempotency-key network-smoke-1 --timeout-seconds 10 --json
```

The CLI posts this JSON object to `POST /v1/vms/{vm_id}/guest/exec`. It validates
the target ID and JSON-object syntax locally; the public application service owns
request semantics and Guest admission. Arguments with spaces, quotes, shell
metacharacters, and Unicode remain data. No implicit shell, host environment
expansion, or host cwd lookup is performed. A Guest shell must be requested
explicitly through its argv vector.

Exit `0` means the API returned HTTP `202` with an `op_` ULID, the requested
`virtual_machine` resource ID, and a valid acceptance state (`pending`, `running`,
or `succeeded`). It does not mean the Guest command ran or exited successfully.
The acceptance is printed unchanged as compact JSON with `--json`, or pretty JSON
otherwise. Query the returned operation with `operation get/wait`; cancellation
must use the public `operation cancel` path, not a driver connection.

## Deadlines, retries, and errors

- Body `timeout_seconds` is the requested Guest execution budget.
- CLI `--timeout-seconds` is the independent local HTTP deadline, defaulting to
  30 seconds. Expiry returns `124`; it does not rewrite the Guest budget, cancel
  accepted work, or prove that the API did not accept the request.
- Each invocation without a key generates a fresh idempotency key. For explicit
  retries, reuse `--idempotency-key` and the same body. The CLI never automatically
  retries a write.
- API Problems go to stderr with exit `1` (`124` for `WAIT_TIMEOUT`), preserving
  code, HTTP status, request ID, retryability, and details. A missing route and
  `GUEST_AGENT_UNAVAILABLE` are failures, not successful executions.
- Invalid command arguments use exit `2`, transport failures `3`, and malformed
  or wrong-VM operation acceptances `4`. Successful output goes only to stdout.

The command accepts only an explicit VM target, `--body-json`, optional
`--idempotency-key`, and the ordinary socket/deadline/output options. List queries,
revision headers, and VM wait options are rejected locally.

## Verification and remaining dependency

```sh
cd clients/gaovm_cli
mise exec dart@3.9 -- dart test test/guest_exec_cli_test.dart test/public_api_cli_test.dart
```

Tests use the real HTTP/UDS transport and CLI entrypoint with a **fixture public
API**, including a child process started outside the repository. They verify
request preservation, private socket ownership, generated/supplied keys, JSON
formats, acceptance correlation, API errors, local validation, and deadlines.
They do not implement or validate server-side durability, cancellation, Guest
authentication, vsock, actual Guest execution, or artifact transfer. No frozen
public/driver/Guest schema or production daemon behavior is changed by this slice.

Full `CLI-005`/M6 acceptance still requires the installed public application
service and worker, authenticated per-generation Guest sessions, and real GaoOS
readiness/exec/artifact E2E. Client fixture success is not that evidence.
