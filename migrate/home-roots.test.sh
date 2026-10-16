#!/bin/bash
# Tests for migrate/lib/home-roots.sh: the root list import.sh and rehome.sh share. Pins the exact ordered list (a root
# dropped here silently leaves a live file out of both the import gate and prepare's dry scan) and that roots which do
# not exist are filtered out (scan-refs exits 4 on a missing one by design). Runs under /bin/bash 3.2 as well.
set -euo pipefail
export LC_ALL=C   # glob order is the locale's: pin it
here="$(cd "$(dirname "$0")" && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# shellcheck source=migrate/lib/home-roots.sh
. "$here/lib/home-roots.sh"
pass=0; fail=0
eq() { # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; printf '  expected:\n%s\n  actual:\n%s\n' "$2" "$3"; fi
}

h="$t/home"
mkdir -p "$h/.openclaw/cron" "$h/.openclaw/skills" "$h/.openclaw/bin" "$h/.openclaw/workspace1/skills" "$h/.openclaw/workspace2/skills" \
  "$h/.ssh" "$h/brain/vault/.git" "$h/ops"
touch "$h/.openclaw/openclaw.json" "$h/.openclaw/.env" "$h/.openclaw/gateway.systemd.env" "$h/.ssh/config" "$h/brain/vault/.git/config" \
  "$h/.openclaw/workspace1/AGENTS.md" "$h/.openclaw/workspace2/SOUL.md"
# Addendum 2026-10-05: the Workshop skills dirs, Codex's config.toml and the workspace scripts (directly in a workspace
# or its scripts/, .py .mjs .js .sh). Not roots: other names, hidden names, deeper scripts.
mkdir -p "$h/.openclaw/agents/main/agent/workshop-skills/s" "$h/.openclaw/agents/vera/agent/workshop-skills" \
  "$h/.openclaw/agents/main/agent/codex-home" "$h/.openclaw/agents/vera/agent/codex-home" \
  "$h/.openclaw/workspace1/scripts/lib" "$h/.openclaw/workspace2/scripts"
touch "$h/.openclaw/agents/main/agent/codex-home/config.toml" "$h/.openclaw/workspace1/gen.py" "$h/.openclaw/workspace1/qr.mjs" \
  "$h/.openclaw/workspace2/w.js" "$h/.openclaw/workspace2/x.sh" "$h/.openclaw/workspace1/scripts/run.sh" \
  "$h/.openclaw/workspace2/scripts/f.py" "$h/.openclaw/workspace1/notes.txt" "$h/.openclaw/workspace1/.hidden.sh" \
  "$h/.openclaw/workspace1/scripts/lib/deep.py" "$h/.openclaw/workspace1/scripts/README"
roots=(); home_roots "$h" roots
eq "every root, in order" "$(cat <<EOT
$h/.openclaw/openclaw.json
$h/.openclaw/.env
$h/.openclaw/gateway.systemd.env
$h/.openclaw/cron
$h/.openclaw/skills
$h/.openclaw/bin
$h/.ssh/config
$h/brain
$h/brain/vault/.git/config
$h/ops
$h/.openclaw/workspace1/skills
$h/.openclaw/workspace2/skills
$h/.openclaw/workspace1/AGENTS.md
$h/.openclaw/workspace2/SOUL.md
$h/.openclaw/agents/main/agent/workshop-skills
$h/.openclaw/agents/vera/agent/workshop-skills
$h/.openclaw/agents/main/agent/codex-home/config.toml
$h/.openclaw/workspace1/gen.py
$h/.openclaw/workspace1/qr.mjs
$h/.openclaw/workspace2/w.js
$h/.openclaw/workspace2/x.sh
$h/.openclaw/workspace2/scripts/f.py
$h/.openclaw/workspace1/scripts/run.sh
EOT
)" "$(printf '%s\n' "${roots[@]}")"

rm -rf "$h/.openclaw/cron" "$h/ops" "$h/.openclaw/workspace2" "$h/.ssh/config" "$h/.openclaw/agents/vera"
roots=(); home_roots "$h" roots
eq "roots that do not exist are left out" "$(cat <<EOT
$h/.openclaw/openclaw.json
$h/.openclaw/.env
$h/.openclaw/gateway.systemd.env
$h/.openclaw/skills
$h/.openclaw/bin
$h/brain
$h/brain/vault/.git/config
$h/.openclaw/workspace1/skills
$h/.openclaw/workspace1/AGENTS.md
$h/.openclaw/agents/main/agent/workshop-skills
$h/.openclaw/agents/main/agent/codex-home/config.toml
$h/.openclaw/workspace1/gen.py
$h/.openclaw/workspace1/qr.mjs
$h/.openclaw/workspace1/scripts/run.sh
EOT
)" "$(printf '%s\n' "${roots[@]}")"

e="$t/empty"; mkdir -p "$e"
roots=(); home_roots "$e" roots
eq "a home with none yields an empty list" 0 "${#roots[@]}"

echo "home-roots tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
