# OpenClaw install runbook (inside the vm-claw VM)

Pre-conditions:
- `vmclaw bootstrap` completed; VM is up.
- Apple ID signed into Messages.app inside the VM GUI; iMessage active.
- `vmclaw vm tailscale-bootstrap` completed; VM has joined the tailnet.
- You have the Tailscale name of the VM (e.g. `vm-claw.tail-abcdef.ts.net`).

## Steps

### 1) SSH into the VM via tailnet

```bash
tailscale ssh <bridge-user>@vm-claw.tail-abcdef.ts.net
```

If you used `--ssh` during `tailscale up` (default in this project), no extra SSH keys are needed — Tailscale brokers the auth.

### 2) Install Node 24 LTS

```bash
brew install node@24
brew link --overwrite node@24
node -v   # expect v24.x
```

### 3) Install OpenClaw (latest stable)

```bash
npm install -g openclaw@latest
openclaw --version
```

### 4) Install `imsg`

```bash
brew install steipete/tap/imsg
imsg --help
```

Grant Full Disk Access to `imsg` and to `node` (the openclaw gateway runtime):
- System Settings → Privacy & Security → Full Disk Access → add `/opt/homebrew/bin/imsg` AND `/opt/homebrew/bin/node` (the brew node 24 binary).
- Required because both processes need to read `~/Library/Messages/chat.db`.

### 5) Set up OpenClaw config

```bash
mkdir -p ~/.openclaw
# Copy the sample from the repo (you'll need to clone or scp it into the VM)
cp /path/from/repo/docs/openclaw-config.example.yaml ~/.openclaw/config.yaml
chmod 600 ~/.openclaw/config.yaml
```

Edit `~/.openclaw/config.yaml`:
- Replace `REPLACE_FROM_BACKUP_ENV` with your real provider API keys (from `~/Documents/vmclaw-backup.env` on the host — `scp` it over the tailnet).
- Replace the placeholder `+1XXXXXXXXXX` in `channels.imessage.allowFrom` with your own iMessage handle.

### 6) Install the OpenClaw gateway as a LaunchAgent

```bash
openclaw onboard --install-daemon
```

This writes `~/Library/LaunchAgents/ai.openclaw.gateway.plist` and loads it. Verify:

```bash
launchctl print gui/$(id -u)/ai.openclaw.gateway | head -20
openclaw status
```

### 7) Verify iMessage channel

```bash
openclaw channels status --probe --channel imessage
```

Expected: `imessage: ok` with imsg binary path printed.

### 8) Apply Tailscale Serve for WebChat (optional)

If you want OpenClaw WebChat reachable from your host browser at `https://vm-claw.tail-abcdef.ts.net`:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
```

### 9) From the host, run doctor

```bash
vmclaw doctor --tailnet-host=vm-claw.tail-abcdef.ts.net
```

Expected: green across the chain.

### 10) Smoke test

From another Apple device signed into a different Apple ID, send an iMessage to the bridge Apple ID:

> @openclaw what's the weather?

Expected: OpenClaw replies within ~10 seconds.
