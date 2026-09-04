#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

json_schemas=(
  "$repo_root/schemas/vm-spec/v1alpha1.schema.json"
  "$repo_root/schemas/driver-protocol/v2.schema.json"
  "$repo_root/schemas/guest-protocol/v1.schema.json"
)

python3 - "${json_schemas[@]}" <<'PY'
import json
from pathlib import Path
import sys

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    schema = json.loads(path.read_text())
    if not isinstance(schema.get("$schema"), str) or not isinstance(schema.get("$id"), str):
        raise SystemExit(f"{path}: JSON Schema must declare $schema and $id")
    if schema.get("type") != "object" and not isinstance(schema.get("oneOf"), list):
        raise SystemExit(f"{path}: top-level schema must describe an object or object union")
PY

uvx --from check-jsonschema==0.36.1 \
  check-jsonschema --check-metaschema "${json_schemas[@]}"

openapi_schema="$repo_root/schemas/openapi/gaovm-v1.yaml"
if command -v openapi-generator >/dev/null 2>&1; then
  openapi-generator validate -i "$openapi_schema"
else
  uvx --from openapi-spec-validator==0.7.2 \
    openapi-spec-validator "$openapi_schema"
fi
