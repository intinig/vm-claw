#!/bin/bash
# Sourced, not run. Reads the 1Password bootstrap token out of a dotenv file; shared by migrate/import.sh,
# ops/backup/nightly-backup.sh and (Task 9) tests/acceptance.sh so they cannot disagree.
#
#   dotenv_token <file|->   prints the token on stdout; on any doubt prints a message on stderr and returns 1
#                           (`-` reads stdin, for a member streamed out of an archive)
#
# The file is data, never code: it is read line by line and nothing in it is executed. Dotenv loaders
# disagree on duplicates, CRLF, comments and quoting, so whatever they could disagree on is refused here
# instead of guessed. It fails on: CRLF line endings; the key set more than once (`export `-prefixed and
# indented lines count); a missing key (a key that only starts with the name, such as
# OP_SERVICE_ACCOUNT_TOKEN_OLD, is not the key; a commented-out line is not an assignment); an empty value;
# an inline comment or whitespace in the value; and characters a dotenv file cannot carry unquoted.
# One level of matching surrounding quotes is stripped.
dotenv_token() {
  local file="${1:-}" input line raw="" tok n=0
  local key_re='^[[:space:]]*(export[[:space:]]+)?OP_SERVICE_ACCOUNT_TOKEN[[:space:]]*=(.*)$'
  local cr=$'\r'
  if [ "$file" = - ]; then input=/dev/stdin
  elif [ -f "$file" ]; then input="$file"
  else echo "dotenv-token: cannot read '$file'" >&2; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$cr") echo "dotenv-token: the file has CRLF line endings; convert it to LF (a loader may keep the CR in the token)" >&2; return 1 ;;
    esac
    if [[ $line =~ $key_re ]]; then n=$((n + 1)); raw="${BASH_REMATCH[2]}"; fi
  done < "$input"
  if [ "$n" -eq 0 ]; then echo "dotenv-token: bootstrap token missing: no OP_SERVICE_ACCOUNT_TOKEN= line" >&2; return 1; fi
  if [ "$n" -gt 1 ]; then echo "dotenv-token: OP_SERVICE_ACCOUNT_TOKEN is set $n times (export-prefixed and indented lines count); refusing to guess which one a loader uses" >&2; return 1; fi
  tok="$raw"
  case "$tok" in
    \"*\") tok=${tok#\"}; tok=${tok%\"} ;;
    \'*\') tok=${tok#\'}; tok=${tok%\'} ;;
  esac
  if [ -z "$tok" ]; then echo "dotenv-token: the OP_SERVICE_ACCOUNT_TOKEN value is empty" >&2; return 1; fi
  case "$tok" in
    *"#"*) echo "dotenv-token: the OP_SERVICE_ACCOUNT_TOKEN value contains '#' (an inline comment?)" >&2; return 1 ;;
    *[[:space:]]*) echo "dotenv-token: the OP_SERVICE_ACCOUNT_TOKEN value contains whitespace" >&2; return 1 ;;
  esac
  if ! [[ "$tok" =~ ^[A-Za-z0-9_.=+/:@%-]+$ ]]; then
    echo "dotenv-token: bootstrap token has characters a dotenv file cannot carry unquoted" >&2; return 1
  fi
  printf '%s\n' "$tok"
}
