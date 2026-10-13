#!/usr/bin/env bash
set -euo pipefail

# Source-only public-API smoke test; native release gates are separate.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
exec "${DART_BIN:-dart}" \
  --packages="$REPO_DIR/clients/gaovm_cli/.dart_tool/package_config.json" \
  "$REPO_DIR/clients/gaovm_cli/tool/e2e_macos.dart" "$@"
