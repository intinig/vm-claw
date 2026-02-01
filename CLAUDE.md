# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project creates a security-isolated macOS VM using [Tart](https://tart.run) for running OpenClaw (open-source Captain Claw reimplementation). The VM is configured with strict isolation to minimize attack surface.

## Security Requirements

The VM must enforce these isolation constraints:
- **Single shared folder**: Read-only mount only. User controls what files are shared with the guest.
- **Isolated network**: VM uses its own NAT networking, not sharing host's network/VPN configuration.
- **No clipboard sharing**: Clipboard isolation between host and guest.

## Tart Commands Reference

```bash
# Create a macOS VM from IPSW or restore image
tart create <vm-name> --from-ipsw <path>

# Clone from a base image
tart clone <source> <vm-name>

# Run VM with options
tart run <vm-name> --no-clipboard --dir=shared:~/path/to/shared:ro

# List VMs
tart list

# Delete VM
tart delete <vm-name>
```

## Key Tart Flags for Isolation

- `--no-clipboard` - Disables clipboard sharing
- `--dir=<name>:<host-path>:ro` - Mounts read-only shared folder (`:ro` suffix)
- `--net-bridged=<interface>` or default NAT - Network isolation (default NAT is isolated)

## Architecture

This is a shell-script based project for VM provisioning and management. Expected structure:
- Scripts for VM creation, configuration, and launching
- Configuration for shared folder paths
- Documentation for OpenClaw installation inside the guest
