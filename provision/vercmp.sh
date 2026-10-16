#!/bin/bash
# Dotted-version comparison, shared by provision.sh, tests/stack-check.sh and tests/acceptance.sh. Sourced.
# Pure bash (no sort -V: the host's BSD sort and the guest's GNU sort must agree), numeric per field, so
# 2026.10.1 is newer than 2026.9.7. Only digits and single dots are versions; anything else is an error.

# vercmp <a> <b>: prints lt, eq or gt; returns 1 (printing nothing) when either is not a dotted number.
vercmp() {
  local re='^[0-9]+(\.[0-9]+)*$' a b i x y
  [[ $1 =~ $re ]] && [[ $2 =~ $re ]] || return 1
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  i=0
  while [ "$i" -lt "${#a[@]}" ] || [ "$i" -lt "${#b[@]}" ]; do
    x=$((10#${a[$i]:-0})); y=$((10#${b[$i]:-0}))   # 10#: a leading zero is not octal
    if [ "$x" -lt "$y" ]; then echo lt; return 0; fi
    if [ "$x" -gt "$y" ]; then echo gt; return 0; fi
    i=$((i + 1))
  done
  echo eq
}

# version_ge <installed> <pin>: success when installed >= pin; an unreadable version never satisfies.
version_ge() {
  local c
  c=$(vercmp "$1" "$2") || return 1
  [ "$c" != lt ]
}

# openclaw_installed_version: the installed CLI's version ("OpenClaw 2026.9.7 (c074824)" -> 2026.9.7); empty if unreadable.
openclaw_installed_version() {
  openclaw --version 2>/dev/null | sed -n 's/^OpenClaw \([^[:space:]]*\).*$/\1/p' | head -1
}
