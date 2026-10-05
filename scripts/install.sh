#!/bin/bash
# Installs pam_tid_context.so and switches /etc/pam.d/sudo_local to it.
#
# A PAM module that fails to load makes sudo refuse every login ("unable to
# initialize PAM"), whatever its control flag. So each step is gated on libpam
# accepting the result, and a rejected sudo_local is rolled back immediately.
# Keep a root shell open while running this anyway (see README, Recovery).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
module=pam_tid_context.so
dest_dir=/usr/local/lib/pam
dest="$dest_dir/$module"
sudo_local=/etc/pam.d/sudo_local
probe="$root/build/probe_load"

die() { echo "install: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ -f "$root/build/$module" && -x "$probe" ]] || die "run 'just build' first"

echo "1/4 checking the built module loads in libpam"
"$probe" "$root/build/$module" || die "built module rejected by libpam; nothing changed"

echo "2/4 installing $dest (sudo)"
sudo mkdir -p "$dest_dir"
sudo install -o root -g wheel -m 444 "$root/build/$module" "$dest"
"$probe" "$dest" || die "installed module rejected by libpam; sudo_local not changed"

echo "3/4 writing $sudo_local"
backup=""
if [[ -f "$sudo_local" ]]; then
    backup="$sudo_local.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp -p "$sudo_local" "$backup"
    echo "    backup: $backup"
fi
new="$(mktemp)"
trap 'rm -f "$new"' EXIT
# Comment out active pam_tid.so / pam_tid_* lines, put ours where the first one
# was (keeps it after pam_reattach if present), append if there was none.
# Existing lines for this module are dropped so re-running is idempotent.
{ [[ -f "$sudo_local" ]] && cat "$sudo_local"; true; } | awk -v dest="$dest" '
    BEGIN { ours = "auth       sufficient     " dest }
    /^[[:space:]]*#/ { print; next }
    $1 == "auth" && $3 == dest { next }
    $1 == "auth" && ($3 ~ /(^|\/)pam_tid(_[a-z]+)?\.so(\.2)?$/) {
        print "#" $0
        if (!done) { print ours; done = 1 }
        next
    }
    { print }
    END { if (!done) print ours }
' > "$new"
sudo install -o root -g wheel -m 444 "$new" "$sudo_local"

echo "4/4 checking the new $sudo_local loads in libpam"
if ! "$probe" "$sudo_local"; then
    if [[ -n "$backup" ]]; then
        sudo cp -p "$backup" "$sudo_local"
        die "new sudo_local rejected; restored $backup"
    fi
    sudo rm -f "$sudo_local"
    die "new sudo_local rejected; removed it (there was none before)"
fi

echo
echo "Installed. Active sudo_local lines:"
grep -v '^[[:space:]]*#' "$sudo_local" | sed 's/^/    /'
echo "Test in a new terminal: sudo -k; sudo /usr/bin/true"
