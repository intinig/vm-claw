# Hermes + iMessage bridge VM — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the vm-claw repo from its retired OpenClaw scope to the new Hermes + iMessage bridge VM design. End state: shell scripts manage a `bridge-vm` Tart VM that hosts BlueBubbles Server, and the Hermes container reaches it via `docker run --add-host bridge-vm:<ip>`. No host-side port forwarder; no shared folder.

**Architecture:** Two pieces. Hermes Agent runs in Docker on the host (Colima daemon). A Tart-based macOS VM runs Messages.app under a separate Apple ID with [BlueBubbles Server](https://bluebubbles.app/server/) exposed on softnet `0.0.0.0:1234`. Outbound: container → vmnet → host kernel → softnet bridge → VM:1234. Inbound: BlueBubbles webhook → softnet gateway IP → host's published `:8642` Hermes gateway port.

**Tech Stack:** Bash + Tart (cirruslabs) + softnet + Colima + Docker. macOS host (Apple Silicon).

**Spec:** [`docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md`](../specs/2026-05-04-hermes-imessage-bridge-vm-design.md) (committed `165d93a`).

**Phase map:**

- **Phase 0** — Snapshot pre-existing untracked work (1 task).
- **Phase 1** — Tag preserve point + repoint Tart scripts (4 tasks).
- **Phase 2** — *Manual* bridge VM provisioning. No code tasks. Follow [the runbook in the spec](../specs/2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook).
- **Phase 3** — Hermes container `--add-host` wiring (1 task).
- **Phase 4** — Hermes BlueBubbles connector. Starts with a manual research step (env var names, current Hermes docs) then plumbing + e2e (3 tasks).
- **Phase 5** — Polish (3 optional tasks).

**Repo working state at plan start:** branch `main`, latest commit `165d93a`. Working tree has: ` M setup.sh`, ` M run.sh`, `?? hermes-setup.sh`. The `hermes-setup.sh` content is the existing Hermes bootstrap script; it's never been committed. The `setup.sh` and `run.sh` modifications include the `check_vmnet_subnet_collision` function (keep — load-bearing) plus a SHA pin and `DISK_SIZE_GB=100` that the spec wants removed.

---

## Phase 0 — Baseline snapshot

### Task 0: Commit `hermes-setup.sh` as-is

`hermes-setup.sh` exists in the working tree but has never been committed. Commit it now so subsequent tasks have a tracked baseline to modify and so the pre-session work isn't lost. Do **not** modify it yet.

**Files:**
- Add to git: `hermes-setup.sh`

- [ ] **Step 1: Verify the file is untracked**

```bash
cd /Users/gintini/s/vm-claw
git status --short hermes-setup.sh
```

Expected: `?? hermes-setup.sh`. If it shows tracked already (`M` or nothing), skip the rest of this task.

- [ ] **Step 2: Stage the file**

```bash
git add hermes-setup.sh
```

- [ ] **Step 3: Commit it as the baseline**

```bash
git commit -m "$(cat <<'EOF'
Add hermes-setup.sh baseline

Tracks the existing Hermes bootstrap script so subsequent
migration tasks can modify it as a normal tracked file.
This commit is the pre-Hermes-iMessage-bridge baseline; the
--add-host wiring lands in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify clean status for Phase 1**

```bash
git status --short
```

Expected: only `setup.sh` and `run.sh` should still show ` M`. Those are intentionally left for Phase 1 to absorb.

---

## Phase 1 — Repo housekeeping

### Task 1.1: Tag preserve point

Anchor the OpenClaw layout before the migration commits land. Recovery use case: `git checkout openclaw-final` to inspect or revive the old layout.

**Files:** none — git operation only.

- [ ] **Step 1: Verify the tag doesn't already exist**

```bash
git tag --list openclaw-final
```

Expected: empty output. If the tag already exists, skip the next step.

- [ ] **Step 2: Create the tag at current `main`**

```bash
git tag -a openclaw-final main -m "Final OpenClaw-scoped layout before migration to Hermes + iMessage bridge VM"
```

- [ ] **Step 3: Verify the tag points at `165d93a` (or whatever the current `main` HEAD is at plan start)**

```bash
git rev-parse openclaw-final
git rev-parse main
```

Both should print the same SHA.

- [ ] **Step 4 (optional): Push the tag**

```bash
git remote -v
# If a remote is configured, push:
git push origin openclaw-final
# If no remote, the local tag is enough.
```

No code commit — tags are stand-alone refs.

---

### Task 1.2: Repoint `setup.sh`

Update VM name, drop SHA pin from `BASE_IMAGE`, drop `DISK_SIZE_GB` and the `tart set --disk-size` call, drop `SHARED_DIR` and the mkdir block, drop the shared-folder line in the final banner. Keep `check_vmnet_subnet_collision` and the rest of the flow unchanged.

**Files:**
- Modify: `/Users/gintini/s/vm-claw/setup.sh`

- [ ] **Step 1: Write the verification checks (they should fail now)**

Run this verification script — it should print `FAIL` on every line that's not yet correct:

```bash
cd /Users/gintini/s/vm-claw
{
  grep -qF 'VM_NAME="bridge-vm"' setup.sh         && echo "VM_NAME OK"           || echo "VM_NAME FAIL"
  grep -qF 'macos-tahoe-base:latest' setup.sh     && echo "BASE_IMAGE :latest OK"|| echo "BASE_IMAGE :latest FAIL"
  ! grep -qF '@sha256:' setup.sh                  && echo "no SHA pin OK"        || echo "no SHA pin FAIL"
  ! grep -qF 'DISK_SIZE_GB' setup.sh              && echo "no DISK_SIZE_GB OK"   || echo "no DISK_SIZE_GB FAIL"
  ! grep -qF 'tart set' setup.sh                  && echo "no disk-size set OK"  || echo "no disk-size set FAIL"
  ! grep -qF 'SHARED_DIR' setup.sh                && echo "no SHARED_DIR OK"     || echo "no SHARED_DIR FAIL"
  ! grep -qF 'openclaw-shared' setup.sh           && echo "no openclaw-shared OK"|| echo "no openclaw-shared FAIL"
  grep -qF '=== Bridge VM Setup ===' setup.sh     && echo "banner OK"            || echo "banner FAIL"
  grep -qF 'check_vmnet_subnet_collision()' setup.sh && echo "vmnet check kept OK" || echo "vmnet check kept FAIL"
}
```

Expected at this point (working copy still has old content): everything except `vmnet check kept` should be FAIL.

- [ ] **Step 2: Apply the variable-block change**

In `setup.sh`, replace:

```bash
VM_NAME="openclaw"
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base@sha256:6abd551a46da4e595b6a9f678535a8f1bbd61bdc275a363265cd39281d3abdef"
SHARED_DIR="$HOME/openclaw-shared"
DISK_SIZE_GB=100
```

with:

```bash
VM_NAME="bridge-vm"
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
```

- [ ] **Step 3: Update the setup banner**

Replace:

```bash
echo "=== OpenClaw VM Setup ==="
```

with:

```bash
echo "=== Bridge VM Setup ==="
```

- [ ] **Step 4: Remove the shared-directory mkdir block**

Delete this block entirely:

```bash
# Create shared directory if it doesn't exist
if [[ ! -d "$SHARED_DIR" ]]; then
    echo "Creating shared directory: $SHARED_DIR"
    mkdir -p "$SHARED_DIR"
fi
```

- [ ] **Step 5: Remove the disk-size resize block**

Delete this block entirely:

```bash
echo "Resizing disk to ${DISK_SIZE_GB} GB"
tart set "$VM_NAME" --disk-size "$DISK_SIZE_GB"
```

- [ ] **Step 6: Update the final banner**

Replace this block:

```bash
echo ""
echo "=== Setup Complete ==="
echo "VM '$VM_NAME' created successfully (${DISK_SIZE_GB} GB disk)."
echo "Shared directory: $SHARED_DIR (will be mounted read-only)"
echo ""
echo "Run './run.sh' to start the VM with isolation enabled."
```

with:

```bash
echo ""
echo "=== Setup Complete ==="
echo "VM '$VM_NAME' created successfully."
echo ""
echo "Run './run.sh' to start the VM."
```

- [ ] **Step 7: Re-run the verification checks**

```bash
{
  grep -qF 'VM_NAME="bridge-vm"' setup.sh         && echo "VM_NAME OK"           || echo "VM_NAME FAIL"
  grep -qF 'macos-tahoe-base:latest' setup.sh     && echo "BASE_IMAGE :latest OK"|| echo "BASE_IMAGE :latest FAIL"
  ! grep -qF '@sha256:' setup.sh                  && echo "no SHA pin OK"        || echo "no SHA pin FAIL"
  ! grep -qF 'DISK_SIZE_GB' setup.sh              && echo "no DISK_SIZE_GB OK"   || echo "no DISK_SIZE_GB FAIL"
  ! grep -qF 'tart set' setup.sh                  && echo "no disk-size set OK"  || echo "no disk-size set FAIL"
  ! grep -qF 'SHARED_DIR' setup.sh                && echo "no SHARED_DIR OK"     || echo "no SHARED_DIR FAIL"
  ! grep -qF 'openclaw-shared' setup.sh           && echo "no openclaw-shared OK"|| echo "no openclaw-shared FAIL"
  grep -qF '=== Bridge VM Setup ===' setup.sh     && echo "banner OK"            || echo "banner FAIL"
  grep -qF 'check_vmnet_subnet_collision()' setup.sh && echo "vmnet check kept OK" || echo "vmnet check kept FAIL"
}
```

Expected: all 9 lines print `OK`.

- [ ] **Step 8: Syntax-check the script**

```bash
bash -n setup.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 9: Commit**

```bash
git add setup.sh
git commit -m "$(cat <<'EOF'
Repoint setup.sh to bridge-vm for iMessage bridge migration

- VM_NAME: openclaw → bridge-vm
- BASE_IMAGE: drop SHA pin, follow :latest tag (per spec decision)
- Drop DISK_SIZE_GB and tart set --disk-size; use base image default
- Drop SHARED_DIR + mkdir; the new design has no host↔VM shared folder
- Update banners; preserve check_vmnet_subnet_collision

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Repoint `run.sh`

VM name change, drop shared-folder existence check and the `--dir=shared:...:ro` flag, drop the shared-folder banner line. Keep `check_vmnet_subnet_collision` and `--net-softnet`.

**Files:**
- Modify: `/Users/gintini/s/vm-claw/run.sh`

- [ ] **Step 1: Verification checks (will fail initially)**

```bash
cd /Users/gintini/s/vm-claw
{
  grep -qF 'VM_NAME="bridge-vm"' run.sh           && echo "VM_NAME OK"            || echo "VM_NAME FAIL"
  ! grep -qF 'SHARED_DIR' run.sh                  && echo "no SHARED_DIR OK"      || echo "no SHARED_DIR FAIL"
  ! grep -qF 'openclaw-shared' run.sh             && echo "no openclaw-shared OK" || echo "no openclaw-shared FAIL"
  ! grep -qF '--dir=' run.sh                      && echo "no --dir= flag OK"     || echo "no --dir= flag FAIL"
  grep -qF '--net-softnet' run.sh                 && echo "softnet kept OK"       || echo "softnet kept FAIL"
  grep -qF 'check_vmnet_subnet_collision()' run.sh && echo "vmnet check kept OK"  || echo "vmnet check kept FAIL"
}
```

Expected: only `softnet kept` and `vmnet check kept` are OK; the rest are FAIL.

- [ ] **Step 2: Variable-block edit**

Replace:

```bash
VM_NAME="openclaw"
SHARED_DIR="$HOME/openclaw-shared"
```

with:

```bash
VM_NAME="bridge-vm"
```

- [ ] **Step 3: Remove the shared-directory existence check**

Delete this block entirely:

```bash
# Verify shared directory exists
if [[ ! -d "$SHARED_DIR" ]]; then
    echo "Error: Shared directory not found: $SHARED_DIR"
    echo "Run ./setup.sh first or create the directory manually."
    exit 1
fi
```

- [ ] **Step 4: Update the start banner**

Replace this block:

```bash
echo "Starting VM '$VM_NAME' with isolation:"
echo "  - Shared folder: $SHARED_DIR (read-only)"
echo "  - Network: softnet (isolated from host VPN and routes)"
echo "  - Clipboard: enabled"
echo ""
```

with:

```bash
echo "Starting VM '$VM_NAME':"
echo "  - Network: softnet (isolated from host VPN and routes)"
echo "  - Clipboard: enabled"
echo ""
```

- [ ] **Step 5: Drop the `--dir=` flag from `tart run`**

Replace:

```bash
tart run "$VM_NAME" \
    --net-softnet \
    --dir=shared:"$SHARED_DIR":ro
```

with:

```bash
tart run "$VM_NAME" \
    --net-softnet
```

- [ ] **Step 6: Re-run the verification checks**

```bash
{
  grep -qF 'VM_NAME="bridge-vm"' run.sh           && echo "VM_NAME OK"            || echo "VM_NAME FAIL"
  ! grep -qF 'SHARED_DIR' run.sh                  && echo "no SHARED_DIR OK"      || echo "no SHARED_DIR FAIL"
  ! grep -qF 'openclaw-shared' run.sh             && echo "no openclaw-shared OK" || echo "no openclaw-shared FAIL"
  ! grep -qF '--dir=' run.sh                      && echo "no --dir= flag OK"     || echo "no --dir= flag FAIL"
  grep -qF '--net-softnet' run.sh                 && echo "softnet kept OK"       || echo "softnet kept FAIL"
  grep -qF 'check_vmnet_subnet_collision()' run.sh && echo "vmnet check kept OK"  || echo "vmnet check kept FAIL"
}
```

Expected: all 6 lines `OK`.

- [ ] **Step 7: Syntax-check**

```bash
bash -n run.sh && echo "syntax OK"
```

- [ ] **Step 8: Commit**

```bash
git add run.sh
git commit -m "$(cat <<'EOF'
Repoint run.sh to bridge-vm; drop shared folder

- VM_NAME: openclaw → bridge-vm
- Drop SHARED_DIR + existence check + --dir=shared:...:ro flag
- Update banner; preserve --net-softnet and check_vmnet_subnet_collision

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Repoint `destroy.sh`

Single rename — `destroy.sh` already does what we need.

**Files:**
- Modify: `/Users/gintini/s/vm-claw/destroy.sh`

- [ ] **Step 1: Verification check**

```bash
cd /Users/gintini/s/vm-claw
grep -qF 'VM_NAME="bridge-vm"' destroy.sh && echo "VM_NAME OK" || echo "VM_NAME FAIL"
```

Expected: `FAIL`.

- [ ] **Step 2: Edit**

Replace:

```bash
VM_NAME="openclaw"
```

with:

```bash
VM_NAME="bridge-vm"
```

- [ ] **Step 3: Re-run check**

```bash
grep -qF 'VM_NAME="bridge-vm"' destroy.sh && echo "VM_NAME OK" || echo "VM_NAME FAIL"
bash -n destroy.sh && echo "syntax OK"
```

Expected: both `OK`.

- [ ] **Step 4: Commit**

```bash
git add destroy.sh
git commit -m "$(cat <<'EOF'
Repoint destroy.sh to bridge-vm

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Bridge VM provisioning (manual)

**No code tasks in this phase.** This is a manual checkpoint that gates Phase 3 onwards. Follow the runbook in the spec — sections A through E — to:

1. `./setup.sh && ./run.sh` to create and boot the VM.
2. macOS Setup Assistant + Apple ID + 2FA.
3. macOS hardening (auto-login, sleep off, iCloud disabled).
4. Messages.app + iMessage activation, verify a test message arrives.
5. Install BlueBubbles Server, grant Full Disk Access + Automation + Accessibility, set the admin password, configure the webhook, add to Login Items.
6. Sanity-check from host:
   ```bash
   tart ip bridge-vm
   curl "http://$(tart ip bridge-vm):1234/api/v1/server/info?password=<pw>"
   ```
   The second command must return BlueBubbles' server-info JSON before proceeding to Phase 3.

**Save the BlueBubbles admin password — you'll need it in Phase 4.** Stash it in a password manager; the e2e test in Phase 4 step 3 needs the same value that goes into `~/.hermes/.env`.

Reference: [spec runbook](../specs/2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook).

---

## Phase 3 — Hermes container `--add-host` wiring

### Task 3.1: Update `hermes-setup.sh` to inject `--add-host bridge-vm:<ip>`

The script's printed `docker run` next-step commands need `--add-host bridge-vm:$(tart ip bridge-vm)` so the gateway and dashboard containers resolve the VM by name. Also add a precondition check: warn (don't error) if `tart ip bridge-vm` doesn't return an IP at script-run time, so the user knows to do Phase 2 first.

**Files:**
- Modify: `/Users/gintini/s/vm-claw/hermes-setup.sh`

- [ ] **Step 1: Verification checks (will fail initially)**

```bash
cd /Users/gintini/s/vm-claw
{
  grep -qE -- '--add-host bridge-vm' hermes-setup.sh                     && echo "add-host present OK"        || echo "add-host present FAIL"
  grep -qE 'BRIDGE_VM_NAME=' hermes-setup.sh                             && echo "BRIDGE_VM_NAME var OK"      || echo "BRIDGE_VM_NAME var FAIL"
  grep -qE 'tart ip "\$BRIDGE_VM_NAME"|tart ip bridge-vm' hermes-setup.sh && echo "tart ip lookup OK"          || echo "tart ip lookup FAIL"
}
```

Expected: all FAIL.

- [ ] **Step 2: Add a `BRIDGE_VM_NAME` env var with default**

Near the other env-var defaults at the top of `hermes-setup.sh` (around the `HERMES_NETWORK="${HERMES_NETWORK:-...}"` line), add:

```bash
# Tart VM that hosts BlueBubbles Server. The Hermes container resolves it by
# this name via `docker run --add-host`; the IP is looked up at container start.
BRIDGE_VM_NAME="${BRIDGE_VM_NAME:-bridge-vm}"
```

- [ ] **Step 3: Add the bridge-VM IP-lookup function**

Add this helper function below the env-var defaults (anywhere before the `cat <<EOF` heredoc that prints next-step commands):

```bash
# Resolves the Tart bridge VM's softnet IP, or empty if it can't be looked up
# (VM not created yet, not running, or tart not on PATH). Used to template
# --add-host into the printed next-step docker commands.
bridge_vm_ip() {
    if ! command -v tart >/dev/null 2>&1; then
        return 0
    fi
    tart ip "$BRIDGE_VM_NAME" 2>/dev/null || true
}
```

- [ ] **Step 4: Compute the IP once just before the heredoc**

Just before the final `cat <<EOF` block (the one that starts with `=== Done ===`), insert:

```bash
BRIDGE_IP="$(bridge_vm_ip)"
if [[ -n "$BRIDGE_IP" ]]; then
    ADD_HOST_FRAGMENT="--add-host bridge-vm:$BRIDGE_IP"
    BRIDGE_IP_NOTE=""
else
    # VM not up yet: print a literal $(tart ip ...) substitution that the
    # user can copy-paste — docker will run the lookup at container start.
    # The leading backslash escapes the $ so the unquoted heredoc preserves
    # the substitution text instead of expanding it now.
    ADD_HOST_FRAGMENT="--add-host bridge-vm:\$(tart ip $BRIDGE_VM_NAME)"
    BRIDGE_IP_NOTE="
Note: Tart VM '$BRIDGE_VM_NAME' is not running yet, so the commands
above use \$(tart ip $BRIDGE_VM_NAME) — docker resolves the IP at
container start. Run Phase 2 of the migration plan first, or just
re-run this script after the VM is up to bake in a literal IP."
fi
```

- [ ] **Step 5: Inject `--add-host` into the printed docker-run commands**

In the heredoc that prints the next-step commands, modify the gateway and dashboard `docker run` examples to include the `--add-host` flag.

For the **gateway** block, replace:

```
       docker run -d --name $HERMES_GATEWAY_NAME --restart unless-stopped \\
         --network $HERMES_NETWORK \\
         -v $HERMES_HOME:/opt/data \\
         -p $HERMES_GATEWAY_PORT:8642 \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE gateway run
```

with:

```
       docker run -d --name $HERMES_GATEWAY_NAME --restart unless-stopped \\
         --network $HERMES_NETWORK \\
         $ADD_HOST_FRAGMENT \\
         -v $HERMES_HOME:/opt/data \\
         -p $HERMES_GATEWAY_PORT:8642 \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE gateway run
```

For the **interactive chat** block (used to run \`hermes config set\` etc.), replace:

```
       docker run -it --rm \\
         -v $HERMES_HOME:/opt/data \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE
```

with:

```
       docker run -it --rm \\
         $ADD_HOST_FRAGMENT \\
         -v $HERMES_HOME:/opt/data \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE
```

The dashboard container does not talk to BlueBubbles; leave it without `--add-host`.

- [ ] **Step 6: Append the bridge-VM note to the heredoc**

Just before the final `EOF` line of the heredoc (after the multi-profile pattern section, before `Reference: ...`), insert one extra line:

```
$BRIDGE_IP_NOTE
```

This prints nothing when the VM is up, and a clear "do Phase 2 first" hint otherwise.

- [ ] **Step 7: Re-run verification checks**

```bash
{
  grep -qE -- '--add-host bridge-vm' hermes-setup.sh                     && echo "add-host present OK"        || echo "add-host present FAIL"
  grep -qE 'BRIDGE_VM_NAME=' hermes-setup.sh                             && echo "BRIDGE_VM_NAME var OK"      || echo "BRIDGE_VM_NAME var FAIL"
  grep -qE 'tart ip "\$BRIDGE_VM_NAME"' hermes-setup.sh                  && echo "tart ip lookup OK"          || echo "tart ip lookup FAIL"
}
```

Expected: all `OK`.

- [ ] **Step 8: Syntax-check + dry-run print**

```bash
bash -n hermes-setup.sh && echo "syntax OK"
```

If you have time and can risk a full Colima boot, run the script end-to-end and verify the printed commands include `--add-host`. Otherwise, the syntax check + greps are enough.

- [ ] **Step 9: Commit**

```bash
git add hermes-setup.sh
git commit -m "$(cat <<'EOF'
Inject --add-host bridge-vm:<ip> into Hermes docker-run examples

The Hermes container reaches BlueBubbles in the bridge VM via
http://bridge-vm:1234. Resolve the name with docker --add-host;
look up the IP at container start (or print the literal subshell
form when the bridge VM isn't running yet).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Hermes BlueBubbles connector

### Task 4.1: Research the connector's expected env var / config key names (manual)

**This step is deferred to implementation time per the spec's "Open implementation details" section.** The names aren't worth committing from memory — verify against current Hermes docs.

**No code commit; output is the values that go into `~/.hermes/.env` in Task 4.2.**

- [ ] **Step 1: Open the Hermes Docker user guide**

Visit:
- <https://hermes-agent.nousresearch.com/docs/user-guide/docker>
- <https://hermes-agent.nousresearch.com/> (search "BlueBubbles")

- [ ] **Step 2: Identify the connector's config**

Find the BlueBubbles connector documentation. Note down:

| Setting | Goes in `.env` as | Value |
|---|---|---|
| BlueBubbles server URL | `<KEY>` | `http://bridge-vm:1234` |
| BlueBubbles password | `<KEY>` | `<password from Phase 2>` |
| Webhook auth secret (if applicable) | `<KEY>` | `<secret matching the BlueBubbles webhook config>` |

Common patterns to look for in Hermes docs: `BLUEBUBBLES_SERVER_URL`, `BLUEBUBBLES_PASSWORD`, `BLUEBUBBLES_WEBHOOK_SECRET`, or a YAML connector block under `toolsets:` / `messengers:` in `~/.hermes/config.yaml`.

- [ ] **Step 3: Note the webhook receive path on Hermes' side**

The webhook URL configured in BlueBubbles (see spec runbook D.8) needs to match the path Hermes' connector exposes on `:8642`. Note the exact path, e.g., `/v1/messengers/bluebubbles/webhook` (placeholder — confirm in Hermes docs).

- [ ] **Step 4: Update the BlueBubbles webhook URL in the bridge VM if it differs**

If the path in the spec runbook turned out wrong, update BlueBubbles' Settings → API & Webhooks → webhook URL to the correct path.

This task produces a piece of paper (or a sticky note in your password manager) with the three values + the webhook path. No git operations.

---

### Task 4.2: Populate `~/.hermes/.env` with BlueBubbles config

**Prerequisite:** Task 4.1 complete; you know the exact key names. **Prerequisite:** Phase 2 done; BlueBubbles is up.

**Files:**
- Modify: `~/.hermes/.env` (host-side; not in git).

- [ ] **Step 1: Confirm `.env` perms before touching it**

```bash
stat -f '%Sp %N' ~/.hermes/.env
chmod 600 ~/.hermes/.env
stat -f '%Sp %N' ~/.hermes/.env
```

Expected after chmod: `-rw-------`. If the file doesn't exist yet because you haven't run the Hermes setup wizard, do that first:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent setup
```

- [ ] **Step 2: Append the BlueBubbles config keys**

Replace `<KEY1>`, `<KEY2>`, etc. with the actual key names from Task 4.1. Replace `<PASSWORD>` and `<SECRET>` with the values from Phase 2.

```bash
cat >> ~/.hermes/.env <<'EOF'

# BlueBubbles bridge to the iMessage VM (vm-claw)
<KEY_FOR_SERVER_URL>=http://bridge-vm:1234
<KEY_FOR_PASSWORD>=<PASSWORD>
<KEY_FOR_WEBHOOK_SECRET>=<SECRET>
EOF
```

- [ ] **Step 3: Re-confirm perms and quick sanity**

```bash
stat -f '%Sp %N' ~/.hermes/.env
grep -c '<KEY_FOR_SERVER_URL>=' ~/.hermes/.env  # should print 1
```

`-rw-------` and `1`. If the grep prints `0` or `>1`, fix the file.

- [ ] **Step 4: No git operations.** `.env` lives outside the repo.

---

### Task 4.3: End-to-end test (send + receive)

**Prerequisite:** Tasks 4.1, 4.2 complete. Bridge VM is up. The Hermes gateway container is running with `--add-host bridge-vm:$(tart ip bridge-vm)`.

**Files:** none — runtime test only.

- [ ] **Step 1: Restart the gateway container with `--add-host`**

```bash
docker stop hermes 2>/dev/null || true
docker rm   hermes 2>/dev/null || true

BRIDGE_IP=$(tart ip bridge-vm)
test -n "$BRIDGE_IP" || { echo "bridge-vm not running; abort"; exit 1; }

docker run -d --name hermes --restart unless-stopped \
  --network hermes-net-default \
  --add-host "bridge-vm:$BRIDGE_IP" \
  -v ~/.hermes:/opt/data \
  -p 8642:8642 \
  --memory 4g --cpus 2 --shm-size 1g \
  nousresearch/hermes-agent gateway run
```

- [ ] **Step 2: Verify the container can reach BlueBubbles**

```bash
docker exec hermes wget -qO- "http://bridge-vm:1234/api/v1/server/info?password=$BB_PASSWORD" | head -c 300
```

(Substitute `$BB_PASSWORD` with the BlueBubbles admin password.) Expected: JSON starting with `{` and containing `serverVersion` or similar BlueBubbles server-info fields. If the request hangs or 404s, run the spec's foot-gun diagnostic.

- [ ] **Step 3: Outbound test — send a message via Hermes**

Use the Hermes API or interactive chat to send an iMessage to a known recipient (e.g., your own phone). Exact API call depends on the Hermes BlueBubbles connector docs (researched in Task 4.1).

Expected: the message arrives on the recipient device within ~5 seconds. The bridge identity's Apple ID is the sender.

- [ ] **Step 4: Inbound test — receive a message**

From the recipient device, reply to the bridge identity's Apple ID. Watch the Hermes gateway logs:

```bash
docker logs -f hermes --tail 20
```

Expected: a webhook POST is logged, the message body appears, and Hermes' session state acknowledges it. If nothing fires:
- Check BlueBubbles' Settings → API & Webhooks → webhook log for delivery attempts.
- Verify the BlueBubbles webhook URL targets `http://<softnet_gw_ip>:8642/<path>` and the path matches Task 4.1's research.
- From inside the bridge VM, test reachability of the gateway: `curl http://<softnet_gw_ip>:8642/healthz` (or whichever Hermes health endpoint exists).

- [ ] **Step 5: No git commit.** This task validates the running system.

---

## Phase 5 — Polish (optional)

These tasks improve operability but aren't required for the core feature. Do them only if Phase 4 is solid.

### Task 5.1 (optional): Auto-start the bridge VM on host boot

**Files:**
- Create: `/Users/gintini/s/vm-claw/host/com.vm-claw.bridge-vm.plist`
- Create: `/Users/gintini/s/vm-claw/host/install-vm-launchagent.sh`

- [ ] **Step 1: Create `host/` directory if not present**

```bash
mkdir -p /Users/gintini/s/vm-claw/host
```

- [ ] **Step 2: Write the LaunchAgent plist template**

Path: `/Users/gintini/s/vm-claw/host/com.vm-claw.bridge-vm.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vm-claw.bridge-vm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/tart</string>
    <string>run</string>
    <string>--net-softnet</string>
    <string>bridge-vm</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/com.vm-claw.bridge-vm.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/com.vm-claw.bridge-vm.err.log</string>
</dict>
</plist>
```

- [ ] **Step 3: Write the installer script**

Path: `/Users/gintini/s/vm-claw/host/install-vm-launchagent.sh`

```bash
#!/bin/bash
# Install / load the LaunchAgent that starts the bridge VM at user login.
# Idempotent: safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
PLIST_NAME="com.vm-claw.bridge-vm.plist"
SRC="$REPO_DIR/host/$PLIST_NAME"
DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ ! -f "$SRC" ]]; then
    echo "Source plist missing: $SRC" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Unload existing version if loaded.
if launchctl list | grep -q 'com\.vm-claw\.bridge-vm'; then
    launchctl unload "$DST" 2>/dev/null || true
fi

cp "$SRC" "$DST"
launchctl load "$DST"

echo "Loaded $DST"
echo "Logs: /tmp/com.vm-claw.bridge-vm.{out,err}.log"
echo "To unload: launchctl unload $DST"
```

- [ ] **Step 4: Make the installer executable + smoke test**

```bash
chmod +x /Users/gintini/s/vm-claw/host/install-vm-launchagent.sh
bash -n /Users/gintini/s/vm-claw/host/install-vm-launchagent.sh && echo "syntax OK"
```

Optionally run the installer:

```bash
./host/install-vm-launchagent.sh
launchctl list | grep vm-claw
```

Expected: a line for `com.vm-claw.bridge-vm`. The VM should start (or already be running).

- [ ] **Step 5: Commit**

```bash
git add host/com.vm-claw.bridge-vm.plist host/install-vm-launchagent.sh
git commit -m "$(cat <<'EOF'
Add optional LaunchAgent to auto-start the bridge VM at login

host/com.vm-claw.bridge-vm.plist + install-vm-launchagent.sh.
Loads at user login, restarts on non-zero exit, logs to /tmp.
Optional: only needed if you want the VM up without manual ./run.sh.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.2 (optional): Host-side healthcheck script

A one-shot script that prints `OK`/`FAIL` for each component so you can spot-check the chain when something silently breaks.

**Files:**
- Create: `/Users/gintini/s/vm-claw/host/healthcheck.sh`

- [ ] **Step 1: Write the script**

Path: `/Users/gintini/s/vm-claw/host/healthcheck.sh`

```bash
#!/bin/bash
# Spot-check vm-claw end-to-end. Prints OK/FAIL per component.
# Usage: BB_PASSWORD=... ./host/healthcheck.sh
set -uo pipefail

VM_NAME="${VM_NAME:-bridge-vm}"
BB_PORT="${BB_PORT:-1234}"
HERMES_GATEWAY_PORT="${HERMES_GATEWAY_PORT:-8642}"
HERMES_GATEWAY_NAME="${HERMES_GATEWAY_NAME:-hermes}"
BB_PASSWORD="${BB_PASSWORD:-}"

ok()   { printf "  OK    %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; }

echo "vm-claw healthcheck"

# 1. Tart VM running.
if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM_NAME"; then
    ok "tart VM '$VM_NAME' is known"
else
    fail "tart VM '$VM_NAME' not found in 'tart list'"
fi

# 2. VM has a softnet IP.
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
if [[ -n "$VM_IP" ]]; then
    ok "tart ip $VM_NAME = $VM_IP"
else
    fail "tart ip $VM_NAME returned empty (VM not running?)"
fi

# 3. BlueBubbles reachable from host (only if we have a password).
if [[ -n "$VM_IP" && -n "$BB_PASSWORD" ]]; then
    if curl -fsS --max-time 5 "http://$VM_IP:$BB_PORT/api/v1/server/info?password=$BB_PASSWORD" >/dev/null; then
        ok "BlueBubbles reachable from host at $VM_IP:$BB_PORT"
    else
        fail "BlueBubbles not reachable at $VM_IP:$BB_PORT (auth or routing?)"
    fi
elif [[ -z "$BB_PASSWORD" ]]; then
    fail "BB_PASSWORD env var not set; skipping BlueBubbles auth check"
fi

# 4. Colima/docker daemon up.
if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
else
    fail "docker info failed (colima not started?)"
fi

# 5. Hermes gateway container running.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$HERMES_GATEWAY_NAME"; then
    ok "container '$HERMES_GATEWAY_NAME' is running"
else
    fail "container '$HERMES_GATEWAY_NAME' not running"
fi

# 6. Container can resolve bridge-vm and reach BlueBubbles.
if [[ -n "$BB_PASSWORD" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$HERMES_GATEWAY_NAME"; then
    if docker exec "$HERMES_GATEWAY_NAME" wget -q --timeout=5 -O- \
            "http://bridge-vm:$BB_PORT/api/v1/server/info?password=$BB_PASSWORD" >/dev/null 2>&1; then
        ok "container reaches BlueBubbles via http://bridge-vm:$BB_PORT"
    else
        fail "container cannot reach http://bridge-vm:$BB_PORT (--add-host missing? or vmnet↔softnet blocked?)"
    fi
fi

echo "Done."
```

- [ ] **Step 2: Make executable + syntax-check**

```bash
chmod +x /Users/gintini/s/vm-claw/host/healthcheck.sh
bash -n /Users/gintini/s/vm-claw/host/healthcheck.sh && echo "syntax OK"
```

- [ ] **Step 3: Smoke run**

```bash
BB_PASSWORD=<your-bluebubbles-password> ./host/healthcheck.sh
```

Expected (when everything is healthy): six `OK` lines. Iterate until all green.

- [ ] **Step 4: Commit**

```bash
git add host/healthcheck.sh
git commit -m "$(cat <<'EOF'
Add host/healthcheck.sh for end-to-end spot-checks

Six checks: tart VM known, tart ip resolves, BlueBubbles reachable
from host, docker daemon up, hermes gateway container running, and
container-to-BlueBubbles connectivity via the --add-host name.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5.3 (optional): Document recovery paths in CLAUDE.md

Add a "Recovery" section to `CLAUDE.md` so future-you (or another agent) knows where to look when things break.

**Files:**
- Modify: `/Users/gintini/s/vm-claw/CLAUDE.md`

- [ ] **Step 1: Locate the insertion point**

```bash
grep -n '## Architecture' /Users/gintini/s/vm-claw/CLAUDE.md
```

The new section should be inserted just **before** the `## Architecture` heading.

- [ ] **Step 2: Insert the recovery section**

Insert this block immediately before `## Architecture`:

```markdown
## Recovery paths

When something silently breaks, work down this list before deeper debugging:

1. **`./host/healthcheck.sh`** — six-line green/red status across the chain.
2. **VM not booting / no IP** — `tart list` and `tart ip bridge-vm`. If the VM exists but has no IP, `./run.sh` is probably not active in any terminal; either run it again or load the LaunchAgent (`./host/install-vm-launchagent.sh`).
3. **Container can't reach `bridge-vm`** — usually means the gateway container was started without `--add-host bridge-vm:$(tart ip bridge-vm)`. Restart the container with the flag (see the spec's runbook §E for the exact docker run).
4. **iMessage stops sending** — log into the VM's GUI, open Messages.app, confirm iMessage is still active. macOS sleep on the VM is the most common cause; verify "Display sleep when on power adapter" is still off.
5. **Apple ID activation loop** — sign out of the Apple ID in Messages (not System Settings), wait 30 seconds, sign back in. If persistent, recreate the Apple ID; running iMessage in a VM is a grey area with Apple.
6. **VM is unrecoverable / suspect / over-updated** — `./destroy.sh && ./setup.sh && ./run.sh`, then re-run the runbook. The bridge identity's Apple ID is portable; only the local Messages history and BlueBubbles password are lost.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
Document recovery paths in CLAUDE.md

Six numbered checkpoints covering healthcheck, VM IP, --add-host
missing, iMessage send halts, Apple ID activation loops, and
last-resort VM rebuild.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes

**Spec coverage check:**

- Phase 1.1 → spec migration plan §"Phase 1" item 1 (tag).
- Phase 1.2/1.3/1.4 → spec migration plan §"Phase 1" item 3 (repoint scripts).
- Phase 2 (manual) → spec runbook §"VM provisioning runbook".
- Phase 3.1 → spec migration plan §"Phase 3" + Components §"Hermes container `--add-host` wiring" + Network model.
- Phase 4.1/4.2/4.3 → spec migration plan §"Phase 4" + spec §"Open implementation details".
- Phase 5.1/5.2/5.3 → spec migration plan §"Phase 5".

**Deferrals explicitly called out:**
- Phase 2 — manual; cross-references the spec runbook.
- Phase 4.1 — Hermes BlueBubbles connector key names; explicit research task.

**Pre-existing edits handled:**
- `hermes-setup.sh` — committed as-is in Task 0, then modified in Task 3.1.
- `setup.sh` — pre-session edits absorbed in Task 1.2 (the vmnet-collision function survives; the SHA pin and `DISK_SIZE_GB` are removed per spec).
- `run.sh` — same pattern in Task 1.3.
- `destroy.sh` — clean modification in Task 1.4.

---

**Update 2026-05-04: superseded by the `vmclaw` CLI plan.** Tasks 0,
1.1, 1.2, 1.3, 1.4, and 3.1 of this plan landed (commits `bfe4842`
through `b264bca` plus `a4ae55a`). The remaining Phase 4.1–4.3 and
Phase 5.1–5.2 tasks are subsumed by
[`docs/superpowers/plans/2026-05-04-vmclaw-cli.md`](./2026-05-04-vmclaw-cli.md):

- 4.1 (research connector key names) → still deferred; output is a
  single commit updating constants in `internal/hermes/envfile.go`.
- 4.2 + 4.3 (`.env` write + e2e test) → folded into
  `vmclaw bootstrap finalize`.
- 5.1 (auto-start LaunchAgent) → `vmclaw vm install-agent`.
- 5.2 (host healthcheck script) → `vmclaw doctor`.
- 5.3 (recovery paths in CLAUDE.md) → already landed in commit
  `eecf46e`.
