#!/bin/bash
# Regenerates docs/images/dialog.png: shows the module's dialog for brew's argv and
# parent shape, then captures only the dialog window (nothing else on screen).
#
# Runs the built module through tests/harness.c, copied as "sudo" so the dialog
# title matches real sudo, with a Perl script named brew.rb as the requester.
# Do not touch the sensor until the capture message appears.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/screenshot"
out="$root/docs/images/dialog.png"
mkdir -p "$work" "$(dirname "$out")"

cp "$root/build/harness" "$work/sudo"
cat > "$work/brew.rb" <<'EOF'
system("./sudo", "-E", "--", "/usr/sbin/installer", "-pkg",
       "/opt/homebrew/Caskroom/zoom/6.4.0/zoomusInstallerFull.pkg", "-target", "/");
EOF

cd "$work"
MODULE="$root/build/pam_tid_context.so" /usr/bin/perl -W brew.rb upgrade --cask zoom &
/bin/sleep 3

# The Touch ID sheet is drawn by coreautha; its window title is the requesting process.
id="$("$root/build/windows" | awk -F'\t' '$2 == "coreautha" && $3 == "sudo" { print $1; exit }')"
if [[ -z "$id" ]]; then
    echo "screenshot: no coreautha window titled 'sudo' found; cancel the dialog" >&2
    wait || true
    exit 1
fi
screencapture -x -l "$id" "$out"
echo "screenshot: captured window $id -> docs/images/dialog.png (cancel or approve the dialog now)"
wait || true
