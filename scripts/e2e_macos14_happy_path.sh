#!/usr/bin/env bash
set -euo pipefail

# GaoVM v1.2 happy path (macOS 14+, Apple Silicon)
# Requires:
#   - Linux arm64 kernel/initrd files compatible with Virtualization.framework
#   - Root disk path for guest installation/use (sparse file will be created automatically)
#
# Example usage:
#   KERNEL_PATH=/path/to/vmlinuz \
#   INITRD_PATH=/path/to/initrd \
#   DISK_PATH=$HOME/gaovm/demo.img \
#   bash scripts/e2e_macos14_happy_path.sh

: "${KERNEL_PATH:?Set KERNEL_PATH to an ARM64 Linux kernel image path}"
: "${DISK_PATH:?Set DISK_PATH to desired sparse disk image path}"
INITRD_PATH="${INITRD_PATH:-}"
STATE_DIR="${STATE_DIR:-$PWD/.tmp/e2e-state}"
SOCK_PATH="${SOCK_PATH:-$STATE_DIR/run/daemon.sock}"
DRIVER_BIN="${DRIVER_BIN:-$PWD/drivers/vz_macos/.build/debug/gaovm-driver-vz}"

mkdir -p "$STATE_DIR"

echo "[1/8] Build driver"
(cd drivers/vz_macos && swift build)

echo "[2/8] Start daemon"
(cd daemon/gaovmd && dart run bin/gaovmd.dart --state-dir "$STATE_DIR" --socket-path "$SOCK_PATH" --driver-bin "$DRIVER_BIN") &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" >/dev/null 2>&1 || true' EXIT
sleep 2

if [[ -n "$INITRD_PATH" ]]; then
  INITRD_JSON="\"$INITRD_PATH\""
else
  INITRD_JSON="null"
fi

BOOT_JSON=$(cat <<JSON
{"loader":"linux","kernelPath":"$KERNEL_PATH","initrdPath":$INITRD_JSON,"commandLine":"console=hvc0 root=/dev/vda rw"}
JSON
)

CONFIG_JSON=$(cat <<JSON
{
  "cpu": 2,
  "memory": 2147483648,
  "boot": $BOOT_JSON,
  "disk": {"path":"$DISK_PATH","sizeMiB":8192},
  "network": {"mode":"shared"},
  "graphics": {"enabled": true, "width": 1280, "height": 800}
}
JSON
)

echo "[3/8] Write VM config"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" config-set --json "$CONFIG_JSON")

echo "[4/8] Start VM (creates sparse disk if missing)"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" start)

echo "[5/8] Open display"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" open-display)

echo "[6/8] Close display (VM should keep running)"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" close-display)

echo "[7/8] Re-open display"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" open-display)

echo "[8/8] Stop VM"
(cd clients/gaovm_cli && dart run bin/gaovm_cli.dart --socket-path "$SOCK_PATH" stop)

echo "Done. Daemon logs: $STATE_DIR/logs/gaovmd.log"
