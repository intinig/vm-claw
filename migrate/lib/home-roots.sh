#!/bin/bash
# Shared by migrate/import.sh and migrate/rehome.sh: the live-configuration roots that the home rewrite
# (homepaths.mjs) and the leftover scan (scan-refs.mjs --old-home) cover. One list, so the dry scan in
# rehome.sh prepare checks exactly what import.sh will check mid-downtime. Source it; bash 3.2 safe.

# home_roots <home> <array-name>: fill the named array with the roots that exist under <home>. Only roots that
# exist are named (scan-refs fails with exit 4 on a missing one by design). scan-refs skips vault directories, so
# the vault's git config is named itself. Addendum 2026-10-05: the Workshop skills dirs, Codex's project trust
# (config.toml) and the workspace scripts, which homepaths.mjs now rewrites (the same globs). The memory notes and
# pre-rehome-config-backups/ are not roots: history, and admin's untouched config copies.
home_roots() {
  local _h="$1" _name="$2" _p
  eval "$_name=()"
  for _p in "$_h/.openclaw/openclaw.json" "$_h/.openclaw/.env" "$_h/.openclaw/gateway.systemd.env" "$_h/.openclaw/cron" \
            "$_h/.openclaw/skills" "$_h/.openclaw/bin" "$_h/.ssh/config" "$_h/brain" "$_h/brain/vault/.git/config" "$_h/ops" \
            "$_h"/.openclaw/workspace*/skills "$_h"/.openclaw/workspace*/*.md \
            "$_h"/.openclaw/agents/*/agent/workshop-skills "$_h"/.openclaw/agents/*/agent/codex-home/config.toml \
            "$_h"/.openclaw/workspace*/*.{py,mjs,js,sh} "$_h"/.openclaw/workspace*/scripts/*.{py,mjs,js,sh}; do
    if [ -e "$_p" ]; then eval "$_name+=(\"\$_p\")"; fi
  done
}
