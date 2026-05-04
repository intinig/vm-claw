#!/bin/bash
set -euo pipefail

VM_NAME="bridge-vm"

# Check if VM exists
if ! tart list | grep -q "[[:space:]]$VM_NAME[[:space:]]"; then
    echo "VM '$VM_NAME' does not exist. Nothing to destroy."
    exit 0
fi

echo "This will permanently delete the VM '$VM_NAME'."
read -p "Are you sure? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Deleting VM '$VM_NAME'..."
tart delete "$VM_NAME"
echo "VM '$VM_NAME' has been destroyed."
