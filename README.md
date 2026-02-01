# vm-claw

Security-isolated macOS VM for running [OpenClaw](https://github.com/pjasicek/OpenClaw) using [Tart](https://tart.run).

## Security Isolation

The VM is configured with strict isolation:
- **Single read-only shared folder** - Only `~/openclaw-shared` is accessible to the guest
- **Isolated network** - VM uses its own NAT, not sharing host network/VPN config
- **No clipboard sharing** - Clipboard is isolated between host and guest

## Requirements

- macOS host
- [Tart](https://tart.run) installed (`brew install cirruslabs/cli/tart`)

## Usage

### Setup

```bash
./setup.sh
```

Downloads macOS Tahoe base image (~25 GB) and creates the `openclaw` VM.

### Run

```bash
./run.sh
```

Starts the VM with isolation enabled. The shared folder is mounted at `/Volumes/My Shared Files/shared` inside the guest (read-only).

### Sharing Files

Place files in `~/openclaw-shared` on your host. They'll be available read-only inside the VM.

## License

MIT
