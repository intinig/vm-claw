#!/bin/bash
set -euo pipefail

VM_NAME="openclaw"
SHARED_DIR="$HOME/openclaw-shared"

# Verify VM exists
if ! tart list | grep -q "[[:space:]]$VM_NAME[[:space:]]"; then
    echo "Error: VM '$VM_NAME' not found. Run ./setup.sh first."
    exit 1
fi

# Verify shared directory exists
if [[ ! -d "$SHARED_DIR" ]]; then
    echo "Error: Shared directory not found: $SHARED_DIR"
    echo "Run ./setup.sh first or create the directory manually."
    exit 1
fi

echo "Starting VM '$VM_NAME' with isolation:"
echo "  - Clipboard: disabled"
echo "  - Shared folder: $SHARED_DIR (read-only)"
echo "  - Network: isolated NAT"
echo ""

tart run "$VM_NAME" \
    --no-clipboard \
    --dir=shared:"$SHARED_DIR":ro
