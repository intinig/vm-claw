#!/bin/bash
set -euo pipefail

VM_NAME="openclaw"
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
SHARED_DIR="$HOME/openclaw-shared"

echo "=== OpenClaw VM Setup ==="

# Create shared directory if it doesn't exist
if [[ ! -d "$SHARED_DIR" ]]; then
    echo "Creating shared directory: $SHARED_DIR"
    mkdir -p "$SHARED_DIR"
fi

# Check if VM already exists
if tart list | grep -q "[[:space:]]$VM_NAME[[:space:]]"; then
    echo "VM '$VM_NAME' already exists."
    read -p "Delete and recreate? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing VM..."
        tart delete "$VM_NAME"
    else
        echo "Keeping existing VM. Use ./run.sh to start it."
        exit 0
    fi
fi

# Pull base image and clone
echo "Pulling base image: $BASE_IMAGE"
tart pull "$BASE_IMAGE"

echo "Creating VM: $VM_NAME"
tart clone "$BASE_IMAGE" "$VM_NAME"

echo ""
echo "=== Setup Complete ==="
echo "VM '$VM_NAME' created successfully."
echo "Shared directory: $SHARED_DIR (will be mounted read-only)"
echo ""
echo "Run './run.sh' to start the VM with isolation enabled."
