#!/bin/bash
# Tests for provision/lib.sh's install_sshd_dropin, with a fake sshd that rejects any config containing "reject".
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/d"
cat > "$t/bin/sshd" <<'EOS'
#!/bin/bash
[ "$1" = -t ] && [ "$2" = -f ] || exit 9
! grep -q reject "$3"
EOS
chmod +x "$t/bin/sshd"
echo "Port 22" > "$t/sshd_config"
# shellcheck source=provision/lib.sh
. "$here/provision/lib.sh"
export PATH="$t/bin:$PATH" SSHD_CONFIG="$t/sshd_config"
pass=0; fail=0
ok() { if [ "$2" = yes ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
dest="$t/d/20-x.conf"
install_sshd_dropin "$dest" "DenyUsers a" && r=yes || r=no; ok "a valid drop-in installs" "$r"
ok "its content is in place" "$(yn grep -qx 'DenyUsers a' "$dest")"
ok "no temp file is left" "$(yn test -z "$(find "$t/d" -type f ! -name 20-x.conf)")"
install_sshd_dropin "$dest" "DenyUsers reject" && r=no || r=yes; ok "a rejected drop-in fails" "$r"
ok "the earlier drop-in is untouched" "$(yn grep -qx 'DenyUsers a' "$dest")"
ok "no temp file is left after a rejection" "$(yn test -z "$(find "$t/d" -type f ! -name 20-x.conf)")"
dest2="$t/d/30-y.conf"
install_sshd_dropin "$dest2" "DenyUsers reject" && r=no || r=yes; ok "a rejected first install fails" "$r"
ok "the final drop-in does not exist" "$(yn test ! -e "$dest2")"
ok "no temp file for it either" "$(yn test -z "$(find "$t/d" -type f ! -name 20-x.conf)")"
echo "lib tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
