#!/bin/bash
# Sourced, never run. The bot account of docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md, in one
# place for provisioning, the host wrapper, the backup pull, the in-place switch and the checks.
# shellcheck disable=SC2034  # every name here is used by the scripts that source this file
BOT_USER=sebastian
BOT_UID=2000
BOT_HOME=/home/sebastian
# The repo inside the guest: root-owned, readable by everyone, writable by no one else (host/claw.sh deploy).
CLAW_REPO=/opt/vm-claw
# A prefix that runs a command as the bot with a user-session environment, so systemctl --user, journalctl --user
# and openclaw reach the bot's own lingering user manager. Run it from an account with sudo (admin).
BOT_SESSION=(sudo -n -u "$BOT_USER" -- env -C "$BOT_HOME" HOME="$BOT_HOME" USER="$BOT_USER" LOGNAME="$BOT_USER"
  XDG_RUNTIME_DIR="/run/user/$BOT_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$BOT_UID/bus")
